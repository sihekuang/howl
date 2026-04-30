package speaker

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

// fakeSource simulates mic input — returns a pre-built sample slice, then closes.
type fakeSource struct {
	samples []float32
	sent    bool
}

func (s *fakeSource) start(_ context.Context, _ int) (<-chan []float32, error) {
	ch := make(chan []float32, 1)
	if !s.sent {
		ch <- s.samples
		s.sent = true
	}
	close(ch)
	return ch, nil
}

func TestEnroller_SavesWAVAndProfile(t *testing.T) {
	dir := t.TempDir()

	// 1 second of audio at 16kHz
	samples := make([]float32, 16000)
	for i := range samples {
		samples[i] = float32(i) / 16000
	}
	src := &fakeSource{samples: samples}

	e := &Enroller{sampleRate: 16000, source: src.start}
	if err := e.Record(context.Background(), dir, 5*time.Second); err != nil {
		t.Fatalf("Record: %v", err)
	}

	// speaker.json must exist
	p, err := LoadProfile(dir)
	if err != nil {
		t.Fatalf("LoadProfile: %v", err)
	}
	if p.Version != 1 {
		t.Errorf("Version = %d, want 1", p.Version)
	}

	// enrollment.wav must exist and be non-empty
	got, err := LoadWAV(filepath.Join(dir, "enrollment.wav"))
	if err != nil {
		t.Fatalf("LoadWAV: %v", err)
	}
	if len(got) == 0 {
		t.Error("enrollment.wav is empty")
	}
}
