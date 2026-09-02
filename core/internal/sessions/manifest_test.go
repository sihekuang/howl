package sessions

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestManifest_WriteReadRoundTrip(t *testing.T) {
	dir := t.TempDir()
	m := Manifest{
		Version:     1,
		ID:          "2026-05-02T14:32:11Z",
		Preset:      "default",
		DurationSec: 3.2,
		Stages: []StageEntry{
			{Name: "denoise", Kind: "frame", WavRel: "frame-stages/denoise.wav", RateHz: 48000},
			{Name: "tse", Kind: "chunk", WavRel: "chunk-stages/tse.wav", RateHz: 16000, TSESimilarity: floatPtr(0.62)},
		},
		Transcripts: TranscriptEntries{
			Raw:     "transcripts/raw.txt",
			Dict:    "transcripts/dict.txt",
			Cleaned: "transcripts/cleaned.txt",
		},
	}
	if err := m.Write(dir); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "session.json")); err != nil {
		t.Fatalf("session.json missing: %v", err)
	}
	got, err := Read(dir)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.ID != m.ID || got.Preset != m.Preset || len(got.Stages) != 2 {
		t.Errorf("round-trip mismatch: got %+v", got)
	}
	if got.Stages[1].TSESimilarity == nil || *got.Stages[1].TSESimilarity != 0.62 {
		t.Errorf("TSESimilarity = %v, want 0.62", got.Stages[1].TSESimilarity)
	}
}

func TestManifest_RejectsUnknownVersion(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "session.json"), []byte(`{"version":99,"id":"x"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(dir); err == nil {
		t.Fatal("expected error for version 99")
	}
}

func TestManifest_RejectsMalformedJSON(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "session.json"), []byte(`{not json`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(dir); err == nil {
		t.Fatal("expected error for malformed JSON")
	}
}

func TestManifest_ReadMissing_ReturnsSentinel(t *testing.T) {
	dir := t.TempDir()
	_, err := Read(dir)
	if err == nil {
		t.Fatal("expected error for missing session.json")
	}
	if !errors.Is(err, ErrManifestNotFound) {
		t.Errorf("err = %v, want errors.Is(_, ErrManifestNotFound)", err)
	}
}

func TestManifest_WriteProducesCanonicalJSON(t *testing.T) {
	// Pin one specific manifest's serialized form so any change to
	// JSON tags (which are this package's effective ABI to Swift +
	// howl-cli readers) breaks this test loudly. Update the want
	// string ONLY when intentionally evolving the schema.
	dir := t.TempDir()
	sim := float32(0.75)
	m := Manifest{
		Version: 1, ID: "x", Preset: "default", DurationSec: 1.5,
		Stages: []StageEntry{
			{Name: "tse", Kind: "chunk", WavRel: "tse.wav", RateHz: 16000, TSESimilarity: &sim},
		},
		Transcripts: TranscriptEntries{Raw: "raw.txt", Dict: "dict.txt", Cleaned: "cleaned.txt"},
	}
	if err := m.Write(dir); err != nil {
		t.Fatalf("Write: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dir, "session.json"))
	if err != nil {
		t.Fatal(err)
	}
	want := `{
  "version": 1,
  "id": "x",
  "preset": "default",
  "duration_sec": 1.5,
  "stages": [
    {
      "name": "tse",
      "kind": "chunk",
      "wav": "tse.wav",
      "rate_hz": 16000,
      "tse_similarity": 0.75
    }
  ],
  "transcripts": {
    "raw": "raw.txt",
    "dict": "dict.txt",
    "cleaned": "cleaned.txt"
  }
}`
	if string(got) != want {
		t.Errorf("manifest bytes drift:\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// TestManifest_ScreenKeywordsOmittedWhenEmpty guards the back-compat
// promise on ScreenKeywords' `omitempty` tag: existing manifests (and
// sessions that never had screen context) must serialize with no
// `screen_keywords` key at all, not `"screen_keywords": null` or `[]`.
// Before this test, that guarantee rested only on the struct tag
// looking correct — nothing exercised it directly.
func TestManifest_ScreenKeywordsOmittedWhenEmpty(t *testing.T) {
	base := TranscriptEntries{Raw: "raw.txt", Dict: "dict.txt", Cleaned: "cleaned.txt"}

	t.Run("nil", func(t *testing.T) {
		dir := t.TempDir()
		m := Manifest{Version: 1, ID: "x", Preset: "default", Transcripts: base}
		if err := m.Write(dir); err != nil {
			t.Fatalf("Write: %v", err)
		}
		got, err := os.ReadFile(filepath.Join(dir, "session.json"))
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(got), "screen_keywords") {
			t.Errorf("expected screen_keywords absent when nil, got:\n%s", got)
		}
	})

	t.Run("empty_non_nil", func(t *testing.T) {
		// This is the actual shape produced when a caller sets
		// `{"keywords":[]}` via howl_set_screen_keywords (a non-nil,
		// zero-length slice) — omitempty must treat it the same as nil.
		dir := t.TempDir()
		m := Manifest{Version: 1, ID: "x", Preset: "default", Transcripts: base, ScreenKeywords: []string{}}
		if err := m.Write(dir); err != nil {
			t.Fatalf("Write: %v", err)
		}
		got, err := os.ReadFile(filepath.Join(dir, "session.json"))
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(got), "screen_keywords") {
			t.Errorf("expected screen_keywords absent when empty, got:\n%s", got)
		}
	})
}

func floatPtr(f float32) *float32 { return &f }

// TestManifest_WhisperPromptOmittedWhenEmpty holds whisper_prompt and
// whisper_prompt_tokens to the same back-compat promise
// screen_keywords already carries: a session that had no ASR prompt
// must serialize with neither key present, so existing manifests stay
// byte-identical.
func TestManifest_WhisperPromptOmittedWhenEmpty(t *testing.T) {
	base := TranscriptEntries{Raw: "raw.txt", Dict: "dict.txt", Cleaned: "cleaned.txt"}
	dir := t.TempDir()
	m := Manifest{Version: 1, ID: "x", Preset: "default", Transcripts: base}
	if err := m.Write(dir); err != nil {
		t.Fatalf("Write: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dir, "session.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(got), "whisper_prompt") {
		t.Errorf("expected whisper_prompt absent when empty, got:\n%s", got)
	}
}
