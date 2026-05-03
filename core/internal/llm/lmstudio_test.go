package llm

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fakeLMStudioServer mounts /models (for auto-detect / LocalModels) and
// /chat/completions (so factory-built Cleaners can be exercised end-to-end
// without a real LM Studio process). modelIDs=nil means /models returns
// 503 — simulates LM Studio not running.
func fakeLMStudioServer(t *testing.T, modelIDs []string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	if modelIDs != nil {
		mux.HandleFunc("/models", func(w http.ResponseWriter, _ *http.Request) {
			var resp lmStudioModelsResponse
			for _, id := range modelIDs {
				resp.Data = append(resp.Data, struct {
					ID string `json:"id"`
				}{ID: id})
			}
			_ = json.NewEncoder(w).Encode(resp)
		})
	} else {
		mux.HandleFunc("/models", func(w http.ResponseWriter, _ *http.Request) {
			http.Error(w, "service unavailable", http.StatusServiceUnavailable)
		})
	}
	mux.HandleFunc("/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		// The Cleaner must NOT send Authorization when no API key is set.
		// LM Studio tolerates either, but defending the contract here means
		// a regression in the OpenAI client's header handling fails loudly.
		if got := r.Header.Get("Authorization"); got != "" {
			t.Errorf("lmstudio: unexpected Authorization header %q", got)
		}
		_ = json.NewEncoder(w).Encode(openaiChatResponse{
			Choices: []struct {
				Message openaiChatMessage `json:"message"`
			}{
				{Message: openaiChatMessage{Role: "assistant", Content: "ok"}},
			},
		})
	})
	return httptest.NewServer(mux)
}

func TestLMStudioListModels_ReturnsIDs(t *testing.T) {
	s := fakeLMStudioServer(t, []string{"qwen2.5-7b-instruct", "llama-3.2-3b"})
	defer s.Close()

	got, err := lmStudioListModels(s.URL, 0)
	if err != nil {
		t.Fatalf("lmStudioListModels: %v", err)
	}
	want := []string{"qwen2.5-7b-instruct", "llama-3.2-3b"}
	if len(got) != len(want) {
		t.Fatalf("len = %d, want %d (got %v)", len(got), len(want), got)
	}
	for i, w := range want {
		if got[i] != w {
			t.Errorf("got[%d] = %q, want %q", i, got[i], w)
		}
	}
}

func TestLMStudioListModels_EmptyList(t *testing.T) {
	s := fakeLMStudioServer(t, []string{})
	defer s.Close()
	got, err := lmStudioListModels(s.URL, 0)
	if err != nil {
		t.Fatalf("lmStudioListModels: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected empty list, got %v", got)
	}
}

func TestLMStudioListModels_HTTPError(t *testing.T) {
	s := fakeLMStudioServer(t, nil)
	defer s.Close()
	_, err := lmStudioListModels(s.URL, 0)
	if err == nil {
		t.Fatal("expected error on 503, got nil")
	}
	if !strings.Contains(err.Error(), "503") {
		t.Errorf("error %q does not mention 503", err)
	}
}

func TestLMStudioProvider_RegisteredAndUsable(t *testing.T) {
	p, err := ProviderByName("lmstudio")
	if err != nil {
		t.Fatalf("ProviderByName(lmstudio): %v", err)
	}
	if p.NeedsAPIKey {
		t.Errorf("lmstudio should not require API key")
	}
	if p.DefaultModel != "" {
		t.Errorf("lmstudio DefaultModel should be empty (no universal default), got %q", p.DefaultModel)
	}
}

func TestLMStudioProvider_LocalModelsExposed(t *testing.T) {
	s := fakeLMStudioServer(t, []string{"qwen2.5-7b-instruct", "llama-3.2-3b"})
	defer s.Close()

	got, err := LMStudioProvider.LocalModels(Options{BaseURL: s.URL})
	if err != nil {
		t.Fatalf("LocalModels: %v", err)
	}
	if len(got) != 2 {
		t.Errorf("got %d models, want 2 (%v)", len(got), got)
	}
}

func TestLMStudioProvider_AutoDetectPicksFirst(t *testing.T) {
	s := fakeLMStudioServer(t, []string{"qwen2.5-7b-instruct", "llama-3.2-3b"})
	defer s.Close()

	c, err := LMStudioProvider.New(Options{BaseURL: s.URL})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	o, ok := c.(*OpenAI)
	if !ok {
		t.Fatalf("Cleaner is %T, want *OpenAI (lmstudio reuses the OpenAI HTTP client)", c)
	}
	if o.model != "qwen2.5-7b-instruct" {
		t.Errorf("auto-detect picked %q, want first listed (%q)", o.model, "qwen2.5-7b-instruct")
	}
	if o.apiKey != "" {
		t.Errorf("apiKey should be empty for lmstudio, got %q", o.apiKey)
	}
}

func TestLMStudioProvider_AutoDetectNoModelsErrors(t *testing.T) {
	s := fakeLMStudioServer(t, []string{})
	defer s.Close()
	_, err := LMStudioProvider.New(Options{BaseURL: s.URL})
	if err == nil {
		t.Fatal("expected error when no models available")
	}
	if !strings.Contains(err.Error(), "none available") {
		t.Errorf("error %q does not mention 'none available'", err)
	}
}

func TestLMStudioProvider_ExplicitModelSkipsAutoDetect(t *testing.T) {
	modelsHit := 0
	mux := http.NewServeMux()
	mux.HandleFunc("/models", func(w http.ResponseWriter, _ *http.Request) {
		modelsHit++
		_ = json.NewEncoder(w).Encode(lmStudioModelsResponse{})
	})
	mux.HandleFunc("/chat/completions", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(openaiChatResponse{
			Choices: []struct {
				Message openaiChatMessage `json:"message"`
			}{
				{Message: openaiChatMessage{Role: "assistant", Content: "ok"}},
			},
		})
	})
	s := httptest.NewServer(mux)
	defer s.Close()

	if _, err := LMStudioProvider.New(Options{Model: "user-pick", BaseURL: s.URL}); err != nil {
		t.Fatalf("New: %v", err)
	}
	if modelsHit != 0 {
		t.Errorf("expected /v1/models NOT called when Model is set; got %d hits", modelsHit)
	}
}

func TestLMStudioProvider_EndToEndCleanOmitsAuthHeader(t *testing.T) {
	s := fakeLMStudioServer(t, []string{"qwen2.5-7b-instruct"})
	defer s.Close()

	c, err := LMStudioProvider.New(Options{BaseURL: s.URL})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	got, err := c.Clean(context.Background(), "raw text", nil)
	if err != nil {
		t.Fatalf("Clean: %v", err)
	}
	if got != "ok" {
		t.Errorf("Clean = %q, want %q", got, "ok")
	}
}
