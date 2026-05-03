package recorder

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"

	"github.com/voice-keyboard/core/internal/sessions"
)

func TestSessionWritesPerStageWAV(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(Options{Dir: dir, AudioStages: true, Transcripts: false})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := s.AddStage("denoise", 48000); err != nil {
		t.Fatalf("AddStage denoise: %v", err)
	}
	if err := s.AddStage("tse", 16000); err != nil {
		t.Fatalf("AddStage tse: %v", err)
	}
	s.AppendStage("denoise", make([]float32, 480))
	s.AppendStage("tse", make([]float32, 160))
	if err := s.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	for name, wantBytes := range map[string]int{
		"denoise.wav": 480 * 2,
		"tse.wav":     160 * 2,
	} {
		path := filepath.Join(dir, name)
		assertWavDataLen(t, path, wantBytes)
	}
}

func TestSessionTranscripts(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(Options{Dir: dir, AudioStages: false, Transcripts: true})
	if err := s.WriteTranscript("raw.txt", "hello world"); err != nil {
		t.Fatalf("WriteTranscript: %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(dir, "raw.txt"))
	if string(got) != "hello world" {
		t.Errorf("raw.txt=%q", got)
	}
	_ = s.Close()
}

func TestSessionDisabledIsNoOp(t *testing.T) {
	s, err := Open(Options{Dir: "", AudioStages: false, Transcripts: false})
	if err != nil {
		t.Fatalf("Open returned err for empty options: %v", err)
	}
	if s != nil {
		t.Errorf("expected nil session for fully-disabled options")
	}
	// Methods on nil session must be safe.
	s.AppendStage("anything", []float32{1, 2, 3})
	_ = s.WriteTranscript("raw.txt", "x")
	_ = s.Close()
}

func TestSession_WriteManifest(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(Options{Dir: dir, AudioStages: true, Transcripts: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })

	m := sessions.Manifest{
		ID:          "2026-05-02T14:32:11Z",
		Preset:      "default",
		DurationSec: 1.5,
		Stages: []sessions.StageEntry{
			{Name: "denoise", Kind: "frame", WavRel: "denoise.wav", RateHz: 48000},
		},
		Transcripts: sessions.TranscriptEntries{Raw: "raw.txt", Dict: "dict.txt", Cleaned: "cleaned.txt"},
	}
	if err := s.WriteManifest(&m); err != nil {
		t.Fatalf("WriteManifest: %v", err)
	}
	got, err := sessions.Read(dir)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.ID != m.ID || got.Preset != "default" || len(got.Stages) != 1 {
		t.Errorf("manifest mismatch: got %+v", got)
	}
}

func TestSession_WriteManifest_NilSession_NoOp(t *testing.T) {
	// Recorder methods on nil are no-ops by contract.
	var s *Session
	if err := s.WriteManifest(&sessions.Manifest{ID: "x"}); err != nil {
		t.Errorf("WriteManifest on nil should be no-op, got: %v", err)
	}
}

func assertWavDataLen(t *testing.T, path string, wantBytes int) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %q: %v", path, err)
	}
	if len(data) < 44 {
		t.Fatalf("%q: too short (%d bytes)", path, len(data))
	}
	got := int(binary.LittleEndian.Uint32(data[40:44]))
	if got != wantBytes {
		t.Errorf("%q: data chunk size=%d, want %d", path, got, wantBytes)
	}
}
