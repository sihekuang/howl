package llm

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestOllamaCleanImage_SendsImagesArray(t *testing.T) {
	pngBytes := testPNG(t)
	var body map[string]any
	s := fakeOllamaServer(t, func(w http.ResponseWriter, r *http.Request) {
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode req: %v", err)
		}
		_ = json.NewEncoder(w).Encode(chatResponse{
			Message: chatMessage{Role: "assistant", Content: "SpeakerGate, MCP"},
			Done:    true,
		})
	})
	defer s.Close()

	o, err := NewOllama(OllamaOptions{
		Model: "llava", BaseURL: s.URL, Timeout: 5 * time.Second,
		Prompt: "list the terms. covered: " + PlaceholderDictionary,
	})
	if err != nil {
		t.Fatalf("NewOllama: %v", err)
	}
	got, err := o.CleanImage(context.Background(), Image{Data: pngBytes, MediaType: "image/png"}, []string{"WebRTC"})
	if err != nil {
		t.Fatalf("CleanImage: %v", err)
	}
	if got != "SpeakerGate, MCP" {
		t.Errorf("CleanImage = %q", got)
	}

	if body["model"] != "llava" {
		t.Errorf("model = %v", body["model"])
	}
	msgs, _ := body["messages"].([]any)
	if len(msgs) != 1 {
		t.Fatalf("messages = %v, want exactly one", body["messages"])
	}
	msg, _ := msgs[0].(map[string]any)
	// Ollama keeps `content` a plain string and carries the image in a
	// sibling `images` array of bare base64 strings — no data: prefix.
	content, _ := msg["content"].(string)
	if !strings.Contains(content, "WebRTC") || !strings.Contains(content, "list the terms") {
		t.Errorf("content = %q, want the rendered prompt with the dictionary", content)
	}
	images, ok := msg["images"].([]any)
	if !ok {
		t.Fatalf("messages[0].images = %#v, want an array of base64 strings", msg["images"])
	}
	if len(images) != 1 {
		t.Fatalf("images = %v, want exactly one", images)
	}
	want := base64.StdEncoding.EncodeToString(pngBytes)
	if images[0] != want {
		t.Errorf("images[0] is not the bare base64 of the supplied bytes (got %.30v...)", images[0])
	}
	if s, _ := images[0].(string); strings.HasPrefix(s, "data:") {
		t.Errorf("images[0] must NOT be a data: URL — Ollama wants bare base64")
	}
}

func TestOllamaCleanImage_ModelWithoutVisionIsReported(t *testing.T) {
	s := fakeOllamaServer(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"model 'llama3.2' does not support images"}`))
	})
	defer s.Close()

	o, _ := NewOllama(OllamaOptions{Model: "llama3.2", BaseURL: s.URL, Timeout: 5 * time.Second})
	_, err := o.CleanImage(context.Background(), Image{Data: testPNG(t), MediaType: "image/png"}, nil)
	if !errors.Is(err, ErrNoVision) {
		t.Fatalf("err = %v, want ErrNoVision", err)
	}
}

// Ollama's own 500s are transient (model load OOM, runner crash) and
// must not permanently downgrade the model, even when the body happens
// to mention images.
func TestOllamaCleanImage_ServerErrorIsNotNoVision(t *testing.T) {
	s := fakeOllamaServer(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"failed to load model for images"}`))
	})
	defer s.Close()

	o, _ := NewOllama(OllamaOptions{Model: "llava", BaseURL: s.URL, Timeout: 5 * time.Second})
	_, err := o.CleanImage(context.Background(), Image{Data: testPNG(t), MediaType: "image/png"}, nil)
	if err == nil {
		t.Fatal("expected an error")
	}
	if errors.Is(err, ErrNoVision) {
		t.Errorf("500 classified as ErrNoVision: %v", err)
	}
}

func TestOllamaCleanImage_TimeoutIsNotNoVision(t *testing.T) {
	s := fakeOllamaServer(t, func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(300 * time.Millisecond)
	})
	defer s.Close()

	o, _ := NewOllama(OllamaOptions{Model: "llava", BaseURL: s.URL, Timeout: 20 * time.Millisecond})
	_, err := o.CleanImage(context.Background(), Image{Data: testPNG(t), MediaType: "image/png"}, nil)
	if err == nil {
		t.Fatal("expected a timeout error")
	}
	if errors.Is(err, ErrNoVision) {
		t.Errorf("timeout classified as ErrNoVision: %v", err)
	}
}
