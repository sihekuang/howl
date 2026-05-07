//go:build speakerbeam

package speaker

import (
	"context"
	"math"
	"os"
	"path/filepath"
	"testing"
)

// tseResult holds everything the assertions need from one run of
// evaluateTSE. Returned (not asserted) by evaluateTSE so the caller
// can log all four numbers regardless of which assertion fails.
type tseResult struct {
	SimTarget     float32 // cos(extracted, voices[targetIdx])
	SimInterferer float32 // cos(extracted, voices[1-targetIdx])
	RMSIn         float32 // RMS of the mixed input
	RMSOut        float32 // RMS of the extracted output
}

// evaluateTSE mixes voices[0]+voices[1] at equal level, runs TSE
// using voices[targetIdx]'s embedding as reference, and reports the
// four numbers needed to assess "did TSE pull toward the target."
//
// Pure: no assertions inside. Caller chooses what to do with the
// result. InitONNXRuntime must have been called before this.
func evaluateTSE(t *testing.T, voices [2]voiceClip, targetIdx int, tseModelPath, encoderModelPath string) tseResult {
	t.Helper()
	if targetIdx != 0 && targetIdx != 1 {
		t.Fatalf("targetIdx must be 0 or 1, got %d", targetIdx)
	}

	n := len(voices[0].Samples)
	if len(voices[1].Samples) < n {
		n = len(voices[1].Samples)
	}
	a := voices[0].Samples[:n]
	b := voices[1].Samples[:n]

	mixed := make([]float32, n)
	for i := range mixed {
		mixed[i] = (a[i] + b[i]) * 0.5
	}

	const ecapaDim = 192
	embedTarget, err := ComputeEmbedding(encoderModelPath, voices[targetIdx].Samples, ecapaDim)
	if err != nil {
		t.Fatalf("ComputeEmbedding(target=%s): %v", voices[targetIdx].Label, err)
	}

	tse, err := NewSpeakerGate(SpeakerGateOptions{
		ModelPath: tseModelPath,
		Reference: embedTarget,
	})
	if err != nil {
		t.Fatalf("NewSpeakerGate: %v", err)
	}
	defer tse.Close()

	extracted, err := tse.Extract(context.Background(), mixed)
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}

	embedExtracted, err := ComputeEmbedding(encoderModelPath, extracted, ecapaDim)
	if err != nil {
		t.Fatalf("ComputeEmbedding(extracted): %v", err)
	}
	embedInterferer, err := ComputeEmbedding(encoderModelPath, voices[1-targetIdx].Samples, ecapaDim)
	if err != nil {
		t.Fatalf("ComputeEmbedding(interferer=%s): %v", voices[1-targetIdx].Label, err)
	}

	return tseResult{
		SimTarget:     cosineSimilarity(embedExtracted, embedTarget),
		SimInterferer: cosineSimilarity(embedExtracted, embedInterferer),
		RMSIn:         rms(mixed),
		RMSOut:        rms(extracted),
	}
}

func rms(s []float32) float32 {
	if len(s) == 0 {
		return 0
	}
	var sum float64
	for _, v := range s {
		sum += float64(v) * float64(v)
	}
	return float32(math.Sqrt(sum / float64(len(s))))
}

// resolveModelPath returns the value of envVar if it points to an
// existing file; otherwise tries the conventional repo and
// Application Support locations; otherwise t.Skips.
func resolveModelPath(t *testing.T, envVar, basename string) string {
	t.Helper()
	if v := os.Getenv(envVar); v != "" {
		if _, err := os.Stat(v); err == nil {
			return v
		}
		t.Skipf("%s=%q does not exist", envVar, v)
	}
	candidates := []string{
		filepath.Join("..", "..", "build", "models", basename),
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates,
			filepath.Join(home, "Library", "Application Support", "VoiceKeyboard", "models", basename))
	}
	for _, p := range candidates {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	t.Skipf("%s not set and no %s found at %v", envVar, basename, candidates)
	return ""
}

// initONNXOnce wraps InitONNXRuntime so multiple t.Run subtests
// don't fight over re-initialising. InitONNXRuntime is idempotent
// per the speaker package, so this is just centralised path
// resolution.
func initONNXOnce(t *testing.T) {
	t.Helper()
	libPath := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if libPath == "" {
		libPath = "/opt/homebrew/lib/libonnxruntime.dylib"
	}
	if err := InitONNXRuntime(libPath); err != nil {
		t.Fatalf("InitONNXRuntime(%q): %v", libPath, err)
	}
}

// TestTSE_evaluateTSE_smoke runs evaluateTSE on the LibriSpeech
// fixture and just LOGS the four numbers — no assertions yet. This
// is a development checkpoint to eyeball that the function returns
// finite, sensible values before we layer on the real assertions in
// the next task.
func TestTSE_evaluateTSE_smoke(t *testing.T) {
	tseModel := resolveModelPath(t, "TSE_MODEL_PATH", "tse_model.onnx")
	encoderModel := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
	initONNXOnce(t)

	a, b := newLibriSpeechFixture().Voices(t)
	for _, dir := range []struct {
		name string
		idx  int
	}{{"target=A", 0}, {"target=B", 1}} {
		t.Run(dir.name, func(t *testing.T) {
			res := evaluateTSE(t, [2]voiceClip{a, b}, dir.idx, tseModel, encoderModel)
			t.Logf("SimTarget=%.4f  SimInterferer=%.4f  RMSIn=%.4f  RMSOut=%.4f",
				res.SimTarget, res.SimInterferer, res.RMSIn, res.RMSOut)
		})
	}
}
