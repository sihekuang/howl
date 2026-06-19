//go:build whispercpp

package transcribe

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode"
)

// TestWhisperCpp_CodeSwitch_EN_ZH proves the production config retains BOTH
// scripts: whisper anchored on English (primary) with the custom dictionary as
// the initial prompt still emits the Chinese term — exactly how build.go wires
// the live pipeline. Requires the multilingual large-v3 model; skips when
// absent (local/opt-in, not run in CI — see
// docs/superpowers/plans/2026-06-19-multilingual-codeswitch.md).
func TestWhisperCpp_CodeSwitch_EN_ZH(t *testing.T) {
	modelPath := os.ExpandEnv("$HOME/Library/Application Support/Howl/models/ggml-large-v3.bin")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("multilingual model not available at %s; download ggml-large-v3.bin to run this test", modelPath)
	}

	wavPath := filepath.Join("..", "..", "test", "integration", "testdata", "codeswitch-en-zh.wav")
	pcm, err := readWavMono16k(wavPath)
	if err != nil {
		t.Skipf("fixture unavailable (regenerate via core/test/integration/gen-codeswitch-fixture.sh): %v", err)
	}

	// Production parity: anchor on the English primary; the bilingual
	// dictionary primes the Chinese term via the initial prompt.
	w, err := NewWhisperCpp(WhisperOptions{
		ModelPath:     modelPath,
		Language:      "en",
		InitialPrompt: DictionaryPrompt([]string{"会议", "schedule"}),
	})
	if err != nil {
		t.Fatalf("NewWhisperCpp: %v", err)
	}
	defer w.Close()

	got, err := w.Transcribe(context.Background(), pcm)
	if err != nil {
		t.Fatalf("Transcribe: %v", err)
	}
	t.Logf("code-switch transcription: %q", got)

	// Han characters present → the English-anchored decode kept the second
	// script (robust to simplified/traditional and to whisper's word choice).
	hasHan := false
	for _, r := range got {
		if unicode.Is(unicode.Han, r) {
			hasHan = true
			break
		}
	}
	if !hasHan {
		t.Errorf("expected Han characters (code-switch retained), got %q", got)
	}

	// English structure retained too (not flipped wholesale to Chinese).
	lower := strings.ToLower(got)
	if !strings.Contains(lower, "schedule") &&
		!strings.Contains(lower, "tomorrow") &&
		!strings.Contains(lower, "afternoon") {
		t.Errorf("expected an English keyword (schedule/tomorrow/afternoon), got %q", got)
	}
}
