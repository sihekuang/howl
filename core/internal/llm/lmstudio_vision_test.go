package llm

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

// LM Studio is OpenAI-compatible, so a factory-built LM Studio Cleaner
// must both satisfy VisionCleaner and put the image on the wire in
// OpenAI's image_url shape — including omitting Authorization.
func TestLMStudioCleanImage_UsesOpenAIShapeWithoutAuthHeader(t *testing.T) {
	pngBytes := testPNG(t)
	var body map[string]any
	mux := http.NewServeMux()
	mux.HandleFunc("/models", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(lmStudioModelsResponse{Data: []struct {
			ID string `json:"id"`
		}{{ID: "qwen2.5-vl-7b"}}})
	})
	mux.HandleFunc("/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "" {
			t.Errorf("lmstudio: unexpected Authorization header %q", got)
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode req: %v", err)
		}
		_ = json.NewEncoder(w).Encode(openaiChatResponse{
			Choices: []struct {
				Message openaiChatMessage `json:"message"`
			}{{Message: openaiChatMessage{Role: "assistant", Content: "MCP"}}},
		})
	})
	s := httptest.NewServer(mux)
	defer s.Close()

	c, err := LMStudioProvider.New(Options{BaseURL: s.URL})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	vc, ok := c.(VisionCleaner)
	if !ok {
		t.Fatalf("LM Studio Cleaner (%T) does not implement VisionCleaner", c)
	}
	if _, err := vc.CleanImage(context.Background(), Image{Data: pngBytes, MediaType: "image/png"}, nil); err != nil {
		t.Fatalf("CleanImage: %v", err)
	}

	msgs, _ := body["messages"].([]any)
	if len(msgs) != 1 {
		t.Fatalf("messages = %v", body["messages"])
	}
	msg, _ := msgs[0].(map[string]any)
	parts, ok := msg["content"].([]any)
	if !ok || len(parts) != 2 {
		t.Fatalf("content = %#v, want two content parts", msg["content"])
	}
	imgPart, _ := parts[1].(map[string]any)
	iu, _ := imgPart["image_url"].(map[string]any)
	want := "data:image/png;base64," + base64.StdEncoding.EncodeToString(pngBytes)
	if imgPart["type"] != "image_url" || iu["url"] != want {
		t.Errorf("image part = %#v, want an image_url data: URL", imgPart)
	}
}

func TestLMStudioCleanImage_ModelWithoutVisionIsReported(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/chat/completions", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"Vision is not supported by this model"}`))
	})
	s := httptest.NewServer(mux)
	defer s.Close()

	c, err := LMStudioProvider.New(Options{BaseURL: s.URL, Model: "qwen2.5-7b-instruct"})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	_, err = c.(VisionCleaner).CleanImage(context.Background(), Image{Data: testPNG(t), MediaType: "image/png"}, nil)
	if !errors.Is(err, ErrNoVision) {
		t.Fatalf("err = %v, want ErrNoVision", err)
	}
}
