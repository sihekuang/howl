package llm

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"strings"
	"testing"
)

// testPNG returns a tiny but genuinely valid PNG, so the media-type
// sniffer and every provider's encoder see real bytes rather than a
// magic-number stub that only happens to look like one.
func testPNG(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 2, 2))
	img.Set(0, 0, color.RGBA{R: 255, A: 255})
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("png.Encode: %v", err)
	}
	return buf.Bytes()
}

// Every provider that claims vision must satisfy VisionCleaner —
// callers discover support by type assertion, so a missing method is
// invisible until runtime without this.
func TestVisionCleaner_ProvidersImplementInterface(t *testing.T) {
	var _ VisionCleaner = (*Anthropic)(nil)
	var _ VisionCleaner = (*OpenAI)(nil) // LM Studio is an *OpenAI too
	var _ VisionCleaner = (*Ollama)(nil)
}

func TestIsNoVisionRejection_Classification(t *testing.T) {
	cases := []struct {
		name    string
		status  int
		message string
		want    bool
	}{
		// --- genuinely "this model has no vision" ---
		{"anthropic image block unsupported", 400,
			"messages.0.content.1.image: Image content blocks are not supported by this model", true},
		{"openai image_url", 400,
			"Invalid content type. image_url is only supported by certain models.", true},
		{"ollama", 400, "model 'llama3.2' does not support images", true},
		{"lmstudio", 400, "Vision is not supported by this model", true},
		{"unprocessable", 422, "this model does not accept image input", true},

		// --- ordinary failures that must NEVER be cached as no-vision ---
		{"auth", 401, "Incorrect API key provided", false},
		{"forbidden", 403, "You do not have access to this model", false},
		{"rate limit mentioning images", 429,
			"Rate limit reached for images per minute", false},
		{"server error mentioning images", 500,
			"model does not support images", false},
		{"overloaded", 529, "Overloaded", false},
		{"unrelated 400", 400, "max_tokens: must be greater than 0", false},
		{"model not found", 404, "The model `gpt-9` does not exist", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isNoVisionRejection(tc.status, tc.message); got != tc.want {
				t.Errorf("isNoVisionRejection(%d, %q) = %v, want %v", tc.status, tc.message, got, tc.want)
			}
		})
	}
}

func TestDetectImageMediaType_PNG(t *testing.T) {
	got, err := DetectImageMediaType(testPNG(t))
	if err != nil {
		t.Fatalf("DetectImageMediaType: %v", err)
	}
	if got != "image/png" {
		t.Errorf("media type = %q, want image/png", got)
	}
}

func TestDetectImageMediaType_RejectsNonImage(t *testing.T) {
	if _, err := DetectImageMediaType([]byte("this is not an image at all")); err == nil {
		t.Error("expected an error for non-image bytes, got nil")
	}
	if _, err := DetectImageMediaType(nil); err == nil {
		t.Error("expected an error for empty bytes, got nil")
	}
}

func TestRenderImagePrompt_SubstitutesDictionary(t *testing.T) {
	got := RenderImagePrompt("terms: "+PlaceholderDictionary, []string{"SpeakerGate", "MCP"})
	if got != "terms: SpeakerGate, MCP" {
		t.Errorf("RenderImagePrompt = %q", got)
	}
}

// The image prompt has no transcription to substitute — the image IS
// the input — so RenderPrompt's "Raw transcription:" trailer must never
// be appended, or the model is told to read text that isn't there.
func TestRenderImagePrompt_NeverAppendsTranscriptionTrailer(t *testing.T) {
	got := RenderImagePrompt("read the screenshot. covered: "+PlaceholderDictionary, nil)
	if strings.Contains(got, "Raw transcription") {
		t.Errorf("RenderImagePrompt appended a transcription trailer: %q", got)
	}
	if !strings.Contains(got, "(none)") {
		t.Errorf("empty preserveTerms should render as (none): %q", got)
	}
}
