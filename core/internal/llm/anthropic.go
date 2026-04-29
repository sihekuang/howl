package llm

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

const defaultTimeout = 30 * time.Second

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
// for concurrent use.
func NewAnthropic(opts AnthropicOptions) *Anthropic {
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
	return &Anthropic{client: &c, model: opts.Model}
}

// Clean sends the raw transcription to Anthropic and returns the cleaned text.
// Returns an error on missing API key, network/auth failures, or empty
// responses — callers must fall back to the raw transcription on error.
func (a *Anthropic) Clean(ctx context.Context, raw string, preserveTerms []string) (string, error) {
	if a == nil || a.client == nil {
		return "", errors.New("anthropic: not initialized")
	}
	prompt := renderPrompt(raw, preserveTerms)

	msg, err := a.client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:     anthropic.Model(a.model),
		MaxTokens: 1024,
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(prompt)),
		},
	})
	if err != nil {
		return "", fmt.Errorf("anthropic: %w", err)
	}
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
