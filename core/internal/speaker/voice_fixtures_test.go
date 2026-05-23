//go:build speakerbeam || cleanupeval

package speaker

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

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

// Transcripts returns the ground-truth transcripts matching the two
// voice clips returned by Voices, in the same order (A, B). Reads
// libri_1272.txt and libri_1462.txt sibling files. Fatals if either
// is missing — the harness depends on transcripts.
func (f *libriSpeechFixture) Transcripts(t *testing.T) (a, b string) {
	t.Helper()
	a = readLibriTranscript(t, "libri_1272.txt")
	b = readLibriTranscript(t, "libri_1462.txt")
	return
}

func readLibriTranscript(t *testing.T, file string) string {
	t.Helper()
	path := filepath.Join(libriVoicesDir, file)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("LibriSpeech transcript missing at %s — run scripts/fetch-libri-transcripts.sh: %v", path, err)
	}
	return strings.TrimSpace(string(data))
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

// elevenLabsFixture synthesises two distinct voices via the
// ElevenLabs TTS API. Skipped (not failed) when ELEVENLABS_API_KEY
// is unset or `ffmpeg` is missing — opt-in path, never blocks the
// default `go test` run.
type elevenLabsFixture struct{}

func newElevenLabsFixture() *elevenLabsFixture { return &elevenLabsFixture{} }

func (f *elevenLabsFixture) Name() string { return "elevenlabs" }

// Canonical demo voice IDs documented at
// https://elevenlabs.io/docs/voices/default-voices. Adam is a
// resonant male voice; Rachel is a clear female voice — pair gives
// good acoustic distance for ECAPA discrimination.
const (
	elevenLabsAdamID   = "pNInz6obpgDQGcFmaJgB"
	elevenLabsRachelID = "21m00Tcm4TlvDq8ikWAM"
)

const elevenLabsTestText = "Twas brillig and the slithy toves did gyre and gimble in the wabe; all mimsy were the borogoves and the mome raths outgrabe."

func (f *elevenLabsFixture) Voices(t *testing.T) (a, b voiceClip) {
	t.Helper()
	apiKey := os.Getenv("ELEVENLABS_API_KEY")
	if apiKey == "" {
		t.Skip("ELEVENLABS_API_KEY not set — opt-in fixture")
	}
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not on PATH — required to decode ElevenLabs MP3")
	}
	a = fetchElevenLabsVoice(t, apiKey, elevenLabsAdamID, "elevenlabs-adam-M")
	b = fetchElevenLabsVoice(t, apiKey, elevenLabsRachelID, "elevenlabs-rachel-F")
	return
}

// fetchElevenLabsVoice returns a 16 kHz mono float32 clip for
// (voiceID, elevenLabsTestText). Cached under $TMPDIR so repeat
// runs don't burn API credits or re-decode.
func fetchElevenLabsVoice(t *testing.T, apiKey, voiceID, label string) voiceClip {
	t.Helper()
	cacheDir := filepath.Join(os.TempDir(), "voicekeyboard-tse-fixtures")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		t.Fatalf("mkdir cache: %v", err)
	}
	keyHash := sha256.Sum256([]byte(voiceID + "|" + elevenLabsTestText))
	cacheFile := filepath.Join(cacheDir, fmt.Sprintf("%s_%s.wav", voiceID, hex.EncodeToString(keyHash[:8])))

	if _, err := os.Stat(cacheFile); err == nil {
		samples, sr, err := audio.ReadWAVMono(cacheFile)
		if err == nil && sr == 16000 {
			return voiceClip{Label: label, Samples: samples}
		}
		// Fall through: cache file is corrupt; re-fetch.
	}

	mp3Bytes, err := elevenLabsTTS(apiKey, voiceID, elevenLabsTestText)
	if err != nil {
		t.Skipf("ElevenLabs TTS failed (skipping rather than failing): %v", err)
	}

	mp3File := cacheFile + ".mp3"
	if err := os.WriteFile(mp3File, mp3Bytes, 0o644); err != nil {
		t.Fatalf("write mp3 cache: %v", err)
	}
	defer os.Remove(mp3File)

	cmd := exec.Command("ffmpeg", "-y", "-loglevel", "error",
		"-i", mp3File,
		"-ac", "1", "-ar", "16000", "-sample_fmt", "s16",
		cacheFile)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg mp3->wav: %v\n%s", err, out)
	}

	samples, sr, err := audio.ReadWAVMono(cacheFile)
	if err != nil {
		t.Fatalf("ReadWAVMono(%s): %v", cacheFile, err)
	}
	if sr != 16000 {
		t.Fatalf("expected 16 kHz, got %d Hz", sr)
	}
	return voiceClip{Label: label, Samples: samples}
}

// elevenLabsTTS calls the v1 text-to-speech endpoint and returns
// raw MP3 bytes. 30 s timeout — the API typically returns in 1–3 s.
func elevenLabsTTS(apiKey, voiceID, text string) ([]byte, error) {
	body, err := json.Marshal(map[string]any{
		"text":     text,
		"model_id": "eleven_multilingual_v2",
		"voice_settings": map[string]any{
			"stability":        0.5,
			"similarity_boost": 0.75,
		},
	})
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}
	url := "https://api.elevenlabs.io/v1/text-to-speech/" + voiceID
	req, err := http.NewRequest("POST", url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("xi-api-key", apiKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "audio/mpeg")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		errBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("status %d: %s", resp.StatusCode, string(errBody))
	}
	return io.ReadAll(resp.Body)
}
