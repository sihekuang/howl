package screenctx

import (
	"context"
	"errors"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/voice-keyboard/core/internal/config"
)

// fakeCleaner records what it was asked to clean and returns a canned
// response, mirroring the fakeCleaner pattern in internal/pipeline.
type fakeCleaner struct {
	out      string
	err      error
	gotRaw   string
	gotTerms []string
	calls    int
}

func (f *fakeCleaner) Clean(_ context.Context, raw string, preserveTerms []string) (string, error) {
	f.calls++
	f.gotRaw = raw
	f.gotTerms = preserveTerms
	return f.out, f.err
}

func TestExtract_SanitizesProviderResponse(t *testing.T) {
	f := &fakeCleaner{out: "- SpeakerGate\n- DeepFilterNet\n- speakergate"}
	res, err := Extract(context.Background(), f, "some window text", nil)
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}
	got := res.Keywords
	want := []string{"SpeakerGate", "DeepFilterNet"}
	if len(got) != len(want) {
		t.Fatalf("Extract() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("Extract()[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestExtract_TruncatesWindowText(t *testing.T) {
	f := &fakeCleaner{out: "MCP"}
	huge := strings.Repeat("x", MaxWindowTextBytes*2)
	if _, err := Extract(context.Background(), f, huge, nil); err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if len(f.gotRaw) > MaxWindowTextBytes {
		t.Errorf("provider received %d bytes, want <= %d", len(f.gotRaw), MaxWindowTextBytes)
	}
}

func TestExtract_PassesDictionaryAsPreserveTerms(t *testing.T) {
	f := &fakeCleaner{out: "MCP"}
	dict := []string{"WebRTC", "DeepFilterNet"}
	if _, err := Extract(context.Background(), f, "text", dict); err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if len(f.gotTerms) != 2 || f.gotTerms[0] != "WebRTC" {
		t.Errorf("preserveTerms = %v, want %v", f.gotTerms, dict)
	}
}

func TestExtract_EmptyTextSkipsProviderCall(t *testing.T) {
	f := &fakeCleaner{out: "should not be called"}
	res, err := Extract(context.Background(), f, "   \n\t ", nil)
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if res.Keywords != nil {
		t.Errorf("Extract() keywords = %v, want nil", res.Keywords)
	}
	if res.Raw != "" {
		t.Errorf("Extract() raw = %q, want empty", res.Raw)
	}
	if f.calls != 0 {
		t.Errorf("provider called %d times for empty text, want 0", f.calls)
	}
}

func TestExtract_PropagatesProviderError(t *testing.T) {
	f := &fakeCleaner{err: errors.New("network down")}
	res, err := Extract(context.Background(), f, "text", nil)
	if err == nil {
		t.Fatal("Extract() error = nil, want provider error")
	}
	if res.Keywords != nil {
		t.Errorf("Extract() keywords = %v, want nil on error", res.Keywords)
	}
}

func TestExtract_TruncationDoesNotSplitRune(t *testing.T) {
	f := &fakeCleaner{out: "MCP"}
	// Multibyte runes straddling the byte cap must not be sliced.
	huge := strings.Repeat("世", MaxWindowTextBytes)
	if _, err := Extract(context.Background(), f, huge, nil); err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if !utf8.ValidString(f.gotRaw) {
		t.Error("truncated window text is not valid UTF-8")
	}
}

func TestExtractPrompt_ContainsBothPlaceholders(t *testing.T) {
	// Without both placeholders, llm.RenderPrompt appends its
	// cleanup-flavoured trailer and the extraction prompt stops
	// making sense.
	if !strings.Contains(ExtractPrompt, "{{transcription}}") {
		t.Error("ExtractPrompt missing {{transcription}}")
	}
	if !strings.Contains(ExtractPrompt, "{{dictionary}}") {
		t.Error("ExtractPrompt missing {{dictionary}}")
	}
}

func TestNewExtractor_UnknownProviderErrors(t *testing.T) {
	_, err := NewExtractor(config.Config{LLMProvider: "nope"})
	if err == nil {
		t.Fatal("NewExtractor() error = nil, want unknown-provider error")
	}
}

// TestExtract_ReportsRawResponseAndDrops covers the diagnostic half of
// the result: the model's response is returned verbatim and every
// sanitizer reject is accounted for.
func TestExtract_ReportsRawResponseAndDrops(t *testing.T) {
	const raw = "SpeakerGate, speakergate, 12345, DeepFilterNet"
	f := &fakeCleaner{out: raw}
	res, err := Extract(context.Background(), f, "some window text", nil)
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if res.Raw != raw {
		t.Errorf("Raw = %q, want %q", res.Raw, raw)
	}
	if len(res.Keywords) != 2 {
		t.Fatalf("Keywords = %v, want 2 terms", res.Keywords)
	}
	if len(res.Dropped) != 2 {
		t.Fatalf("Dropped = %+v, want the duplicate and the numeric token", res.Dropped)
	}
	if res.Dropped[0].Reason != DropDuplicate || res.Dropped[1].Reason != DropNumeric {
		t.Errorf("Dropped reasons = %q/%q, want %q/%q", res.Dropped[0].Reason, res.Dropped[1].Reason, DropDuplicate, DropNumeric)
	}
}
