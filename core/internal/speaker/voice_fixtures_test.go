//go:build speakerbeam

package speaker

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/voice-keyboard/core/internal/audio"
)

// voiceClip is a 16 kHz mono PCM clip with a human-readable label.
// Label flows into test-failure messages so a regression points
// directly at which speaker pair triggered it.
type voiceClip struct {
	Label   string
	Samples []float32
}

// voiceFixture provides two distinct-speaker voiceClips for the TSE
// real-voice integration test. Implementations may skip cleanly via
// t.Skip when their inputs (e.g. an API key) are unavailable.
type voiceFixture interface {
	Name() string
	Voices(t *testing.T) (a, b voiceClip)
}

// libriSpeechFixture serves two committed LibriSpeech dev-clean
// clips. Always available — the WAVs are in the repo.
type libriSpeechFixture struct{}

func newLibriSpeechFixture() *libriSpeechFixture { return &libriSpeechFixture{} }

func (f *libriSpeechFixture) Name() string { return "libri_speech" }

// libriVoicesDir is the path from core/internal/speaker (the test's
// working dir at `go test` time) to the bundled fixtures.
const libriVoicesDir = "../../test/integration/testdata/voices"

func (f *libriSpeechFixture) Voices(t *testing.T) (a, b voiceClip) {
	t.Helper()
	a = readLibriClip(t, "libri_1272.wav", "libri-1272-M")
	b = readLibriClip(t, "libri_1462.wav", "libri-1462-F")
	return
}

func readLibriClip(t *testing.T, file, label string) voiceClip {
	t.Helper()
	path := filepath.Join(libriVoicesDir, file)
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("LibriSpeech fixture missing at %s — run scripts/fetch-tse-test-voices.sh: %v", path, err)
	}
	samples, sr, err := audio.ReadWAVMono(path)
	if err != nil {
		t.Fatalf("ReadWAVMono(%s): %v", path, err)
	}
	if sr != 16000 {
		t.Fatalf("expected 16 kHz, got %d Hz from %s", sr, path)
	}
	if len(samples) < 16000 {
		t.Fatalf("fixture %s too short: %d samples (< 1 s)", path, len(samples))
	}
	return voiceClip{Label: label, Samples: samples}
}

// TestVoiceFixtures_LibriSpeech is a smoke test that just verifies
// the bundled fixtures load and look like valid 16 kHz mono speech.
// The real TSE test that uses them lives in tse_real_voice_test.go.
func TestVoiceFixtures_LibriSpeech(t *testing.T) {
	fix := newLibriSpeechFixture()
	a, b := fix.Voices(t)
	t.Logf("%s: %d samples (%.2f s)", a.Label, len(a.Samples), float64(len(a.Samples))/16000.0)
	t.Logf("%s: %d samples (%.2f s)", b.Label, len(b.Samples), float64(len(b.Samples))/16000.0)
	if a.Label == b.Label {
		t.Errorf("fixtures should be distinct speakers; got identical label %q", a.Label)
	}
}
