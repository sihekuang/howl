//go:build whispercpp

package main

import (
	"encoding/json"
	"testing"

	"github.com/voice-keyboard/core/internal/config"
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
}
