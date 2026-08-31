//go:build whispercpp

package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/pipeline"
	"github.com/voice-keyboard/core/internal/transcribe"
)

func TestSetScreenKeywords_StoresOnEngine(t *testing.T) {
	resetEngineForTest(t)
	rc := setScreenKeywordsJSON(`{"keywords":["SpeakerGate","DeepFilterNet"]}`)
	if rc != 0 {
		t.Fatalf("setScreenKeywordsJSON rc = %d, want 0", rc)
	}
	e := getEngine()
	e.mu.Lock()
	got := e.screenKeywords
	e.mu.Unlock()
	if len(got) != 2 || got[0] != "SpeakerGate" {
		t.Errorf("screenKeywords = %v, want [SpeakerGate DeepFilterNet]", got)
	}
}

func TestSetScreenKeywords_RejectsBadJSON(t *testing.T) {
	resetEngineForTest(t)
	if rc := setScreenKeywordsJSON(`not json`); rc != 2 {
		t.Errorf("rc = %d, want 2 for malformed JSON", rc)
	}
}

func TestSetScreenKeywords_EmptyListClearsPrevious(t *testing.T) {
	resetEngineForTest(t)
	setScreenKeywordsJSON(`{"keywords":["Stale"]}`)
	if rc := setScreenKeywordsJSON(`{"keywords":[]}`); rc != 0 {
		t.Fatalf("rc = %d, want 0", rc)
	}
	e := getEngine()
	e.mu.Lock()
	got := e.screenKeywords
	e.mu.Unlock()
	if len(got) != 0 {
		t.Errorf("screenKeywords = %v, want empty after clear", got)
	}
}

func TestScreenExtractorFor_CachesForSameConfig(t *testing.T) {
	resetEngineForTest(t)
	e := getEngine()
	cfg := config.Config{LLMProvider: "ollama", LLMModel: "qwen2.5:7b"}

	first, err := e.screenExtractorFor(cfg)
	if err != nil {
		t.Fatalf("screenExtractorFor: %v", err)
	}
	second, err := e.screenExtractorFor(cfg)
	if err != nil {
		t.Fatalf("screenExtractorFor (second call): %v", err)
	}
	if first != second {
		t.Errorf("expected the same cached Cleaner for an unchanged config, got two different instances")
	}
}

func TestScreenExtractorFor_RebuildsWhenConfigChanges(t *testing.T) {
	resetEngineForTest(t)
	e := getEngine()

	first, err := e.screenExtractorFor(config.Config{LLMProvider: "ollama", LLMModel: "qwen2.5:7b"})
	if err != nil {
		t.Fatalf("screenExtractorFor: %v", err)
	}
	// Model differs — a settings change must still rebuild, not reuse
	// the cached extractor for the old model.
	second, err := e.screenExtractorFor(config.Config{LLMProvider: "ollama", LLMModel: "qwen2.5:14b"})
	if err != nil {
		t.Fatalf("screenExtractorFor (changed model): %v", err)
	}
	if first == second {
		t.Errorf("expected a rebuilt Cleaner after the model changed, got the same cached instance")
	}
}

func TestExtractKeywords_UnknownProviderReturnsErrorJSON(t *testing.T) {
	resetEngineForTest(t)
	e := getEngine()
	e.mu.Lock()
	e.cfg.LLMProvider = "nope"
	e.mu.Unlock()

	out := extractKeywordsJSON(`{"text":"hello"}`)
	var resp struct {
		Error    string   `json:"error"`
		Keywords []string `json:"keywords"`
	}
	if err := json.Unmarshal([]byte(out), &resp); err != nil {
		t.Fatalf("response is not JSON: %v (%s)", err, out)
	}
	if resp.Error == "" {
		t.Errorf("expected an error field, got %s", out)
	}
}

func TestExtractKeywords_RejectsBadJSON(t *testing.T) {
	resetEngineForTest(t)
	out := extractKeywordsJSON(`not json`)
	if !json.Valid([]byte(out)) {
		t.Fatalf("response is not valid JSON: %s", out)
	}
	var resp struct {
		Error string `json:"error"`
	}
	_ = json.Unmarshal([]byte(out), &resp)
	if resp.Error == "" {
		t.Errorf("expected an error field, got %s", out)
	}
}

// resetEngineForTest gives each test a clean engine. howl_init is
// idempotent on the C side; this mirrors it for Go-level tests.
//
// gEngine is a package-level singleton shared by every test in this
// binary (howl_init no-ops once it exists), so without resetting cfg
// here a mutation like TestExtractKeywords_UnknownProviderReturnsErrorJSON's
// e.cfg.LLMProvider = "nope" would leak into every test that runs
// afterward, in this file and others. Zeroing e.cfg restores the same
// zero-value config.Config{} that a fresh engine starts with (no test
// in this package calls howl_configure, so there are no defaults to
// preserve).
func resetEngineForTest(t *testing.T) {
	t.Helper()
	if rc := howl_init(); rc != 0 {
		t.Fatalf("howl_init rc = %d", rc)
	}
	e := getEngine()
	e.mu.Lock()
	e.screenKeywords = nil
	e.cfg = config.Config{}
	e.mu.Unlock()
	// gEngine is reused across every test in this binary (see the
	// comment above), so the screen-extractor cache added alongside
	// screenExtractorFor needs clearing here too — otherwise a test
	// that successfully builds one could leak it into an unrelated
	// later test.
	e.extractorMu.Lock()
	e.screenExtractor = nil
	e.screenExtractorKey = extractorCacheKey{}
	e.extractorMu.Unlock()
}

// fakePromptSetter is a Transcriber that also implements
// transcribe.PromptSetter, so the preview export can be exercised
// without loading a whisper model. It records whether the MUTATING
// call was made — the preview must never make it.
type fakePromptSetter struct {
	setCalls     int
	previewCalls int
	lastDict     []string
	lastScreen   []string
}

func (f *fakePromptSetter) Transcribe(context.Context, []float32) (string, error) { return "", nil }
func (f *fakePromptSetter) Close() error                                          { return nil }

func (f *fakePromptSetter) SetContextPrompt(dictTerms, screenTerms []string) []string {
	f.setCalls++
	return screenTerms
}

func (f *fakePromptSetter) PreviewContextPrompt(dictTerms, screenTerms []string) transcribe.ContextPromptPlan {
	f.previewCalls++
	f.lastDict = dictTerms
	f.lastScreen = screenTerms
	return transcribe.ContextPromptPlan{
		Dictionary:            dictTerms,
		ScreenKeywords:        screenTerms,
		DictBounded:           dictTerms,
		DictApplied:           dictTerms,
		ScreenApplied:         screenTerms,
		Prompt:                "MCP, SpeakerGate",
		TokenCount:            7,
		MaxScreenPromptTokens: transcribe.MaxScreenPromptTokens,
		MaxPromptTokens:       transcribe.MaxPromptTokens,
	}
}

// TestScreenContextPreview_ReturnsPlanWithoutMutating is the export's
// contract: it composes from the engine's CURRENT dictionary and screen
// keywords, returns the whole plan as JSON, and does not re-bias the
// transcriber on the way through.
func TestScreenContextPreview_ReturnsPlanWithoutMutating(t *testing.T) {
	resetEngineForTest(t)
	fake := &fakePromptSetter{}
	e := getEngine()
	e.mu.Lock()
	e.cfg.CustomDict = []string{"MCP"}
	e.screenKeywords = []string{"SpeakerGate"}
	e.pipeline = pipeline.New(fake, nil, nil)
	e.mu.Unlock()
	t.Cleanup(func() {
		e.mu.Lock()
		e.pipeline = nil
		e.mu.Unlock()
	})

	out := screenContextPreviewJSON()

	if fake.setCalls != 0 {
		t.Errorf("preview called SetContextPrompt %d time(s); it must not mutate engine state", fake.setCalls)
	}
	if fake.previewCalls != 1 {
		t.Fatalf("PreviewContextPrompt called %d time(s), want 1", fake.previewCalls)
	}
	if len(fake.lastDict) != 1 || fake.lastDict[0] != "MCP" {
		t.Errorf("composed from dictionary %v, want [MCP]", fake.lastDict)
	}
	if len(fake.lastScreen) != 1 || fake.lastScreen[0] != "SpeakerGate" {
		t.Errorf("composed from screen keywords %v, want [SpeakerGate]", fake.lastScreen)
	}

	var got transcribe.ContextPromptPlan
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("response is not JSON: %v (%s)", err, out)
	}
	if got.Prompt != "MCP, SpeakerGate" || got.TokenCount != 7 {
		t.Errorf("prompt/token_count = %q/%d, want %q/7", got.Prompt, got.TokenCount, "MCP, SpeakerGate")
	}
	if got.MaxPromptTokens != transcribe.MaxPromptTokens || got.MaxScreenPromptTokens != transcribe.MaxScreenPromptTokens {
		t.Errorf("caps = (%d, %d), want (%d, %d)", got.MaxScreenPromptTokens, got.MaxPromptTokens, transcribe.MaxScreenPromptTokens, transcribe.MaxPromptTokens)
	}
	// Nil slices must encode as [], not null — the Swift side decodes
	// arrays unconditionally.
	if !strings.Contains(out, `"dropped":[]`) {
		t.Errorf("expected an empty dropped array, got %s", out)
	}
}

func TestScreenContextPreview_NoPipelineReturnsErrorJSON(t *testing.T) {
	resetEngineForTest(t)
	e := getEngine()
	e.mu.Lock()
	e.pipeline = nil
	e.mu.Unlock()

	out := screenContextPreviewJSON()
	var resp struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal([]byte(out), &resp); err != nil {
		t.Fatalf("response is not JSON: %v (%s)", err, out)
	}
	if resp.Error == "" {
		t.Errorf("expected an error field, got %s", out)
	}
}
