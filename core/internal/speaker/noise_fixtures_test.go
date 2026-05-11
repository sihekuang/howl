//go:build cleanupeval

package speaker

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/voice-keyboard/core/internal/audio"
)

func TestMusanMusicFixture_Loads(t *testing.T) {
	fix := newMusanMusicFixture()
	if fix.Name() == "" {
		t.Fatalf("Name() empty")
	}
	clip := fix.Noise(t)
	if clip.Class != "music" {
		t.Errorf("Class = %q, want %q", clip.Class, "music")
	}
	if len(clip.Samples) < 16000 {
		t.Errorf("Noise clip too short: %d samples (< 1 s)", len(clip.Samples))
	}
}

// noiseClip is a 16 kHz mono PCM clip of non-speech noise with a
// human-readable label and a class tag.
type noiseClip struct {
	Label   string
	Samples []float32
	Class   string // "music" | "fan" | "babble" | "keyboard" | "traffic"
}

// noiseFixture is symmetric to voiceFixture: yields one noiseClip
// for the harness's mixture-with-noise rows. Implementations may
// skip cleanly when their inputs are unavailable.
type noiseFixture interface {
	Name() string
	Noise(t *testing.T) noiseClip
}

// musanMusicFixture serves a single committed clip extracted from
// MUSAN's music subset (Apache-2.0). The clip is sourced via
// scripts/fetch-musan-music-fixture.sh and lives next to the voice
// fixtures.
type musanMusicFixture struct{}

func newMusanMusicFixture() *musanMusicFixture { return &musanMusicFixture{} }

func (f *musanMusicFixture) Name() string { return "musan_music" }

const musanMusicPath = "../../test/integration/testdata/noise/musan_music_excerpt.wav"

func (f *musanMusicFixture) Noise(t *testing.T) noiseClip {
	t.Helper()
	if _, err := os.Stat(musanMusicPath); err != nil {
		t.Fatalf("MUSAN music fixture missing at %s — run scripts/fetch-musan-music-fixture.sh: %v", musanMusicPath, err)
	}
	samples, sr, err := audio.ReadWAVMono(musanMusicPath)
	if err != nil {
		t.Fatalf("ReadWAVMono(%s): %v", musanMusicPath, err)
	}
	if sr != 16000 {
		t.Fatalf("expected 16 kHz, got %d Hz from %s", sr, musanMusicPath)
	}
	return noiseClip{
		Label:   filepath.Base(musanMusicPath),
		Samples: samples,
		Class:   "music",
	}
}
