package llm

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

const (
	openaiDefaultBaseURL = "https://api.openai.com/v1"
	// OpenAI chat-completions returns quickly for short prompts but the
	// transcription cleaner can occasionally exceed a few seconds when
	// the prompt is long; mirror Anthropic's modest default and let
	// callers tighten via Options.Timeout if they want fail-fast.
	openaiDefaultTimeout = 30 * time.Second
)

// OpenAIProvider is the registry entry for OpenAI. Cloud-only — requires
// an API key. The factory adapts the generic Options shape to OpenAI's
// constructor.
var OpenAIProvider = &Provider{
	Name:         "openai",
	DefaultModel: "gpt-4o-mini",
	NeedsAPIKey:  true,
	factory: func(opts Options) (Cleaner, error) {
		return NewOpenAI(OpenAIOptions{
			APIKey:  opts.APIKey,
			Model:   opts.Model,
			BaseURL: opts.BaseURL,
			Timeout: opts.Timeout,
			Prompt:  opts.Prompt,
		})
	},
}

func init() {
	register(OpenAIProvider)
}

// OpenAIOptions configures the OpenAI Cleaner.
type OpenAIOptions struct {
	APIKey  string
	Model   string
	BaseURL string        // optional; for testing or proxy
	Timeout time.Duration // optional; defaults to 30s
	Prompt  string        // optional; uses DefaultPrompt when empty
}

// OpenAI is the OpenAI-backed Cleaner. Talks to /chat/completions over HTTP.
type OpenAI struct {
	client  *http.Client
	apiKey  string
	model   string
	baseURL string
	prompt  string
}

// NewOpenAI constructs an OpenAI Cleaner. Validates APIKey explicitly so
// callers don't accidentally fall through to OPENAI_API_KEY in env — same
// reasoning as NewAnthropic.
func NewOpenAI(opts OpenAIOptions) (*OpenAI, error) {
	return newOpenAICompatible(opts, true)
}

// newOpenAICompatible builds the *OpenAI client without forcing an API key,
// so OpenAI-compatible local servers (e.g. LM Studio) can reuse the same
// HTTP wire code. requireKey=true keeps the historical NewOpenAI behaviour;
// requireKey=false lets opts.APIKey be empty (in which case Clean/CleanStream
// omit the Authorization header entirely).
func newOpenAICompatible(opts OpenAIOptions, requireKey bool) (*OpenAI, error) {
	if requireKey && opts.APIKey == "" {
		return nil, errors.New("openai: APIKey is required")
	}
	baseURL := opts.BaseURL
	if baseURL == "" {
		baseURL = openaiDefaultBaseURL
	}
	timeout := opts.Timeout
	if timeout == 0 {
		timeout = openaiDefaultTimeout
	}
	return &OpenAI{
		client:  &http.Client{Timeout: timeout},
		apiKey:  opts.APIKey,
		model:   opts.Model,
		baseURL: strings.TrimRight(baseURL, "/"),
		prompt:  opts.Prompt,
	}, nil
}

// openaiChatRequest is the wire format for POST /chat/completions.
type openaiChatRequest struct {
	Model     string              `json:"model"`
	Messages  []openaiChatMessage `json:"messages"`
	Stream    bool                `json:"stream"`
	MaxTokens int                 `json:"max_tokens,omitempty"`
}

type openaiChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// openaiVisionRequest is the multimodal variant of
// openaiChatRequest. It is a separate type rather than a `Content any`
// on the existing one because the text path's shape is a contract its
// own tests assert on, and widening it to `any` would let a future
// refactor silently send the wrong thing on the far commoner path.
type openaiVisionRequest struct {
	Model     string                `json:"model"`
	Messages  []openaiVisionMessage `json:"messages"`
	Stream    bool                  `json:"stream"`
	MaxTokens int                   `json:"max_tokens,omitempty"`
}

// openaiVisionMessage carries an ARRAY of content parts. This is the
// one structural difference from the text path: OpenAI accepts a plain
// string for `content` OR a parts array, and images are only expressible
// in the array form.
type openaiVisionMessage struct {
	Role    string              `json:"role"`
	Content []openaiContentPart `json:"content"`
}

// openaiContentPart is one element of that array: either
// {"type":"text","text":...} or
// {"type":"image_url","image_url":{"url":...}}.
type openaiContentPart struct {
	Type     string          `json:"type"`
	Text     string          `json:"text,omitempty"`
	ImageURL *openaiImageURL `json:"image_url,omitempty"`
}

// openaiImageURL holds a `data:` URL for an inline image. Detail is
// left unset so the server picks its own tiling; the design already
// bounds the image to a 1568px long edge host-side.
type openaiImageURL struct {
	URL    string `json:"url"`
	Detail string `json:"detail,omitempty"`
}

// openaiChatResponse is the non-streaming response shape. We only care
// about the assistant text in choices[0].message.content.
type openaiChatResponse struct {
	Choices []struct {
		Message openaiChatMessage `json:"message"`
	} `json:"choices"`
	Error *openaiErrorBody `json:"error,omitempty"`
}

// openaiStreamFrame is one SSE `data: {…}` payload during streaming.
// choices[0].delta.content carries each chunk; the final frame is the
// literal string `[DONE]` (handled before unmarshaling).
type openaiStreamFrame struct {
	Choices []struct {
		Delta struct {
			Content string `json:"content"`
		} `json:"delta"`
		FinishReason *string `json:"finish_reason"`
	} `json:"choices"`
	Error *openaiErrorBody `json:"error,omitempty"`
}

// openaiErrorBody mirrors the error envelope OpenAI returns on 4xx/5xx.
// We lift the message into the Go error so callers see a useful string
// instead of a raw HTTP code.
type openaiErrorBody struct {
	Message string `json:"message"`
	Type    string `json:"type"`
	Code    string `json:"code"`
}

// Clean sends raw to /chat/completions with stream=false and returns the
// cleaned text. Errors on missing key (caught at construction), network
// failures, non-2xx responses, or empty content — callers must fall back
// to the raw transcription on error.
func (o *OpenAI) Clean(ctx context.Context, raw string, preserveTerms []string) (string, error) {
	if o == nil || o.client == nil {
		return "", errors.New("openai: not initialized")
	}
	promptTpl := o.prompt
	if promptTpl == "" {
		promptTpl = DefaultPrompt
	}
	prompt := RenderPrompt(promptTpl, raw, preserveTerms)
	body, _ := json.Marshal(openaiChatRequest{
		Model:     o.model,
		Messages:  []openaiChatMessage{{Role: "user", Content: prompt}},
		Stream:    false,
		MaxTokens: 1024,
	})
	t0 := time.Now()
	// See the matching comment in ollama.go's Clean: suppressed for
	// screen-context extraction so cleanup's Clean: lines stay
	// one-to-one with dictations and the log doesn't record every
	// focused window's text size on every focus change.
	if !IsScreenContextSource(ctx) {
		log.Printf("[howl] openai.Clean: sending model=%s rawLen=%d termCount=%d", o.model, len(raw), len(preserveTerms))
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, o.baseURL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("openai: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if o.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+o.apiKey)
	}

	resp, err := o.client.Do(req)
	if err != nil {
		log.Printf("[howl] openai.Clean: FAILED after %v: %v", time.Since(t0), err)
		return "", fmt.Errorf("openai: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", openaiHTTPError(resp)
	}

	var cr openaiChatResponse
	if err := json.NewDecoder(resp.Body).Decode(&cr); err != nil {
		return "", fmt.Errorf("openai: decode response: %w", err)
	}
	log.Printf("[howl] openai.Clean: response in %v choices=%d", time.Since(t0), len(cr.Choices))
	if len(cr.Choices) == 0 {
		return "", errors.New("openai: empty response (no choices)")
	}
	result := strings.TrimSpace(cr.Choices[0].Message.Content)
	if result == "" {
		return "", errors.New("openai: no text content in response")
	}
	return result, nil
}

// CleanStream streams from /chat/completions (SSE) and invokes onDelta for
// each non-empty content chunk. Returns the accumulated text on completion.
func (o *OpenAI) CleanStream(
	ctx context.Context,
	raw string,
	preserveTerms []string,
	onDelta func(string),
) (string, error) {
	if o == nil || o.client == nil {
		return "", errors.New("openai: not initialized")
	}
	promptTpl := o.prompt
	if promptTpl == "" {
		promptTpl = DefaultPrompt
	}
	prompt := RenderPrompt(promptTpl, raw, preserveTerms)
	body, _ := json.Marshal(openaiChatRequest{
		Model:     o.model,
		Messages:  []openaiChatMessage{{Role: "user", Content: prompt}},
		Stream:    true,
		MaxTokens: 1024,
	})
	t0 := time.Now()
	log.Printf("[howl] openai.CleanStream: starting model=%s rawLen=%d termCount=%d", o.model, len(raw), len(preserveTerms))

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, o.baseURL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("openai: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if o.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+o.apiKey)
	}
	req.Header.Set("Accept", "text/event-stream")

	resp, err := o.client.Do(req)
	if err != nil {
		log.Printf("[howl] openai.CleanStream: FAILED after %v: %v", time.Since(t0), err)
		return "", fmt.Errorf("openai: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", openaiHTTPError(resp)
	}

	var b strings.Builder
	firstDeltaAt := time.Time{}
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		// SSE frames look like `data: {…}` or `data: [DONE]`. We don't
		// care about the `event:` field — OpenAI only emits messages.
		if !bytes.HasPrefix(line, []byte("data: ")) {
			continue
		}
		payload := bytes.TrimPrefix(line, []byte("data: "))
		if bytes.Equal(bytes.TrimSpace(payload), []byte("[DONE]")) {
			break
		}
		var frame openaiStreamFrame
		if err := json.Unmarshal(payload, &frame); err != nil {
			return strings.TrimSpace(b.String()), fmt.Errorf("openai: decode frame: %w", err)
		}
		if frame.Error != nil {
			return strings.TrimSpace(b.String()), fmt.Errorf("openai: %s", frame.Error.Message)
		}
		if len(frame.Choices) == 0 {
			continue
		}
		chunk := frame.Choices[0].Delta.Content
		if chunk != "" {
			if firstDeltaAt.IsZero() {
				firstDeltaAt = time.Now()
				log.Printf("[howl] openai.CleanStream: first delta after %v", firstDeltaAt.Sub(t0))
			}
			b.WriteString(chunk)
			onDelta(chunk)
		}
	}
	if err := scanner.Err(); err != nil {
		log.Printf("[howl] openai.CleanStream: scan FAILED after %v: %v", time.Since(t0), err)
		return strings.TrimSpace(b.String()), fmt.Errorf("openai: scan: %w", err)
	}
	final := strings.TrimSpace(b.String())
	log.Printf("[howl] openai.CleanStream: done in %v cleanedLen=%d", time.Since(t0), len(final))
	if final == "" {
		return "", errors.New("openai: empty stream")
	}
	return final, nil
}

// openaiErrorMessage reads the response body and lifts any structured
// error message out of it. Falls back to the trimmed body for
// unstructured failures (LM Studio and llama.cpp-derived servers are
// inconsistent about the envelope).
func openaiErrorMessage(resp *http.Response) string {
	snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
	var env struct {
		Error *openaiErrorBody `json:"error"`
	}
	if err := json.Unmarshal(snippet, &env); err == nil && env.Error != nil && env.Error.Message != "" {
		return env.Error.Message
	}
	// Some OpenAI-compatible servers return {"error":"<string>"} rather
	// than the object form; take the string when that's what it is.
	var plain struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(snippet, &plain); err == nil && plain.Error != "" {
		return plain.Error
	}
	return strings.TrimSpace(string(snippet))
}

// openaiHTTPError renders a non-2xx response as a Go error, lifting any
// structured error message into it.
func openaiHTTPError(resp *http.Response) error {
	return fmt.Errorf("openai: HTTP %d: %s", resp.StatusCode, openaiErrorMessage(resp))
}

// openaiImageHTTPError is openaiHTTPError plus the no-vision verdict.
// Split out rather than folded into openaiHTTPError so the text path
// can never start reporting ErrNoVision.
func openaiImageHTTPError(resp *http.Response) error {
	msg := openaiErrorMessage(resp)
	if isNoVisionRejection(resp.StatusCode, msg) {
		return fmt.Errorf("openai: HTTP %d: %w: %s", resp.StatusCode, ErrNoVision, msg)
	}
	return fmt.Errorf("openai: HTTP %d: %s", resp.StatusCode, msg)
}

// CleanImage is the vision counterpart of Clean, and is shared verbatim
// with LM Studio (an *OpenAI built without an API key). Same endpoint,
// same auth handling, same timeouts — the only difference is that
// `content` becomes an array of parts so an image can be attached as a
// base64 `data:` URL.
func (o *OpenAI) CleanImage(ctx context.Context, img Image, preserveTerms []string) (string, error) {
	if o == nil || o.client == nil {
		return "", errors.New("openai: not initialized")
	}
	if err := validateImage("openai", img); err != nil {
		return "", err
	}
	promptTpl := o.prompt
	if promptTpl == "" {
		promptTpl = DefaultPrompt
	}
	prompt := RenderImagePrompt(promptTpl, preserveTerms)
	dataURL := "data:" + img.MediaType + ";base64," + base64.StdEncoding.EncodeToString(img.Data)
	body, _ := json.Marshal(openaiVisionRequest{
		Model: o.model,
		Messages: []openaiVisionMessage{{
			Role: "user",
			Content: []openaiContentPart{
				{Type: "text", Text: prompt},
				{Type: "image_url", ImageURL: &openaiImageURL{URL: dataURL}},
			},
		}},
		Stream:    false,
		MaxTokens: 1024,
	})
	t0 := time.Now()
	// Same suppression rule as Clean — see its comment.
	if !IsScreenContextSource(ctx) {
		log.Printf("[howl] openai.CleanImage: sending model=%s imageBytes=%d termCount=%d", o.model, len(img.Data), len(preserveTerms))
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, o.baseURL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("openai: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if o.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+o.apiKey)
	}

	resp, err := o.client.Do(req)
	if err != nil {
		// A transport error (timeout, refused connection, cancelled
		// context) has no status code, so it can never be mistaken for
		// a no-vision verdict.
		log.Printf("[howl] openai.CleanImage: FAILED after %v: %v", time.Since(t0), err)
		return "", fmt.Errorf("openai: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", openaiImageHTTPError(resp)
	}

	var cr openaiChatResponse
	if err := json.NewDecoder(resp.Body).Decode(&cr); err != nil {
		return "", fmt.Errorf("openai: decode response: %w", err)
	}
	log.Printf("[howl] openai.CleanImage: response in %v choices=%d", time.Since(t0), len(cr.Choices))
	if len(cr.Choices) == 0 {
		return "", errors.New("openai: empty response (no choices)")
	}
	result := strings.TrimSpace(cr.Choices[0].Message.Content)
	if result == "" {
		return "", errors.New("openai: no text content in response")
	}
	return result, nil
}
