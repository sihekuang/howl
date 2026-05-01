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

func TestNewOpenAI_RequiresAPIKey(t *testing.T) {
	if _, err := NewOpenAI(OpenAIOptions{Model: "gpt-4o-mini"}); err == nil {
		t.Fatal("expected error for empty APIKey, got nil")
	}
}

func TestNewOpenAI_DefaultsBaseURLAndTimeout(t *testing.T) {
	o, err := NewOpenAI(OpenAIOptions{APIKey: "sk-test", Model: "gpt-4o-mini"})
	if err != nil {
		t.Fatalf("NewOpenAI: %v", err)
	}
	if o.baseURL != openaiDefaultBaseURL {
		t.Errorf("baseURL = %q, want default", o.baseURL)
	}
	if o.client.Timeout == 0 {
		t.Errorf("Timeout should default to non-zero")
	}
}

func TestNewOpenAI_StripsTrailingSlash(t *testing.T) {
	o, _ := NewOpenAI(OpenAIOptions{APIKey: "sk-test", Model: "x", BaseURL: "http://example.com/v1/"})
	if o.baseURL != "http://example.com/v1" {
		t.Errorf("baseURL = %q, want trailing slash stripped", o.baseURL)
	}
}

// fakeOpenAIServer mounts /chat/completions with the provided handler.
func fakeOpenAIServer(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/chat/completions", handler)
	return httptest.NewServer(mux)
}

func TestOpenAIClean_HappyPath(t *testing.T) {
	s := fakeOpenAIServer(t, func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer sk-test" {
			t.Errorf("Authorization = %q, want Bearer sk-test", got)
		}
		var req openaiChatRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode req: %v", err)
		}
		if req.Model != "gpt-4o-mini" {
			t.Errorf("model = %q, want gpt-4o-mini", req.Model)
		}
		if req.Stream {
			t.Errorf("Stream should be false for Clean")
		}
		if !strings.Contains(req.Messages[0].Content, "raw text here") {
			t.Errorf("prompt missing raw input: %q", req.Messages[0].Content)
		}
		_ = json.NewEncoder(w).Encode(openaiChatResponse{
			Choices: []struct {
				Message openaiChatMessage `json:"message"`
			}{
				{Message: openaiChatMessage{Role: "assistant", Content: "  Hello, world.  "}},
			},
		})
	})
	defer s.Close()

	o, err := NewOpenAI(OpenAIOptions{
		APIKey:  "sk-test",
		Model:   "gpt-4o-mini",
		BaseURL: s.URL,
		Timeout: 5 * time.Second,
	})
	if err != nil {
		t.Fatalf("NewOpenAI: %v", err)
	}
	got, err := o.Clean(context.Background(), "raw text here", []string{"MCP"})
	if err != nil {
		t.Fatalf("Clean: %v", err)
	}
	if got != "Hello, world." {
		t.Errorf("Clean = %q, want %q (trimmed)", got, "Hello, world.")
	}
}

func TestOpenAIClean_AuthError(t *testing.T) {
	s := fakeOpenAIServer(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}`))
	})
	defer s.Close()

	o, _ := NewOpenAI(OpenAIOptions{APIKey: "sk-bad", Model: "gpt-4o-mini", BaseURL: s.URL, Timeout: 5 * time.Second})
	_, err := o.Clean(context.Background(), "x", nil)
	if err == nil {
		t.Fatal("expected auth error, got nil")
	}
	// The structured error message should be lifted into the Go error
	// — that's what makes 401s actionable for users.
	if !strings.Contains(err.Error(), "Incorrect API key") {
		t.Errorf("error %q should mention 'Incorrect API key'", err)
	}
}

func TestOpenAIClean_EmptyChoices(t *testing.T) {
	s := fakeOpenAIServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(openaiChatResponse{Choices: nil})
	})
	defer s.Close()

	o, _ := NewOpenAI(OpenAIOptions{APIKey: "sk-test", Model: "gpt-4o-mini", BaseURL: s.URL, Timeout: 5 * time.Second})
	_, err := o.Clean(context.Background(), "x", nil)
	if err == nil {
		t.Fatal("expected error for empty choices, got nil")
	}
}

// sseOpenAIHandler emits a synthetic OpenAI SSE stream with the given
// content deltas, terminated by `data: [DONE]`. Mirrors the real wire
// shape: `data: {…}\n\n` per frame.
func sseOpenAIHandler(deltas []string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "no flusher", http.StatusInternalServerError)
			return
		}
		emit := func(payload string) {
			fmt.Fprintf(w, "data: %s\n\n", payload)
			flusher.Flush()
		}
		for _, d := range deltas {
			b, _ := json.Marshal(map[string]any{
				"choices": []map[string]any{
					{"delta": map[string]any{"content": d}, "finish_reason": nil},
				},
			})
			emit(string(b))
		}
		// Final stop frame (delta empty, finish_reason set), then DONE.
		stopFrame, _ := json.Marshal(map[string]any{
			"choices": []map[string]any{
				{"delta": map[string]any{}, "finish_reason": "stop"},
			},
		})
		emit(string(stopFrame))
		emit("[DONE]")
	}
}

func TestOpenAICleanStream_HappyPath(t *testing.T) {
	s := fakeOpenAIServer(t, sseOpenAIHandler([]string{"Hello", ", ", "world", "."}))
	defer s.Close()

	o, err := NewOpenAI(OpenAIOptions{APIKey: "sk-test", Model: "gpt-4o-mini", BaseURL: s.URL, Timeout: 5 * time.Second})
	if err != nil {
		t.Fatalf("NewOpenAI: %v", err)
	}
	var got []string
	var mu sync.Mutex
	final, err := o.CleanStream(context.Background(), "hello world", nil, func(d string) {
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
		t.Errorf("delta sequence: got %v want %v", got, want)
	}
	if final != "Hello, world." {
		t.Errorf("final = %q, want %q", final, "Hello, world.")
	}
}

func TestOpenAICleanStream_EmptyStreamReturnsError(t *testing.T) {
	s := fakeOpenAIServer(t, sseOpenAIHandler(nil))
	defer s.Close()

	o, _ := NewOpenAI(OpenAIOptions{APIKey: "sk-test", Model: "gpt-4o-mini", BaseURL: s.URL, Timeout: 5 * time.Second})
	final, err := o.CleanStream(context.Background(), "hi", nil, func(_ string) {})
	if err == nil {
		t.Fatalf("expected empty-stream error, got final=%q nil err", final)
	}
}
