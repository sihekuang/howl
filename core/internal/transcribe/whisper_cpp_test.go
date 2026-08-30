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
//
// Sizes are chosen (verified empirically against ggml-tiny.en, see
// task-2-report.md) so stage 2 actually has to trim:
//   - 20 dict terms tokenize to ~159 tokens, comfortably under both the
//     896-byte prompt cap and MaxPromptTokens alone, so dict survives
//     the byte-level pre-filter in ContextPrompt intact.
//   - 60 screen terms survive ContextPrompt's byte pre-filter as ~18
//     terms, which stage 1 (the MaxScreenPromptTokens loop) then trims
//     to ~8-9 terms (~90-96 tokens).
//   - dict (~159 tokens) + that screen remainder (~90-96 tokens) totals
//     ~250-255 tokens, over MaxPromptTokens (224), so stage 2's loop
//     body must actually execute and trim further.
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

	dict := make([]string, 20)
	for i := range dict {
		dict[i] = fmt.Sprintf("QvxDictTerm%02d", i)
	}
	// 60 dense CamelCase identifiers: byte-legal, token-illegal.
	screen := make([]string, 60)
	for i := range screen {
		screen[i] = fmt.Sprintf("XqzGlyphWarpNode%02d", i)
	}

	w.SetContextPrompt(dict, screen)
	got := w.initialPrompt

	if n := w.tokenCount(got); n > MaxPromptTokens {
		t.Errorf("prompt is %d tokens, want <= %d", n, MaxPromptTokens)
	}

	survivors := strings.Split(got, ", ")
	present := make(map[string]bool, len(survivors))
	for _, term := range survivors {
		present[term] = true
	}
	dictPresent, screenPresent := 0, 0
	for _, term := range dict {
		if present[term] {
			dictPresent++
		}
	}
	for _, term := range screen {
		if present[term] {
			screenPresent++
		}
	}
	if dictPresent == 0 {
		t.Fatalf("no dictionary terms survived at all; test fixture sizes need rebalancing")
	}

	// The ordering invariant this whole feature exists to guarantee:
	// stage 2 drops from the tail of dict++screen, so screen keywords
	// must be fully evicted before a single dictionary term is touched.
	// Concretely: if any dictionary term was evicted, no screen term may
	// have survived. This fails if the append order in SetContextPrompt
	// is ever inverted (screen appended before dict) -- verified by
	// temporarily reversing that order locally and confirming this
	// assertion goes red (see task-2-report.md).
	if dictPresent < len(dict) && screenPresent > 0 {
		t.Errorf("ordering inversion: only %d/%d dict terms survived while %d/%d screen terms also survived; screen keywords must be evicted before any dictionary term is dropped", dictPresent, len(dict), screenPresent, len(screen))
	}
}

// TestWhisperCpp_SetContextPrompt_ScreenSubCapInTokens verifies stage 1
// (the MaxScreenPromptTokens sub-cap) independently of stage 2.
//
// dict is deliberately nil here rather than "given a dict and asserting
// what's observable with one": whisper's BPE tokenizer is not additive
// across concatenation (joining dict and screen segments can merge or
// split tokens at the boundary, per the deferred BPE-isolation finding
// on stage 1 itself), so with a dict present there is no way to recover
// the screen segment's token count from tokenCount(w.initialPrompt) --
// the combined figure is not "dict tokens + screen tokens". With dict
// nil, w.initialPrompt IS the screen segment (stage 2 is a no-op
// because dict-less input can't exceed MaxPromptTokens once it's
// already under MaxScreenPromptTokens < MaxPromptTokens), so this is
// the only way to observe the stage-1 bound directly through the
// public field.
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

// TestWhisperCpp_SetContextPrompt_ReturnsSurvivingScreenTerms is the
// regression test for the manifest-lies defect found in review:
// howl_start_capture records SetContextPrompt's RETURN value (not the
// input screenTerms) in the session manifest, so the return value must
// be the terms that actually survived trimming, not what was offered.
//
// A broken "fix" that returns the input unchanged (or only applies
// ContextPrompt's byte-level pre-filter without the token-based stages
// below it) would make len(got) == len(screen) here and fail this test
// — that's the case this test exists to catch.
//
// dict is nil for the same reason as the sibling ScreenSubCap test
// above: with dict absent, stage 2 (MaxPromptTokens) is a no-op once
// stage 1 (MaxScreenPromptTokens) has already trimmed screen below it,
// isolating stage 1's effect on the return value cleanly.
func TestWhisperCpp_SetContextPrompt_ReturnsSurvivingScreenTerms(t *testing.T) {
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
		screen[i] = fmt.Sprintf("PmnxSurviveScreen%02d", i)
	}

	got := w.SetContextPrompt(nil, screen)

	if len(got) == 0 {
		t.Fatalf("expected some screen terms to survive trimming, got none")
	}
	if len(got) >= len(screen) {
		t.Fatalf("got %d survivors, want fewer than the %d offered — 40 dense identifiers must exceed MaxScreenPromptTokens (%d) and get trimmed", len(got), len(screen), MaxScreenPromptTokens)
	}
	// Both trim stages drop from the tail, so survivors must be an
	// exact prefix of what was offered, in the same order.
	for i, term := range got {
		if term != screen[i] {
			t.Errorf("survivor[%d] = %q, want %q — trimming must drop from the tail, preserving order", i, term, screen[i])
		}
	}
	// The returned slice must be exactly what ended up in the prompt
	// whisper actually sees — this is the whole point of returning it.
	if joined := strings.Join(got, ", "); joined != w.initialPrompt {
		t.Errorf("returned survivors %q don't match initialPrompt %q", joined, w.initialPrompt)
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
