package llm

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAnthropicClean_HappyPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("x-api-key") != "sk-ant-test" {
			t.Errorf("missing or wrong x-api-key header: %q", r.Header.Get("x-api-key"))
		}
		if !strings.Contains(r.URL.Path, "/messages") {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		// Read the request body to verify our prompt structure.
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode req: %v", err)
		}
		if model, _ := body["model"].(string); model == "" {
			t.Errorf("model missing in request")
		}
		// Respond with a synthetic Anthropic-shaped reply.
		resp := map[string]any{
			"id":   "msg_test",
			"type": "message",
			"role": "assistant",
			"content": []map[string]any{
				{"type": "text", "text": "Hello, world."},
			},
			"model":      "claude-sonnet-4-6",
			"stop_reason": "end_turn",
			"usage":      map[string]any{"input_tokens": 10, "output_tokens": 4},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	cleaner := NewAnthropic(AnthropicOptions{
		APIKey:  "sk-ant-test",
		Model:   "claude-sonnet-4-6",
		BaseURL: srv.URL,
		Timeout: 5 * time.Second,
	})

	got, err := cleaner.Clean(context.Background(), "hello um world", []string{"MCP"})
	if err != nil {
		t.Fatalf("Clean: %v", err)
	}
	if got != "Hello, world." {
		t.Errorf("Clean returned %q, want %q", got, "Hello, world.")
	}
}

func TestAnthropicClean_AuthError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"type":"error","error":{"type":"authentication_error","message":"invalid api key"}}`))
	}))
	defer srv.Close()

	cleaner := NewAnthropic(AnthropicOptions{
		APIKey:  "wrong",
		Model:   "claude-sonnet-4-6",
		BaseURL: srv.URL,
		Timeout: 5 * time.Second,
	})

	_, err := cleaner.Clean(context.Background(), "hi", nil)
	if err == nil {
		t.Fatalf("expected auth error, got nil")
	}
}

func TestAnthropicClean_MissingAPIKey(t *testing.T) {
	cleaner := NewAnthropic(AnthropicOptions{
		APIKey:  "",
		Model:   "claude-sonnet-4-6",
		BaseURL: "http://example.invalid",
		Timeout: time.Millisecond,
	})
	_, err := cleaner.Clean(context.Background(), "hi", nil)
	if err == nil {
		t.Fatalf("expected error for missing API key, got nil")
	}
}

func TestAnthropicClean_EmptyTextContent(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Response has content but only a tool_use block; no text.
		resp := map[string]any{
			"id":   "msg_test",
			"type": "message",
			"role": "assistant",
			"content": []map[string]any{
				{"type": "tool_use", "id": "tu_1", "name": "no_op", "input": map[string]any{}},
			},
			"model":       "claude-sonnet-4-6",
			"stop_reason": "tool_use",
			"usage":       map[string]any{"input_tokens": 1, "output_tokens": 1},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	cleaner := NewAnthropic(AnthropicOptions{
		APIKey:  "sk-ant-test",
		Model:   "claude-sonnet-4-6",
		BaseURL: srv.URL,
		Timeout: 5 * time.Second,
	})
	_, err := cleaner.Clean(context.Background(), "hi", nil)
	if err == nil {
		t.Fatalf("expected error for response with no text blocks, got nil")
	}
}
