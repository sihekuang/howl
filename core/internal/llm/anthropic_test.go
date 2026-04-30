package llm

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
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

	cleaner, err := NewAnthropic(AnthropicOptions{
		APIKey:  "sk-ant-test",
		Model:   "claude-sonnet-4-6",
		BaseURL: srv.URL,
		Timeout: 5 * time.Second,
	})
	if err != nil {
		t.Fatalf("NewAnthropic: %v", err)
	}

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

	cleaner, err := NewAnthropic(AnthropicOptions{
		APIKey:  "wrong",
		Model:   "claude-sonnet-4-6",
		BaseURL: srv.URL,
		Timeout: 5 * time.Second,
	})
	if err != nil {
		t.Fatalf("NewAnthropic: %v", err)
	}

	_, err = cleaner.Clean(context.Background(), "hi", nil)
	if err == nil {
		t.Fatalf("expected auth error, got nil")
	}
}

func TestAnthropicClean_MissingAPIKey(t *testing.T) {
	cleaner, err := NewAnthropic(AnthropicOptions{
		APIKey:  "",
		Model:   "claude-sonnet-4-6",
		BaseURL: "http://example.invalid",
		Timeout: time.Millisecond,
	})
	if err == nil {
		t.Fatalf("expected NewAnthropic to fail with empty APIKey, got nil")
	}
	if cleaner != nil {
		t.Fatalf("expected nil cleaner on error, got %v", cleaner)
	}
}

// sseStreamHandler returns an Anthropic-shaped SSE stream that emits
// the given text deltas in order. Format mirrors the wire protocol
// the SDK consumes via Messages.NewStreaming.
func sseStreamHandler(deltas []string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "no flusher", http.StatusInternalServerError)
			return
		}

		write := func(eventType, data string) {
			fmt.Fprintf(w, "event: %s\ndata: %s\n\n", eventType, data)
			flusher.Flush()
		}

		write("message_start", `{"type":"message_start","message":{"id":"msg_x","type":"message","role":"assistant","content":[],"model":"claude","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":0}}}`)
		write("content_block_start", `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`)
		for _, d := range deltas {
			b, _ := json.Marshal(map[string]any{
				"type":  "content_block_delta",
				"index": 0,
				"delta": map[string]any{"type": "text_delta", "text": d},
			})
			write("content_block_delta", string(b))
		}
		write("content_block_stop", `{"type":"content_block_stop","index":0}`)
		write("message_delta", `{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":4}}`)
		write("message_stop", `{"type":"message_stop"}`)
	}
}

func TestAnthropicCleanStream_HappyPath(t *testing.T) {
	srv := httptest.NewServer(sseStreamHandler([]string{"Hello", ", ", "world", "."}))
	defer srv.Close()

	cleaner, err := NewAnthropic(AnthropicOptions{
		APIKey:  "sk-ant-test",
		Model:   "claude-sonnet-4-6",
		BaseURL: srv.URL,
		Timeout: 5 * time.Second,
	})
	if err != nil {
		t.Fatalf("NewAnthropic: %v", err)
	}

	var got []string
	var mu sync.Mutex
	final, err := cleaner.CleanStream(context.Background(), "hello world", nil, func(d string) {
		mu.Lock()
		got = append(got, d)
		mu.Unlock()
	})
	if err != nil {
		t.Fatalf("CleanStream: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if want := []string{"Hello", ", ", "world", "."}; !equalSlices(got, want) {
		t.Errorf("delta sequence wrong: got %v want %v", got, want)
	}
	if final != "Hello, world." {
		t.Errorf("final cleaned text = %q, want %q", final, "Hello, world.")
	}
}

func TestAnthropicCleanStream_EmptyStreamReturnsError(t *testing.T) {
	srv := httptest.NewServer(sseStreamHandler(nil)) // no deltas
	defer srv.Close()

	cleaner, _ := NewAnthropic(AnthropicOptions{
		APIKey: "sk-ant-test", Model: "claude-sonnet-4-6", BaseURL: srv.URL, Timeout: 5 * time.Second,
	})
	final, err := cleaner.CleanStream(context.Background(), "hi", nil, func(_ string) {})
	if err == nil {
		t.Fatalf("expected empty-stream error, got final=%q nil err", final)
	}
}

func equalSlices[T comparable](a, b []T) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
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

	cleaner, err := NewAnthropic(AnthropicOptions{
		APIKey:  "sk-ant-test",
		Model:   "claude-sonnet-4-6",
		BaseURL: srv.URL,
		Timeout: 5 * time.Second,
	})
	if err != nil {
		t.Fatalf("NewAnthropic: %v", err)
	}
	_, err = cleaner.Clean(context.Background(), "hi", nil)
	if err == nil {
		t.Fatalf("expected error for response with no text blocks, got nil")
	}
}
