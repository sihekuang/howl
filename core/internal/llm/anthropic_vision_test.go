package llm

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The wire shape is the whole point: a wrong content-block layout is
// accepted by any test that only checks "no error", and fails only
// against the real endpoint. So decode the body and assert on it.
func TestAnthropicCleanImage_SendsBase64ImageBlock(t *testing.T) {
	pngBytes := testPNG(t)
	var body map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode req: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"id": "msg_test", "type": "message", "role": "assistant",
			"content": []map[string]any{{"type": "text", "text": "SpeakerGate, DeepFilterNet"}},
			"model":   "claude-sonnet-4-6", "stop_reason": "end_turn",
			"usage": map[string]any{"input_tokens": 10, "output_tokens": 4},
		})
	}))
	defer srv.Close()

	a, err := NewAnthropic(AnthropicOptions{
		APIKey: "sk-ant-test", Model: "claude-sonnet-4-6",
		BaseURL: srv.URL, Timeout: 5 * time.Second,
		Prompt: "list the terms. covered: " + PlaceholderDictionary,
	})
	if err != nil {
		t.Fatalf("NewAnthropic: %v", err)
	}
	got, err := a.CleanImage(context.Background(), Image{Data: pngBytes, MediaType: "image/png"}, []string{"MCP"})
	if err != nil {
		t.Fatalf("CleanImage: %v", err)
	}
	if got != "SpeakerGate, DeepFilterNet" {
		t.Errorf("CleanImage = %q", got)
	}

	msgs, _ := body["messages"].([]any)
	if len(msgs) != 1 {
		t.Fatalf("messages = %v, want exactly one", body["messages"])
	}
	msg, _ := msgs[0].(map[string]any)
	if msg["role"] != "user" {
		t.Errorf("role = %v, want user", msg["role"])
	}
	content, _ := msg["content"].([]any)
	if len(content) != 2 {
		t.Fatalf("content = %v, want an image block and a text block", msg["content"])
	}
	// Anthropic documents image-before-text as the better ordering for
	// "look at this and answer" prompts.
	imgBlock, _ := content[0].(map[string]any)
	if imgBlock["type"] != "image" {
		t.Fatalf("content[0].type = %v, want image", imgBlock["type"])
	}
	src, _ := imgBlock["source"].(map[string]any)
	if src["type"] != "base64" {
		t.Errorf("source.type = %v, want base64", src["type"])
	}
	if src["media_type"] != "image/png" {
		t.Errorf("source.media_type = %v, want image/png", src["media_type"])
	}
	wantData := base64.StdEncoding.EncodeToString(pngBytes)
	if src["data"] != wantData {
		t.Errorf("source.data is not the base64 of the supplied bytes")
	}
	txtBlock, _ := content[1].(map[string]any)
	if txtBlock["type"] != "text" {
		t.Fatalf("content[1].type = %v, want text", txtBlock["type"])
	}
	text, _ := txtBlock["text"].(string)
	if !strings.Contains(text, "MCP") || !strings.Contains(text, "list the terms") {
		t.Errorf("text block = %q, want the rendered image prompt with the dictionary", text)
	}
	if strings.Contains(text, PlaceholderDictionary) {
		t.Errorf("dictionary placeholder left unsubstituted: %q", text)
	}
}

func TestAnthropicCleanImage_ModelWithoutVisionIsReported(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"type":"error","error":{"type":"invalid_request_error","message":"messages.0.content.0.image: Image content blocks are not supported by this model"}}`))
	}))
	defer srv.Close()

	a, _ := NewAnthropic(AnthropicOptions{APIKey: "sk-ant-test", Model: "m", BaseURL: srv.URL, Timeout: 5 * time.Second})
	_, err := a.CleanImage(context.Background(), Image{Data: testPNG(t), MediaType: "image/png"}, nil)
	if !errors.Is(err, ErrNoVision) {
		t.Fatalf("err = %v, want ErrNoVision", err)
	}
}

// An auth failure must never be recorded as "this model has no vision"
// — that would permanently downgrade the user over a bad key they then
// fixed.
func TestAnthropicCleanImage_AuthErrorIsNotNoVision(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}`))
	}))
	defer srv.Close()

	a, _ := NewAnthropic(AnthropicOptions{APIKey: "bad", Model: "m", BaseURL: srv.URL, Timeout: 5 * time.Second})
	_, err := a.CleanImage(context.Background(), Image{Data: testPNG(t), MediaType: "image/png"}, nil)
	if err == nil {
		t.Fatal("expected an error")
	}
	if errors.Is(err, ErrNoVision) {
		t.Errorf("auth failure classified as ErrNoVision: %v", err)
	}
}

func TestAnthropicCleanImage_TimeoutIsNotNoVision(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(300 * time.Millisecond)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	a, _ := NewAnthropic(AnthropicOptions{APIKey: "sk-ant-test", Model: "m", BaseURL: srv.URL, Timeout: 20 * time.Millisecond})
	_, err := a.CleanImage(context.Background(), Image{Data: testPNG(t), MediaType: "image/png"}, nil)
	if err == nil {
		t.Fatal("expected a timeout error")
	}
	if errors.Is(err, ErrNoVision) {
		t.Errorf("timeout classified as ErrNoVision: %v", err)
	}
}
