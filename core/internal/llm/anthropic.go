package llm

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

const defaultTimeout = 3 * time.Second

// AnthropicProvider is the registry entry for Anthropic and is also the
// package's default provider. The factory adapts our generic Options
// shape to Anthropic-specific construction.
var AnthropicProvider = &Provider{
	Name:         "anthropic",
	DefaultModel: "claude-sonnet-4-6",
	NeedsAPIKey:  true,
	factory: func(opts Options) (Cleaner, error) {
		return NewAnthropic(AnthropicOptions{
			APIKey:  opts.APIKey,
			Model:   opts.Model,
			BaseURL: opts.BaseURL,
			Timeout: opts.Timeout,
		})
	},
}

func init() {
	register(AnthropicProvider)
	Default = AnthropicProvider
}

// AnthropicOptions configures the Anthropic Cleaner.
type AnthropicOptions struct {
	APIKey  string
	Model   string
	BaseURL string        // optional; for testing
	Timeout time.Duration // optional; defaults to 30s
}

// Anthropic is the Anthropic-backed Cleaner implementation.
type Anthropic struct {
	client *anthropic.Client
	model  string
}

// NewAnthropic constructs an Anthropic Cleaner. The returned value is safe
// for concurrent use. Returns an error if opts.APIKey is empty; we
// validate explicitly so the SDK does not silently fall through to the
// ANTHROPIC_API_KEY environment variable, which could otherwise pick up a
// stale key the user thought they had cleared from Settings.
func NewAnthropic(opts AnthropicOptions) (*Anthropic, error) {
	if opts.APIKey == "" {
		return nil, errors.New("anthropic: APIKey is required")
	}
	timeout := opts.Timeout
	if timeout == 0 {
		timeout = defaultTimeout
	}
	httpClient := &http.Client{Timeout: timeout}

	clientOpts := []option.RequestOption{
		option.WithAPIKey(opts.APIKey),
		option.WithHTTPClient(httpClient),
	}
	if opts.BaseURL != "" {
		clientOpts = append(clientOpts, option.WithBaseURL(opts.BaseURL))
	}
	c := anthropic.NewClient(clientOpts...)
	return &Anthropic{client: &c, model: opts.Model}, nil
}

// CleanStream is the streaming counterpart of Clean. As the Anthropic
// API emits each text delta, onDelta is called with the new chunk; the
// accumulated cleaned text is also returned at the end so the pipeline
// can record the final value. Errors from the SDK are returned with
// whatever text was accumulated up to that point — the host can decide
// whether to keep what it has or fall back to the dict-corrected raw.
func (a *Anthropic) CleanStream(
	ctx context.Context,
	raw string,
	preserveTerms []string,
	onDelta func(string),
) (string, error) {
	if a == nil || a.client == nil {
		return "", errors.New("anthropic: not initialized")
	}
	prompt := renderPrompt(raw, preserveTerms)

	t0 := time.Now()
	log.Printf("[vkb] anthropic.CleanStream: starting model=%s rawLen=%d termCount=%d", a.model, len(raw), len(preserveTerms))

	stream := a.client.Messages.NewStreaming(ctx, anthropic.MessageNewParams{
		Model:     anthropic.Model(a.model),
		MaxTokens: 1024,
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(prompt)),
		},
	})

	var b strings.Builder
	firstDeltaAt := time.Time{}
	for stream.Next() {
		ev := stream.Current()
		if ev.Type == "content_block_delta" && ev.Delta.Type == "text_delta" {
			chunk := ev.Delta.Text
			if firstDeltaAt.IsZero() {
				firstDeltaAt = time.Now()
				log.Printf("[vkb] anthropic.CleanStream: first delta after %v", firstDeltaAt.Sub(t0))
			}
			if chunk != "" {
				b.WriteString(chunk)
				onDelta(chunk)
			}
		}
	}
	if err := stream.Err(); err != nil {
		log.Printf("[vkb] anthropic.CleanStream: stream FAILED after %v: %v", time.Since(t0), err)
		return strings.TrimSpace(b.String()), fmt.Errorf("anthropic: %w", err)
	}
	final := strings.TrimSpace(b.String())
	log.Printf("[vkb] anthropic.CleanStream: done in %v cleanedLen=%d", time.Since(t0), len(final))
	if final == "" {
		return "", errors.New("anthropic: empty stream")
	}
	return final, nil
}

// Clean sends the raw transcription to Anthropic and returns the cleaned text.
// Returns an error on missing API key, network/auth failures, or empty
// responses — callers must fall back to the raw transcription on error.
func (a *Anthropic) Clean(ctx context.Context, raw string, preserveTerms []string) (string, error) {
	if a == nil || a.client == nil {
		return "", errors.New("anthropic: not initialized")
	}
	prompt := renderPrompt(raw, preserveTerms)

	t0 := time.Now()
	log.Printf("[vkb] anthropic.Clean: sending model=%s rawLen=%d termCount=%d", a.model, len(raw), len(preserveTerms))
	msg, err := a.client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:     anthropic.Model(a.model),
		MaxTokens: 1024,
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(prompt)),
		},
	})
	if err != nil {
		log.Printf("[vkb] anthropic.Clean: FAILED after %v: %v", time.Since(t0), err)
		return "", fmt.Errorf("anthropic: %w", err)
	}
	log.Printf("[vkb] anthropic.Clean: response in %v, blocks=%d", time.Since(t0), len(msg.Content))
	if len(msg.Content) == 0 {
		return "", errors.New("anthropic: empty response")
	}
	var b strings.Builder
	for _, block := range msg.Content {
		// Only consider text blocks; tool-use blocks should never be
		// emitted for this prompt but we ignore them defensively.
		if block.Type == "text" {
			b.WriteString(block.Text)
		}
	}
	result := strings.TrimSpace(b.String())
	if result == "" {
		return "", errors.New("anthropic: no text content in response")
	}
	return result, nil
}
