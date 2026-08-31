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

func TestOpenAICleanImage_SendsImageURLDataURL(t *testing.T) {
	pngBytes := testPNG(t)
	var body map[string]any
	s := fakeOpenAIServer(t, func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer sk-test" {
			t.Errorf("Authorization = %q, want Bearer sk-test", got)
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode req: %v", err)
		}
		_ = json.NewEncoder(w).Encode(openaiChatResponse{
			Choices: []struct {
				Message openaiChatMessage `json:"message"`
			}{{Message: openaiChatMessage{Role: "assistant", Content: "SpeakerGate, MCP"}}},
		})
	})
	defer s.Close()

	o, err := NewOpenAI(OpenAIOptions{
		APIKey: "sk-test", Model: "gpt-4o-mini", BaseURL: s.URL, Timeout: 5 * time.Second,
		Prompt: "list the terms. covered: " + PlaceholderDictionary,
	})
	if err != nil {
		t.Fatalf("NewOpenAI: %v", err)
	}
	got, err := o.CleanImage(context.Background(), Image{Data: pngBytes, MediaType: "image/png"}, []string{"WebRTC"})
	if err != nil {
		t.Fatalf("CleanImage: %v", err)
	}
	if got != "SpeakerGate, MCP" {
		t.Errorf("CleanImage = %q", got)
	}

	if body["model"] != "gpt-4o-mini" {
		t.Errorf("model = %v", body["model"])
	}
	if body["stream"] != false {
		t.Errorf("stream = %v, want false", body["stream"])
	}
	msgs, _ := body["messages"].([]any)
	if len(msgs) != 1 {
		t.Fatalf("messages = %v, want exactly one", body["messages"])
	}
	msg, _ := msgs[0].(map[string]any)
	if msg["role"] != "user" {
		t.Errorf("role = %v, want user", msg["role"])
	}
	// OpenAI vision needs `content` to be an ARRAY of parts, not the
	// plain string the text path sends.
	parts, ok := msg["content"].([]any)
	if !ok {
		t.Fatalf("content = %#v, want an array of content parts", msg["content"])
	}
	if len(parts) != 2 {
		t.Fatalf("content parts = %v, want a text part and an image_url part", parts)
	}
	textPart, _ := parts[0].(map[string]any)
	if textPart["type"] != "text" {
		t.Errorf("parts[0].type = %v, want text", textPart["type"])
	}
	if txt, _ := textPart["text"].(string); !strings.Contains(txt, "WebRTC") {
		t.Errorf("parts[0].text = %q, want the rendered prompt with the dictionary", txt)
	}
	imgPart, _ := parts[1].(map[string]any)
	if imgPart["type"] != "image_url" {
		t.Fatalf("parts[1].type = %v, want image_url", imgPart["type"])
	}
	iu, ok := imgPart["image_url"].(map[string]any)
	if !ok {
		t.Fatalf("parts[1].image_url = %#v, want an object with a url", imgPart["image_url"])
	}
	wantURL := "data:image/png;base64," + base64.StdEncoding.EncodeToString(pngBytes)
	if iu["url"] != wantURL {
		t.Errorf("image_url.url is not the expected data: URL (got %.40v...)", iu["url"])
	}
}

func TestOpenAICleanImage_ModelWithoutVisionIsReported(t *testing.T) {
	s := fakeOpenAIServer(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"message":"Invalid content type. image_url is only supported by certain models.","type":"invalid_request_error","code":null}}`))
	})
	defer s.Close()

	o, _ := NewOpenAI(OpenAIOptions{APIKey: "sk-test", Model: "gpt-3.5-turbo", BaseURL: s.URL, Timeout: 5 * time.Second})
	_, err := o.CleanImage(context.Background(), Image{Data: testPNG(t), MediaType: "image/png"}, nil)
	if !errors.Is(err, ErrNoVision) {
		t.Fatalf("err = %v, want ErrNoVision", err)
	}
}

func TestOpenAICleanImage_AuthErrorIsNotNoVision(t *testing.T) {
	s := fakeOpenAIServer(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}`))
	})
	defer s.Close()

	o, _ := NewOpenAI(OpenAIOptions{APIKey: "sk-bad", Model: "gpt-4o", BaseURL: s.URL, Timeout: 5 * time.Second})
	_, err := o.CleanImage(context.Background(), Image{Data: testPNG(t), MediaType: "image/png"}, nil)
	if err == nil {
		t.Fatal("expected an error")
	}
	if errors.Is(err, ErrNoVision) {
		t.Errorf("auth failure classified as ErrNoVision: %v", err)
	}
}

// A 429 whose message happens to mention images is still a rate limit.
func TestOpenAICleanImage_RateLimitIsNotNoVision(t *testing.T) {
	s := fakeOpenAIServer(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"error":{"message":"Rate limit reached for images per min","type":"rate_limit_error"}}`))
	})
	defer s.Close()

	o, _ := NewOpenAI(OpenAIOptions{APIKey: "sk-test", Model: "gpt-4o", BaseURL: s.URL, Timeout: 5 * time.Second})
	_, err := o.CleanImage(context.Background(), Image{Data: testPNG(t), MediaType: "image/png"}, nil)
	if err == nil {
		t.Fatal("expected an error")
	}
	if errors.Is(err, ErrNoVision) {
		t.Errorf("rate limit classified as ErrNoVision: %v", err)
	}
}

func TestOpenAICleanImage_TimeoutIsNotNoVision(t *testing.T) {
	s := fakeOpenAIServer(t, func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(300 * time.Millisecond)
	})
	defer s.Close()

	o, _ := NewOpenAI(OpenAIOptions{APIKey: "sk-test", Model: "gpt-4o", BaseURL: s.URL, Timeout: 20 * time.Millisecond})
	_, err := o.CleanImage(context.Background(), Image{Data: testPNG(t), MediaType: "image/png"}, nil)
	if err == nil {
		t.Fatal("expected a timeout error")
	}
	if errors.Is(err, ErrNoVision) {
		t.Errorf("timeout classified as ErrNoVision: %v", err)
	}
}
