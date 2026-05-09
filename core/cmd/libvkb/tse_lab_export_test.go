//go:build whispercpp && speakerbeam

package main

import (
	"math"
	"os"
	"path/filepath"
	"testing"

	"github.com/voice-keyboard/core/internal/audio"
)

// TestVkbTSEExtractFile_Smoke runs the Go-level body of
// vkb_tse_extract_file (runTSEExtractFile) on a 2-speaker LibriSpeech
// mix and verifies the output WAV exists, has the right format, and
// carries non-trivial energy.
//
// We exercise runTSEExtractFile rather than the C ABI shim because
// Go forbids `import "C"` in _test.go files (see streaming_test.go
// for the long-form note). The shim itself is a thin string-marshal +
// error-code translation; the work lives in runTSEExtractFile.
//
// This is a smoke test for the wiring — the real correctness check
// (extracted audio is closer to the enrolled speaker than to the
// interferer) lives in internal/speaker tests. Skips when the
// production model / enrollment artefacts aren't on the machine.
func TestVkbTSEExtractFile_Smoke(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	modelsDir := filepath.Join(home, "Library", "Application Support", "VoiceKeyboard", "models")
	if _, err := os.Stat(filepath.Join(modelsDir, "tse_model.onnx")); err != nil {
		t.Skipf("TSE model not at %s — skipping", modelsDir)
	}
	voiceDir := filepath.Join(home, "Library", "Application Support", "VoiceKeyboard", "voice")
	if _, err := os.Stat(filepath.Join(voiceDir, "enrollment.emb")); err != nil {
		t.Skipf("no enrollment at %s — skipping", voiceDir)
	}

	libriDir := filepath.Join("..", "..", "test", "integration", "testdata", "voices")
	a, sr, err := audio.ReadWAVMono(filepath.Join(libriDir, "libri_1272.wav"))
	if err != nil {
		t.Skipf("libri_1272.wav not available: %v", err)
	}
	if sr != 16000 {
		t.Fatalf("libri sr: want 16000 got %d", sr)
	}
	b, _, err := audio.ReadWAVMono(filepath.Join(libriDir, "libri_1462.wav"))
	if err != nil {
		t.Fatalf("libri_1462.wav: %v", err)
	}
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	mixed := make([]float32, n)
	for i := range mixed {
		mixed[i] = (a[i] + b[i]) * 0.5
	}

	mixPath := filepath.Join(t.TempDir(), "mixed.wav")
	outPath := filepath.Join(t.TempDir(), "extracted.wav")
	if err := audio.WriteWAVMono(mixPath, mixed, 16000); err != nil {
		t.Fatalf("write mix: %v", err)
	}

	onnxLib := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if onnxLib == "" {
		onnxLib = "/opt/homebrew/lib/libonnxruntime.dylib"
	}

	if err := runTSEExtractFile(mixPath, outPath, modelsDir, voiceDir, onnxLib); err != nil {
		t.Fatalf("runTSEExtractFile: %v", err)
	}

	out, sr2, err := audio.ReadWAVMono(outPath)
	if err != nil {
		t.Fatalf("read output: %v", err)
	}
	if sr2 != 16000 {
		t.Fatalf("output sr: want 16000 got %d", sr2)
	}
	if len(out) != n {
		t.Errorf("output length: want %d got %d", n, len(out))
	}
	var sum float64
	for _, s := range out {
		sum += float64(s) * float64(s)
	}
	rmsOut := math.Sqrt(sum / float64(len(out)))
	if rmsOut < 1e-4 {
		t.Errorf("output looks silent: RMS=%.6f", rmsOut)
	}
	t.Logf("extracted %d samples, RMS=%.4f", len(out), rmsOut)
}
