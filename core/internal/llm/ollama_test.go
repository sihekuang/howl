package llm

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNewOllama_RequiresModel(t *testing.T) {
	if _, err := NewOllama(OllamaOptions{}); err == nil {
		t.Fatal("expected error for empty Model, got nil")
	}
}

func TestNewOllama_DefaultsBaseURLAndTimeout(t *testing.T) {
	o, err := NewOllama(OllamaOptions{Model: "x"})
	if err != nil {
		t.Fatalf("NewOllama: %v", err)
	}
	if o.baseURL != "http://localhost:11434" {
		t.Errorf("baseURL = %q, want default", o.baseURL)
	}
	if o.client.Timeout == 0 {
		t.Errorf("Timeout should default to non-zero")
	}
}

func TestNewOllama_StripsTrailingSlash(t *testing.T) {
	o, _ := NewOllama(OllamaOptions{Model: "x", BaseURL: "http://example.com:11434/"})
	if o.baseURL != "http://example.com:11434" {
		t.Errorf("baseURL = %q, want trailing slash stripped", o.baseURL)
	}
}

// fakeOllamaServer mounts /api/chat with the provided handler and returns
// the test server. Caller defers server.Close().
func fakeOllamaServer(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/api/chat", handler)
	return httptest.NewServer(mux)
}

func TestOllama_CleanNonStreaming(t *testing.T) {
	s := fakeOllamaServer(t, func(w http.ResponseWriter, r *http.Request) {
		// Verify request shape.
		var req chatRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode req: %v", err)
		}
		if req.Model != "test-model" {
			t.Errorf("model = %q, want test-model", req.Model)
		}
		if req.Stream {
			t.Errorf("Stream should be false for Clean")
		}
		if len(req.Messages) != 1 || req.Messages[0].Role != "user" {
			t.Errorf("messages malformed: %+v", req.Messages)
		}
		if !strings.Contains(req.Messages[0].Content, "raw text here") {
			t.Errorf("prompt missing raw input: %q", req.Messages[0].Content)
		}

		_ = json.NewEncoder(w).Encode(chatResponse{
			Message: chatMessage{Role: "assistant", Content: "  cleaned text  "},
			Done:    true,
		})
	})
	defer s.Close()

	o, err := NewOllama(OllamaOptions{Model: "test-model", BaseURL: s.URL})
	if err != nil {
		t.Fatalf("NewOllama: %v", err)
	}
	got, err := o.Clean(context.Background(), "raw text here", nil)
	if err != nil {
		t.Fatalf("Clean: %v", err)
	}
	if got != "cleaned text" {
		t.Errorf("Clean = %q, want %q (trimmed)", got, "cleaned text")
	}
}

func TestOllama_CleanHTTPError(t *testing.T) {
	s := fakeOllamaServer(t, func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "model 'test-model' not found", http.StatusNotFound)
	})
	defer s.Close()

	o, _ := NewOllama(OllamaOptions{Model: "test-model", BaseURL: s.URL})
	_, err := o.Clean(context.Background(), "x", nil)
	if err == nil {
		t.Fatal("expected error on 404, got nil")
	}
	if !strings.Contains(err.Error(), "404") {
		t.Errorf("error %q does not include status", err)
	}
	if !strings.Contains(err.Error(), "model 'test-model' not found") {
		t.Errorf("error %q does not include server message", err)
	}
}

func TestOllama_CleanStreamConcatenates(t *testing.T) {
	frames := []chatResponse{
		{Message: chatMessage{Role: "assistant", Content: "Hello"}, Done: false},
		{Message: chatMessage{Role: "assistant", Content: ", "}, Done: false},
		{Message: chatMessage{Role: "assistant", Content: "world."}, Done: false},
		{Message: chatMessage{Role: "assistant", Content: ""}, Done: true, DoneReason: "stop"},
	}
	s := fakeOllamaServer(t, func(w http.ResponseWriter, r *http.Request) {
		var req chatRequest
		_ = json.NewDecoder(r.Body).Decode(&req)
		if !req.Stream {
			t.Errorf("Stream should be true for CleanStream")
		}
		w.Header().Set("Content-Type", "application/x-ndjson")
		flusher, _ := w.(http.Flusher)
		for _, f := range frames {
			b, _ := json.Marshal(f)
			fmt.Fprintf(w, "%s\n", b)
			if flusher != nil {
				flusher.Flush()
			}
		}
	})
	defer s.Close()

	o, _ := NewOllama(OllamaOptions{Model: "test-model", BaseURL: s.URL})

	var deltas []string
	got, err := o.CleanStream(context.Background(), "x", nil, func(s string) {
		deltas = append(deltas, s)
	})
	if err != nil {
		t.Fatalf("CleanStream: %v", err)
	}
	if got != "Hello, world." {
		t.Errorf("got %q, want %q", got, "Hello, world.")
	}
	wantDeltas := []string{"Hello", ", ", "world."}
	if len(deltas) != len(wantDeltas) {
		t.Fatalf("delta count = %d, want %d (deltas=%v)", len(deltas), len(wantDeltas), deltas)
	}
	for i, want := range wantDeltas {
		if deltas[i] != want {
			t.Errorf("delta[%d] = %q, want %q", i, deltas[i], want)
		}
	}
}

func TestOllama_CleanStreamHTTPError(t *testing.T) {
	s := fakeOllamaServer(t, func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	})
	defer s.Close()

	o, _ := NewOllama(OllamaOptions{Model: "test-model", BaseURL: s.URL})
	_, err := o.CleanStream(context.Background(), "x", nil, func(string) {})
	if err == nil || !strings.Contains(err.Error(), "500") {
		t.Errorf("expected 500 error, got %v", err)
	}
}

func TestOllamaProvider_RegisteredAndUsable(t *testing.T) {
	p, err := ProviderByName("ollama")
	if err != nil {
		t.Fatalf("ProviderByName(ollama): %v", err)
	}
	if p.NeedsAPIKey {
		t.Errorf("ollama should not require API key")
	}
	if p.DefaultModel != "" {
		t.Errorf("ollama DefaultModel should be empty (no universal default), got %q", p.DefaultModel)
	}
	// Without a Model, factory should refuse.
	if _, err := p.New(Options{}); err == nil {
		t.Errorf("expected error from p.New with no Model")
	}
}

