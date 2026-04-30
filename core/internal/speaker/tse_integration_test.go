//go:build speakerbeam

package speaker

import (
	"context"
	"math"
	"os"
	"testing"
)

func rmsOf(s []float32) float64 {
	var sum float64
	for _, v := range s {
		sum += float64(v) * float64(v)
	}
	return math.Sqrt(sum / float64(len(s)))
}

// TestTSE_ReducesInterfererRMS feeds a 2-speaker mixture through TSE and
// asserts the extracted output is closer (in RMS) to the target than the
// raw mixed signal is.
func TestTSE_ReducesInterfererRMS(t *testing.T) {
	libPath := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if libPath == "" {
		libPath = "/opt/homebrew/lib/libonnxruntime.dylib"
	}
	modelPath := os.Getenv("TSE_MODEL_PATH")
	if modelPath == "" {
		t.Skip("TSE_MODEL_PATH not set — set to core/build/models/tse_model.onnx")
	}

	if err := InitONNXRuntime(libPath); err != nil {
		t.Fatalf("InitONNXRuntime: %v", err)
	}

	tse, err := NewSpeakerBeamSS(modelPath)
	if err != nil {
		t.Fatalf("NewSpeakerBeamSS: %v", err)
	}
	defer tse.Close()

	const n = 32000 // 2 seconds at 16kHz
	target := make([]float32, n)
	interferer := make([]float32, n)
	mixed := make([]float32, n)
	for i := range target {
		target[i] = 0.25 * float32(math.Sin(2*math.Pi*300*float64(i)/16000))
		interferer[i] = 0.25 * float32(math.Sin(2*math.Pi*1200*float64(i)/16000))
		mixed[i] = target[i] + interferer[i]
	}

	out, err := tse.Extract(context.Background(), mixed, target)
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}

	// Compute residual RMS vs target
	residualMixed := make([]float32, n)
	residualOut := make([]float32, n)
	for i := range mixed {
		residualMixed[i] = mixed[i] - target[i]
		residualOut[i] = out[i] - target[i]
	}

	rmsMixed := rmsOf(residualMixed)
	rmsOut := rmsOf(residualOut)

	t.Logf("Interferer RMS in mixed: %.4f", rmsMixed)
	t.Logf("Interferer RMS in TSE output: %.4f", rmsOut)

	if rmsOut >= rmsMixed {
		t.Errorf("TSE did not reduce interferer: rmsOut=%.4f >= rmsMixed=%.4f", rmsOut, rmsMixed)
	}
}
