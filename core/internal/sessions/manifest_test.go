package sessions

import (
	"os"
	"path/filepath"
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
			{Name: "tse", Kind: "chunk", WavRel: "chunk-stages/tse.wav", RateHz: 16000, TSESimilarity: 0.62},
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
	if got.Stages[1].TSESimilarity != 0.62 {
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
