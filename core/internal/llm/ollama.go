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
// DefaultModel is intentionally empty. When Options.Model is also empty,
// the factory queries /api/tags and auto-selects the first installed
// model (deterministic order from Ollama). To disable auto-detect and
// fail fast instead, set Options.Model explicitly.
var OllamaProvider = &Provider{
	Name:         "ollama",
	DefaultModel: "",
	NeedsAPIKey:  false,
	factory: func(opts Options) (Cleaner, error) {
		if opts.Model == "" {
			models, err := ollamaListModels(opts.BaseURL, opts.Timeout)
			if err != nil {
				return nil, fmt.Errorf("ollama: model not specified and auto-detect failed: %w", err)
			}
			if len(models) == 0 {
				return nil, errors.New("ollama: model not specified and none installed (run `ollama pull llama3.2` or similar, or pass --llm-model)")
			}
			opts.Model = models[0]
			log.Printf("[vkb] ollama: auto-detected model %q (use --llm-model to override; %d installed)", opts.Model, len(models))
		}
		return NewOllama(OllamaOptions{
			Model:   opts.Model,
			BaseURL: opts.BaseURL,
			Timeout: opts.Timeout,
		})
	},
	listLocalModels: func(opts Options) ([]string, error) {
		return ollamaListModels(opts.BaseURL, opts.Timeout)
	},
}

func init() {
	register(OllamaProvider)
}

// ollamaTagsResponse is the wire format for GET /api/tags.
type ollamaTagsResponse struct {
	Models []struct {
		Name string `json:"name"`
	} `json:"models"`
}

// ollamaListModels queries /api/tags and returns the names of installed
// models in the order Ollama returned them. Used both by the auto-detect
// path in factory and by Provider.LocalModels for the `vkb-cli providers
// --models` listing.
func ollamaListModels(baseURL string, timeout time.Duration) ([]string, error) {
	if baseURL == "" {
		baseURL = ollamaDefaultBaseURL
	}
	if timeout == 0 {
		// /api/tags is a cheap local lookup; use a short timeout so users
		// see a connection failure quickly rather than waiting 60s.
		timeout = 5 * time.Second
	}
	baseURL = strings.TrimRight(baseURL, "/")

	client := &http.Client{Timeout: timeout}
	req, err := http.NewRequest(http.MethodGet, baseURL+"/api/tags", nil)
	if err != nil {
		return nil, fmt.Errorf("ollama: build tags request: %w", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("ollama: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("ollama: tags HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(snippet)))
	}
	var tags ollamaTagsResponse
	if err := json.NewDecoder(resp.Body).Decode(&tags); err != nil {
		return nil, fmt.Errorf("ollama: decode tags: %w", err)
	}
	names := make([]string, 0, len(tags.Models))
	for _, m := range tags.Models {
		if m.Name != "" {
			names = append(names, m.Name)
		}
	}
	return names, nil
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
	// KeepAlive controls how long Ollama keeps the model loaded after
	// this request. Default Ollama behaviour is 5 minutes; we extend
	// to 30 minutes so dictation sessions don't repeatedly pay the
	// model-load cost (typically 5–15 s for 3B–8B models).
	KeepAlive string `json:"keep_alive,omitempty"`
}

// ollamaKeepAlive is sent on every chat request. "30m" stays loaded for
// 30 minutes after the last call. Ollama's default is "5m"; users could
// blow this off and unload eagerly with "0", or pin permanently with
// "-1", but 30 minutes matches typical dictation-session length.
const ollamaKeepAlive = "30m"

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
		Model:     o.model,
		Messages:  []chatMessage{{Role: "user", Content: prompt}},
		Stream:    false,
		KeepAlive: ollamaKeepAlive,
	})
	t0 := time.Now()
	log.Printf("[vkb] ollama.Clean: sending model=%s baseURL=%s rawLen=%d termCount=%d (first request after idle may take 5-15s while Ollama loads the model)", o.model, o.baseURL, len(raw), len(preserveTerms))

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
		Model:     o.model,
		Messages:  []chatMessage{{Role: "user", Content: prompt}},
		Stream:    true,
		KeepAlive: ollamaKeepAlive,
	})
	t0 := time.Now()
	log.Printf("[vkb] ollama.CleanStream: starting model=%s baseURL=%s rawLen=%d termCount=%d (first request after idle may take 5-15s while Ollama loads the model)", o.model, o.baseURL, len(raw), len(preserveTerms))

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
