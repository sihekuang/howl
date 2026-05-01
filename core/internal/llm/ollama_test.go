package llm

import (
	"context"
	"encoding/json"
	"errors"
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
}

// fakeOllamaWithTags returns a server handling both /api/tags and /api/chat
// using the supplied installed-models list. tagModels=nil means /api/tags
// returns 503 (simulates Ollama not running).
func fakeOllamaWithTags(t *testing.T, tagModels []string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	if tagModels != nil {
		mux.HandleFunc("/api/tags", func(w http.ResponseWriter, _ *http.Request) {
			var resp ollamaTagsResponse
			for _, n := range tagModels {
				resp.Models = append(resp.Models, struct {
					Name string `json:"name"`
				}{Name: n})
			}
			_ = json.NewEncoder(w).Encode(resp)
		})
	} else {
		mux.HandleFunc("/api/tags", func(w http.ResponseWriter, _ *http.Request) {
			http.Error(w, "service unavailable", http.StatusServiceUnavailable)
		})
	}
	mux.HandleFunc("/api/chat", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(chatResponse{
			Message: chatMessage{Role: "assistant", Content: "ok"},
			Done:    true,
		})
	})
	return httptest.NewServer(mux)
}

func TestOllamaListModels_ReturnsNames(t *testing.T) {
	s := fakeOllamaWithTags(t, []string{"llama3.2:latest", "qwen2.5:7b", "mistral"})
	defer s.Close()

	got, err := ollamaListModels(s.URL, 0)
	if err != nil {
		t.Fatalf("ollamaListModels: %v", err)
	}
	want := []string{"llama3.2:latest", "qwen2.5:7b", "mistral"}
	if len(got) != len(want) {
		t.Fatalf("len = %d, want %d (got %v)", len(got), len(want), got)
	}
	for i, w := range want {
		if got[i] != w {
			t.Errorf("got[%d] = %q, want %q", i, got[i], w)
		}
	}
}

func TestOllamaListModels_EmptyList(t *testing.T) {
	s := fakeOllamaWithTags(t, []string{})
	defer s.Close()
	got, err := ollamaListModels(s.URL, 0)
	if err != nil {
		t.Fatalf("ollamaListModels: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected empty list, got %v", got)
	}
}

func TestOllamaListModels_HTTPError(t *testing.T) {
	s := fakeOllamaWithTags(t, nil)
	defer s.Close()
	_, err := ollamaListModels(s.URL, 0)
	if err == nil {
		t.Fatal("expected error on 503, got nil")
	}
	if !strings.Contains(err.Error(), "503") {
		t.Errorf("error %q does not mention 503", err)
	}
}

func TestOllamaProvider_LocalModelsExposed(t *testing.T) {
	s := fakeOllamaWithTags(t, []string{"llama3.2", "qwen2.5"})
	defer s.Close()

	got, err := OllamaProvider.LocalModels(Options{BaseURL: s.URL})
	if err != nil {
		t.Fatalf("LocalModels: %v", err)
	}
	if len(got) != 2 {
		t.Errorf("got %d models, want 2 (%v)", len(got), got)
	}
}

func TestAnthropicProvider_LocalModelsNotSupported(t *testing.T) {
	_, err := AnthropicProvider.LocalModels(Options{})
	if !errors.Is(err, ErrNotSupported) {
		t.Errorf("expected ErrNotSupported, got %v", err)
	}
}

func TestOllamaProvider_AutoDetectPicksFirst(t *testing.T) {
	s := fakeOllamaWithTags(t, []string{"llama3.2:latest", "qwen2.5:7b"})
	defer s.Close()

	c, err := OllamaProvider.New(Options{BaseURL: s.URL})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	o, ok := c.(*Ollama)
	if !ok {
		t.Fatalf("Cleaner is %T, want *Ollama", c)
	}
	if o.model != "llama3.2:latest" {
		t.Errorf("auto-detect picked %q, want first listed (%q)", o.model, "llama3.2:latest")
	}
}

func TestOllamaProvider_AutoDetectNoModelsErrors(t *testing.T) {
	s := fakeOllamaWithTags(t, []string{})
	defer s.Close()
	_, err := OllamaProvider.New(Options{BaseURL: s.URL})
	if err == nil {
		t.Fatal("expected error when no models installed")
	}
	if !strings.Contains(err.Error(), "none installed") {
		t.Errorf("error %q does not mention 'none installed'", err)
	}
}

func TestOllamaProvider_ExplicitModelSkipsAutoDetect(t *testing.T) {
	tagsHit := 0
	mux := http.NewServeMux()
	mux.HandleFunc("/api/tags", func(w http.ResponseWriter, _ *http.Request) {
		tagsHit++
		_ = json.NewEncoder(w).Encode(ollamaTagsResponse{})
	})
	mux.HandleFunc("/api/chat", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(chatResponse{
			Message: chatMessage{Role: "assistant", Content: "ok"},
			Done:    true,
		})
	})
	s := httptest.NewServer(mux)
	defer s.Close()

	if _, err := OllamaProvider.New(Options{Model: "user-pick", BaseURL: s.URL}); err != nil {
		t.Fatalf("New: %v", err)
	}
	if tagsHit != 0 {
		t.Errorf("expected /api/tags NOT called when Model is set; got %d hits", tagsHit)
	}
}

