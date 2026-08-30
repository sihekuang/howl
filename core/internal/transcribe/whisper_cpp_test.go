//go:build whispercpp

package transcribe

import (
	"context"
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWhisperCpp_TranscribesSamples(t *testing.T) {
	modelPath := os.ExpandEnv("$HOME/Library/Application Support/Howl/models/ggml-tiny.en.bin")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("model not available at %s; download via the curl in Task 12 step 2", modelPath)
	}

	wavPath := filepath.Join("..", "..", "test", "integration", "testdata", "hello-world.wav")
	pcm, err := readWavMono16k(wavPath)
	if err != nil {
		t.Skipf("test fixture not available: %v", err)
	}

	w, err := NewWhisperCpp(WhisperOptions{ModelPath: modelPath, Language: "en"})
	if err != nil {
		t.Fatalf("NewWhisperCpp: %v", err)
	}
	defer w.Close()

	got, err := w.Transcribe(context.Background(), pcm)
	if err != nil {
		t.Fatalf("Transcribe: %v", err)
	}
	if strings.TrimSpace(got) == "" {
		t.Errorf("expected non-empty transcription, got empty string")
	}
	t.Logf("transcription: %q", got)
}

// readWavMono16k loads a small WAV fixture into []float32. Only handles
// 16-bit PCM mono at 16kHz — sufficient for the test fixture.
// Walks the RIFF chunk list to find the "data" chunk regardless of any
// optional chunks (LIST, INFO, etc.) that precede it.
func readWavMono16k(path string) ([]float32, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(data) < 12 || string(data[0:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return nil, os.ErrInvalid
	}
	// Iterate sub-chunks starting after the WAVE id.
	for i := 12; i+8 <= len(data); {
		id := string(data[i : i+4])
		size := int(binary.LittleEndian.Uint32(data[i+4 : i+8]))
		if i+8+size > len(data) {
			return nil, os.ErrInvalid
		}
		if id == "data" {
			pcm := data[i+8 : i+8+size]
			samples := make([]float32, len(pcm)/2)
			for j := range samples {
				v := int16(binary.LittleEndian.Uint16(pcm[j*2 : j*2+2]))
				samples[j] = float32(v) / float32(math.MaxInt16)
			}
			return samples, nil
		}
		// Chunks are word-aligned: pad odd sizes.
		next := i + 8 + size
		if size%2 == 1 {
			next++
		}
		i = next
	}
	return nil, os.ErrInvalid
}

// TestWhisperCpp_SetContextPrompt_TrimsToRealTokenWindow is the
// regression test for the reason this feature needed a token-based
// bound. Dense jargon tokenizes at ~1.5-3 bytes/token, so a prompt that
// passes the 896-byte pre-filter can still exceed whisper's 224-token
// window — where whisper would silently drop the HEAD, i.e. the user's
// dictionary.
func TestWhisperCpp_SetContextPrompt_TrimsToRealTokenWindow(t *testing.T) {
	modelPath := os.ExpandEnv("$HOME/Library/Application Support/Howl/models/ggml-tiny.en.bin")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("model not available at %s", modelPath)
	}
	w, err := NewWhisperCpp(WhisperOptions{ModelPath: modelPath, Language: "en"})
	if err != nil {
		t.Fatalf("NewWhisperCpp: %v", err)
	}
	defer w.Close()

	// 60 dense CamelCase identifiers: byte-legal, token-illegal.
	screen := make([]string, 60)
	for i := range screen {
		screen[i] = fmt.Sprintf("XqzGlyphWarpNode%02d", i)
	}
	dict := []string{"MCP", "WebRTC", "DeepFilterNet"}

	w.SetContextPrompt(dict, screen)
	got := w.initialPrompt

	if n := w.tokenCount(got); n > MaxPromptTokens {
		t.Errorf("prompt is %d tokens, want <= %d", n, MaxPromptTokens)
	}
	for _, term := range dict {
		if !strings.Contains(got, term) {
			t.Errorf("dictionary term %q was evicted; screen keywords must be dropped first", term)
		}
	}
}

func TestWhisperCpp_SetContextPrompt_ScreenSubCapInTokens(t *testing.T) {
	modelPath := os.ExpandEnv("$HOME/Library/Application Support/Howl/models/ggml-tiny.en.bin")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("model not available at %s", modelPath)
	}
	w, err := NewWhisperCpp(WhisperOptions{ModelPath: modelPath, Language: "en"})
	if err != nil {
		t.Fatalf("NewWhisperCpp: %v", err)
	}
	defer w.Close()

	screen := make([]string, 40)
	for i := range screen {
		screen[i] = fmt.Sprintf("ZzyxKernBlob%02d", i)
	}
	w.SetContextPrompt(nil, screen)

	if n := w.tokenCount(w.initialPrompt); n > MaxScreenPromptTokens {
		t.Errorf("screen-only prompt is %d tokens, want <= %d", n, MaxScreenPromptTokens)
	}
}

func TestWhisperCpp_SetContextPrompt_EmptyClearsPrompt(t *testing.T) {
	modelPath := os.ExpandEnv("$HOME/Library/Application Support/Howl/models/ggml-tiny.en.bin")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("model not available at %s", modelPath)
	}
	w, err := NewWhisperCpp(WhisperOptions{ModelPath: modelPath, Language: "en"})
	if err != nil {
		t.Fatalf("NewWhisperCpp: %v", err)
	}
	defer w.Close()

	w.SetContextPrompt([]string{"MCP"}, nil)
	w.SetContextPrompt(nil, nil)
	if w.initialPrompt != "" {
		t.Errorf("initialPrompt = %q, want empty after clearing", w.initialPrompt)
	}
}
