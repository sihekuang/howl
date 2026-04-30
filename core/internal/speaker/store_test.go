package speaker

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestStore_ProfileRoundTrip(t *testing.T) {
	dir := t.TempDir()
	wavPath := filepath.Join(dir, "enrollment.wav")
	p := Profile{
		Version:    1,
		RefAudio:   wavPath,
		EnrolledAt: time.Date(2026, 4, 30, 12, 0, 0, 0, time.UTC),
		DurationS:  10.2,
	}
	if err := SaveProfile(dir, p); err != nil {
		t.Fatalf("SaveProfile: %v", err)
	}
	got, err := LoadProfile(dir)
	if err != nil {
		t.Fatalf("LoadProfile: %v", err)
	}
	if got.Version != 1 {
		t.Errorf("Version = %d, want 1", got.Version)
	}
	if got.RefAudio != wavPath {
		t.Errorf("RefAudio = %q, want %q", got.RefAudio, wavPath)
	}
	if got.DurationS != 10.2 {
		t.Errorf("DurationS = %f, want 10.2", got.DurationS)
	}
}

func TestStore_WAVRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.wav")

	samples := make([]float32, 16000) // 1 second of silence
	for i := range samples {
		samples[i] = float32(i) / float32(len(samples)) // ramp
	}
	if err := SaveWAV(path, samples, 16000); err != nil {
		t.Fatalf("SaveWAV: %v", err)
	}

	fi, _ := os.Stat(path)
	// 44 header bytes + 16000*4 data bytes
	wantSize := int64(44 + len(samples)*4)
	if fi.Size() != wantSize {
		t.Errorf("file size = %d, want %d", fi.Size(), wantSize)
	}

	got, err := LoadWAV(path)
	if err != nil {
		t.Fatalf("LoadWAV: %v", err)
	}
	if len(got) != len(samples) {
		t.Fatalf("len(got) = %d, want %d", len(got), len(samples))
	}
	for i, v := range got {
		if v != samples[i] {
			t.Errorf("sample[%d] = %f, want %f", i, v, samples[i])
		}
	}
}

func TestStore_LoadProfile_MissingFile(t *testing.T) {
	_, err := LoadProfile(t.TempDir())
	if err == nil {
		t.Fatal("expected error for missing speaker.json, got nil")
	}
}

func TestStore_LoadWAV_MissingFile(t *testing.T) {
	_, err := LoadWAV("/nonexistent/path/enrollment.wav")
	if err == nil {
		t.Fatal("expected error for missing WAV, got nil")
	}
}
