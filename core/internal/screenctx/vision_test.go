package screenctx

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/llm"
)

// fakeVisionCleaner is a fakeCleaner that also accepts images, so the
// two paths can be driven with the SAME canned model output.
type fakeVisionCleaner struct {
	fakeCleaner
	gotImage llm.Image
	imgCalls int
}

func (f *fakeVisionCleaner) CleanImage(_ context.Context, img llm.Image, preserveTerms []string) (string, error) {
	f.imgCalls++
	f.gotImage = img
	f.gotTerms = preserveTerms
	return f.out, f.err
}

func resetVisionCacheForTest(t *testing.T) {
	t.Helper()
	visionMu.Lock()
	textOnlyModels = map[VisionKey]bool{}
	visionMu.Unlock()
}

// The whole point of the re-architecture is that the image path and the
// text path differ ONLY in how the model is asked. Given identical
// model output they must produce byte-identical results, or the two
// paths can silently drift.
func TestExtractImage_ConvergesWithTextPath(t *testing.T) {
	const modelOutput = "- SpeakerGate\n- DeepFilterNet\n- speakergate\n- 1234\n- " +
		"a sentence fragment far too long to be a plausible technical term at all"

	textRes, err := Extract(context.Background(), &fakeCleaner{out: modelOutput}, "window text", []string{"MCP"})
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}
	imgRes, err := ExtractImage(context.Background(),
		&fakeVisionCleaner{fakeCleaner: fakeCleaner{out: modelOutput}},
		llm.Image{Data: []byte("\x89PNG\r\n\x1a\nfake"), MediaType: "image/png"}, []string{"MCP"})
	if err != nil {
		t.Fatalf("ExtractImage: %v", err)
	}
	if !reflect.DeepEqual(textRes, imgRes) {
		t.Errorf("image path produced %#v, text path produced %#v — the two paths have drifted", imgRes, textRes)
	}
	if len(imgRes.Keywords) == 0 || len(imgRes.Dropped) == 0 {
		t.Fatalf("fixture is not exercising both keep and drop paths: %#v", imgRes)
	}
}

func TestExtractImage_PassesImageAndDictionaryThrough(t *testing.T) {
	f := &fakeVisionCleaner{fakeCleaner: fakeCleaner{out: "MCP"}}
	data := []byte("\x89PNG\r\n\x1a\npayload")
	if _, err := ExtractImage(context.Background(), f, llm.Image{Data: data, MediaType: "image/png"}, []string{"WebRTC", "DeepFilterNet"}); err != nil {
		t.Fatalf("ExtractImage: %v", err)
	}
	if f.imgCalls != 1 {
		t.Errorf("CleanImage calls = %d, want 1", f.imgCalls)
	}
	if f.calls != 0 {
		t.Errorf("text Clean must not be called on the image path (calls = %d)", f.calls)
	}
	if string(f.gotImage.Data) != string(data) || f.gotImage.MediaType != "image/png" {
		t.Errorf("provider got %#v, want the supplied image verbatim", f.gotImage)
	}
	if len(f.gotTerms) != 2 || f.gotTerms[0] != "WebRTC" {
		t.Errorf("preserveTerms = %v", f.gotTerms)
	}
}

// A Cleaner that doesn't implement VisionCleaner is exactly the
// "model can't take images" verdict, discovered by type assertion
// rather than by asking a registry.
func TestExtractImage_TextOnlyCleanerReportsNoVision(t *testing.T) {
	_, err := ExtractImage(context.Background(), &fakeCleaner{out: "x"},
		llm.Image{Data: []byte("\x89PNG"), MediaType: "image/png"}, nil)
	if !errors.Is(err, llm.ErrNoVision) {
		t.Fatalf("err = %v, want ErrNoVision", err)
	}
}

func TestExtractImage_EmptyImageSkipsProviderCall(t *testing.T) {
	f := &fakeVisionCleaner{fakeCleaner: fakeCleaner{out: "should not be called"}}
	res, err := ExtractImage(context.Background(), f, llm.Image{}, nil)
	if err != nil {
		t.Fatalf("ExtractImage: %v", err)
	}
	if f.imgCalls != 0 {
		t.Errorf("provider called for an empty image")
	}
	if res.Keywords != nil || res.Raw != "" {
		t.Errorf("res = %#v, want zero", res)
	}
}

// An oversized image is our bug or a mis-sized capture, not a model
// capability verdict — it must NOT be cached as no-vision.
func TestExtractImage_OversizeImageIsAnOrdinaryError(t *testing.T) {
	f := &fakeVisionCleaner{fakeCleaner: fakeCleaner{out: "x"}}
	huge := make([]byte, MaxImageBytes+1)
	copy(huge, "\x89PNG\r\n\x1a\n")
	_, err := ExtractImage(context.Background(), f, llm.Image{Data: huge, MediaType: "image/png"}, nil)
	if err == nil {
		t.Fatal("expected an error for an oversize image")
	}
	if errors.Is(err, llm.ErrNoVision) {
		t.Errorf("oversize image classified as ErrNoVision: %v", err)
	}
	if f.imgCalls != 0 {
		t.Errorf("provider called with an oversize image")
	}
}

func TestExtractImage_ProviderErrorPropagates(t *testing.T) {
	want := errors.New("boom")
	_, err := ExtractImage(context.Background(),
		&fakeVisionCleaner{fakeCleaner: fakeCleaner{err: want}},
		llm.Image{Data: []byte("\x89PNG"), MediaType: "image/png"}, nil)
	if !errors.Is(err, want) {
		t.Fatalf("err = %v, want %v", err, want)
	}
}

func TestVisionCache_MarkAndQuery(t *testing.T) {
	resetVisionCacheForTest(t)
	k := VisionKey{Provider: "ollama", Model: "llama3.2"}
	other := VisionKey{Provider: "ollama", Model: "llava"}
	if IsTextOnly(k) {
		t.Fatal("fresh cache should not report text-only")
	}
	MarkTextOnly(k)
	if !IsTextOnly(k) {
		t.Error("MarkTextOnly did not stick")
	}
	if IsTextOnly(other) {
		t.Error("the verdict leaked to a different model")
	}
}

// An unset provider means "the default" — it must key the same slot as
// naming that default explicitly, or switching the setting to its own
// current value would re-probe.
func TestVisionKeyFor_ResolvesDefaultProvider(t *testing.T) {
	implicit := VisionKeyFor(config.Config{LLMModel: "m"})
	explicit := VisionKeyFor(config.Config{LLMProvider: llm.Default.Name, LLMModel: "m"})
	if implicit != explicit {
		t.Errorf("implicit default key %#v != explicit %#v", implicit, explicit)
	}
	if implicit.Provider == "" {
		t.Errorf("provider left unresolved: %#v", implicit)
	}
}

func TestVisionKeyFor_UnknownProviderKeepsRawName(t *testing.T) {
	k := VisionKeyFor(config.Config{LLMProvider: "nope", LLMModel: "m"})
	if k.Provider != "nope" {
		t.Errorf("provider = %q, want the raw name preserved", k.Provider)
	}
}

// The image prompt must carry every constraint the text prompt carries
// — dropping the cap or the secret rule would change what reaches
// whisper, and what leaves the machine.
func TestExtractImagePrompt_KeepsTextPromptConstraints(t *testing.T) {
	if !strings.Contains(ExtractImagePrompt, llm.PlaceholderDictionary) {
		t.Errorf("image prompt is missing %s", llm.PlaceholderDictionary)
	}
	// No transcription to substitute — see RenderImagePrompt.
	if strings.Contains(ExtractImagePrompt, llm.PlaceholderTranscription) {
		t.Errorf("image prompt must not carry %s", llm.PlaceholderTranscription)
	}
	for _, want := range []string{
		"comma-separated", "At most 20", "verbatim", "secret", "empty string",
	} {
		if !strings.Contains(ExtractImagePrompt, want) {
			t.Errorf("image prompt is missing the %q constraint the text prompt carries", want)
		}
	}
}

func TestNewImageExtractor_BuildsAVisionCleanerWithTheImagePrompt(t *testing.T) {
	c, err := NewImageExtractor(config.Config{LLMProvider: "ollama", LLMModel: "llava"})
	if err != nil {
		t.Fatalf("NewImageExtractor: %v", err)
	}
	if _, ok := c.(llm.VisionCleaner); !ok {
		t.Fatalf("extractor (%T) does not implement llm.VisionCleaner", c)
	}
}
