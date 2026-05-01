package llm

import (
	"bufio"
	"bytes"
	"context"
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
	ollamaDefaultBaseURL = "http://localhost:11434"
	// First request to a freshly-started Ollama can take seconds to load
	// the model into memory; later requests are typically <1s. The default
	// is generous to avoid spurious timeouts; callers that want to fail
	// fast should pass a tighter Timeout.
	ollamaDefaultTimeout = 60 * time.Second
)

// OllamaProvider is the registry entry for Ollama. Local-only — no API key.
// Default base URL targets the standard Ollama port on localhost.
//
// DefaultModel is intentionally empty: there is no universally-installed
// Ollama model, so we require the user to pick one (via vkb-cli
// --llm-model or config.LLMModel) rather than guessing.
var OllamaProvider = &Provider{
	Name:         "ollama",
	DefaultModel: "",
	NeedsAPIKey:  false,
	factory: func(opts Options) (Cleaner, error) {
		return NewOllama(OllamaOptions{
			Model:   opts.Model,
			BaseURL: opts.BaseURL,
			Timeout: opts.Timeout,
		})
	},
}

func init() {
	register(OllamaProvider)
}

// OllamaOptions configures the Ollama Cleaner.
type OllamaOptions struct {
	Model   string        // required — must be a model the local Ollama has pulled
	BaseURL string        // optional; defaults to http://localhost:11434
	Timeout time.Duration // optional; defaults to 60s
}

// Ollama is the Ollama-backed Cleaner. Talks to /api/chat over HTTP.
type Ollama struct {
	client  *http.Client
	model   string
	baseURL string
}

// NewOllama constructs an Ollama Cleaner. Returns an error if Model is
// empty — Ollama has no universal default, the user must pick one.
func NewOllama(opts OllamaOptions) (*Ollama, error) {
	if opts.Model == "" {
		return nil, errors.New("ollama: Model is required (no universal default — try 'llama3.2' or 'qwen2.5')")
	}
	baseURL := opts.BaseURL
	if baseURL == "" {
		baseURL = ollamaDefaultBaseURL
	}
	timeout := opts.Timeout
	if timeout == 0 {
		timeout = ollamaDefaultTimeout
	}
	return &Ollama{
		client:  &http.Client{Timeout: timeout},
		model:   opts.Model,
		baseURL: strings.TrimRight(baseURL, "/"),
	}, nil
}

// chatRequest is the wire format for POST /api/chat.
type chatRequest struct {
	Model    string        `json:"model"`
	Messages []chatMessage `json:"messages"`
	Stream   bool          `json:"stream"`
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// chatResponse is one frame of the response. For non-streaming responses
// there is exactly one frame with done=true. For streaming there are many
// frames; only the final has done=true.
type chatResponse struct {
	Message    chatMessage `json:"message"`
	Done       bool        `json:"done"`
	DoneReason string      `json:"done_reason,omitempty"`
}

// Clean sends raw to /api/chat with stream=false and returns the cleaned text.
func (o *Ollama) Clean(ctx context.Context, raw string, preserveTerms []string) (string, error) {
	if o == nil || o.client == nil {
		return "", errors.New("ollama: not initialized")
	}
	prompt := renderPrompt(raw, preserveTerms)
	body, _ := json.Marshal(chatRequest{
		Model:    o.model,
		Messages: []chatMessage{{Role: "user", Content: prompt}},
		Stream:   false,
	})
	t0 := time.Now()
	log.Printf("[vkb] ollama.Clean: sending model=%s baseURL=%s rawLen=%d termCount=%d", o.model, o.baseURL, len(raw), len(preserveTerms))

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, o.baseURL+"/api/chat", bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("ollama: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := o.client.Do(req)
	if err != nil {
		log.Printf("[vkb] ollama.Clean: FAILED after %v: %v", time.Since(t0), err)
		return "", fmt.Errorf("ollama: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// Read a bit of the body for diagnostics; cap to avoid huge logs.
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("ollama: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(snippet)))
	}

	var cr chatResponse
	if err := json.NewDecoder(resp.Body).Decode(&cr); err != nil {
		return "", fmt.Errorf("ollama: decode response: %w", err)
	}
	log.Printf("[vkb] ollama.Clean: response in %v done=%v", time.Since(t0), cr.Done)
	result := strings.TrimSpace(cr.Message.Content)
	if result == "" {
		return "", errors.New("ollama: empty response")
	}
	return result, nil
}

// CleanStream streams from /api/chat (NDJSON, one JSON object per line)
// and invokes onDelta for each non-empty content chunk. The final
// accumulated text is returned at the end so the pipeline can record it.
func (o *Ollama) CleanStream(
	ctx context.Context,
	raw string,
	preserveTerms []string,
	onDelta func(string),
) (string, error) {
	if o == nil || o.client == nil {
		return "", errors.New("ollama: not initialized")
	}
	prompt := renderPrompt(raw, preserveTerms)
	body, _ := json.Marshal(chatRequest{
		Model:    o.model,
		Messages: []chatMessage{{Role: "user", Content: prompt}},
		Stream:   true,
	})
	t0 := time.Now()
	log.Printf("[vkb] ollama.CleanStream: starting model=%s baseURL=%s rawLen=%d termCount=%d", o.model, o.baseURL, len(raw), len(preserveTerms))

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, o.baseURL+"/api/chat", bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("ollama: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := o.client.Do(req)
	if err != nil {
		log.Printf("[vkb] ollama.CleanStream: FAILED after %v: %v", time.Since(t0), err)
		return "", fmt.Errorf("ollama: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("ollama: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(snippet)))
	}

	var b strings.Builder
	firstDeltaAt := time.Time{}
	scanner := bufio.NewScanner(resp.Body)
	// Allow long single-line JSON frames (Ollama can emit fairly large
	// chunks when content blocks contain longer text).
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var frame chatResponse
		if err := json.Unmarshal(line, &frame); err != nil {
			return strings.TrimSpace(b.String()), fmt.Errorf("ollama: decode frame: %w", err)
		}
		chunk := frame.Message.Content
		if chunk != "" {
			if firstDeltaAt.IsZero() {
				firstDeltaAt = time.Now()
				log.Printf("[vkb] ollama.CleanStream: first delta after %v", firstDeltaAt.Sub(t0))
			}
			b.WriteString(chunk)
			onDelta(chunk)
		}
		if frame.Done {
			break
		}
	}
	if err := scanner.Err(); err != nil {
		log.Printf("[vkb] ollama.CleanStream: scan FAILED after %v: %v", time.Since(t0), err)
		return strings.TrimSpace(b.String()), fmt.Errorf("ollama: scan: %w", err)
	}
	final := strings.TrimSpace(b.String())
	log.Printf("[vkb] ollama.CleanStream: done in %v cleanedLen=%d", time.Since(t0), len(final))
	if final == "" {
		return "", errors.New("ollama: empty stream")
	}
	return final, nil
}
