//go:build silero

package speaker

import (
	"math"
	"os"
	"testing"
)

func TestSileroVAD_VoicedOnTone(t *testing.T) {
	libPath := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if libPath == "" {
		libPath = "/opt/homebrew/lib/libonnxruntime.dylib"
	}
	if err := InitONNXRuntime(libPath); err != nil {
		t.Fatalf("InitONNXRuntime: %v", err)
	}
	modelPath := os.Getenv("SILERO_MODEL_PATH")
	if modelPath == "" {
		t.Skip("SILERO_MODEL_PATH not set")
	}
	vad, err := NewSileroVAD(modelPath)
	if err != nil {
		t.Fatalf("NewSileroVAD: %v", err)
	}
	defer vad.Close()

	// 1600 samples of 440Hz sine at 16kHz (100ms window, above threshold)
	tone := make([]float32, 1600)
	for i := range tone {
		tone[i] = 0.3 * float32(math.Sin(2*math.Pi*440*float64(i)/16000))
	}
	if !vad.IsVoiced(tone) {
		t.Error("expected IsVoiced true for tone, got false")
	}

	// 1600 samples of silence
	silence := make([]float32, 1600)
	if vad.IsVoiced(silence) {
		t.Error("expected IsVoiced false for silence, got true")
	}
}
