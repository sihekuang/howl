package pipeline

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/sessions"
)

// fakeChunkStage satisfies audio.Stage for the chunk lane in tests.
// Optionally exposes LastSimilarity to exercise the TSE similarity
// branch in WriteSessionManifest.
type fakeChunkStage struct {
	name        string
	outputRate  int
	withSim     bool
	simValue    float32
}

func (f *fakeChunkStage) Name() string                                       { return f.name }
func (f *fakeChunkStage) OutputRate() int                                    { return f.outputRate }
func (f *fakeChunkStage) Process(_ context.Context, in []float32) ([]float32, error) {
	return in, nil
}
func (f *fakeChunkStage) LastSimilarity() float32 {
	if !f.withSim {
		return 0
	}
	return f.simValue
}

func TestWriteSessionManifest_FrameAndChunkStages(t *testing.T) {
	dir := t.TempDir()
	p := New(nil, nil, nil)
	p.FrameStages = []audio.Stage{
		denoise.NewStage(denoise.NewPassthrough()),
		resample.NewDecimate3(),
	}
	tse := &fakeChunkStage{name: "tse", outputRate: 0, withSim: true, simValue: 0.71}
	p.ChunkStages = []audio.Stage{tse}

	if err := p.WriteSessionManifest(dir, "2026-05-07T00:00:00Z", "default"); err != nil {
		t.Fatalf("WriteSessionManifest: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(dir, "session.json"))
	if err != nil {
		t.Fatalf("read session.json: %v", err)
	}
	var m sessions.Manifest
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if m.Version != sessions.CurrentManifestVersion {
		t.Errorf("Version = %d, want %d", m.Version, sessions.CurrentManifestVersion)
	}
	if m.ID != "2026-05-07T00:00:00Z" {
		t.Errorf("ID = %q", m.ID)
	}
	if m.Preset != "default" {
		t.Errorf("Preset = %q", m.Preset)
	}
	if len(m.Stages) != 3 {
		t.Fatalf("len(Stages) = %d, want 3", len(m.Stages))
	}

	// Frame stages first, with rate tracking: denoise stays at 48000,
	// decimate3 drops to 16000.
	if m.Stages[0].Name != "denoise" || m.Stages[0].Kind != "frame" || m.Stages[0].RateHz != 48000 {
		t.Errorf("frame[0] = %+v", m.Stages[0])
	}
	if m.Stages[1].Name != "decimate" || m.Stages[1].Kind != "frame" || m.Stages[1].RateHz != 16000 {
		t.Errorf("frame[1] = %+v", m.Stages[1])
	}
	// TSE in the chunk lane carries forward the 16 kHz running rate.
	if m.Stages[2].Name != "tse" || m.Stages[2].Kind != "chunk" || m.Stages[2].RateHz != 16000 {
		t.Errorf("chunk[0] = %+v", m.Stages[2])
	}
	if m.Stages[2].TSESimilarity == nil || *m.Stages[2].TSESimilarity != 0.71 {
		t.Errorf("TSESimilarity = %v, want 0.71", m.Stages[2].TSESimilarity)
	}
	// WAV paths flat, transcripts default.
	if m.Stages[0].WavRel != "denoise.wav" {
		t.Errorf("WavRel = %q", m.Stages[0].WavRel)
	}
	if m.Transcripts.Raw != "raw.txt" || m.Transcripts.Dict != "dict.txt" || m.Transcripts.Cleaned != "cleaned.txt" {
		t.Errorf("Transcripts = %+v", m.Transcripts)
	}
}

func TestWriteSessionManifest_NoChunkStages_OmitsThem(t *testing.T) {
	dir := t.TempDir()
	p := New(nil, nil, nil)
	p.FrameStages = []audio.Stage{denoise.NewStage(denoise.NewPassthrough())}

	if err := p.WriteSessionManifest(dir, "id", "minimal"); err != nil {
		t.Fatalf("WriteSessionManifest: %v", err)
	}

	data, _ := os.ReadFile(filepath.Join(dir, "session.json"))
	var m sessions.Manifest
	_ = json.Unmarshal(data, &m)
	if len(m.Stages) != 1 {
		t.Errorf("len(Stages) = %d, want 1", len(m.Stages))
	}
}

func TestWriteSessionManifest_NonTSEChunkSkipsSimilarity(t *testing.T) {
	// A future chunk stage with a different name should not get
	// TSESimilarity populated even if it happens to expose
	// LastSimilarity (the field is tse-specific).
	dir := t.TempDir()
	p := New(nil, nil, nil)
	p.ChunkStages = []audio.Stage{
		&fakeChunkStage{name: "futurestage", outputRate: 0, withSim: true, simValue: 0.42},
	}

	if err := p.WriteSessionManifest(dir, "id", "default"); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(filepath.Join(dir, "session.json"))
	var m sessions.Manifest
	_ = json.Unmarshal(data, &m)
	if m.Stages[0].TSESimilarity != nil {
		t.Errorf("expected nil TSESimilarity for non-tse stage, got %v", *m.Stages[0].TSESimilarity)
	}
}
