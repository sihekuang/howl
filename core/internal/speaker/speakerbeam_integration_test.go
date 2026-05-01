//go:build speakerbeam

package speaker

import (
	"context"
	"math"
	"os"
	"testing"
)

func TestSpeakerBeamSS_ReducesInterferer(t *testing.T) {
	libPath := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if libPath == "" {
		libPath = "/opt/homebrew/lib/libonnxruntime.dylib"
	}
	if err := InitONNXRuntime(libPath); err != nil {
		t.Fatalf("InitONNXRuntime: %v", err)
	}
	modelPath := os.Getenv("TSE_MODEL_PATH")
	if modelPath == "" {
		t.Skip("TSE_MODEL_PATH not set")
	}

	tse, err := NewSpeakerGate(modelPath)
	if err != nil {
		t.Fatalf("NewSpeakerGate: %v", err)
	}
	defer tse.Close()

	const n = 16000
	// Target speaker: 440Hz sine; interferer: 880Hz sine
	target := make([]float32, n)
	interferer := make([]float32, n)
	for i := range target {
		target[i] = 0.3 * float32(math.Sin(2*math.Pi*440*float64(i)/16000))
		interferer[i] = 0.3 * float32(math.Sin(2*math.Pi*880*float64(i)/16000))
	}
	mixed := make([]float32, n)
	for i := range mixed {
		mixed[i] = target[i] + interferer[i]
	}

	out, err := tse.Extract(context.Background(), mixed, target)
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}

	// RMS of (signal - target) should be lower after TSE than in the mix.
	rmsResidual := func(a, b []float32) float64 {
		var sum float64
		for i := range a {
			d := float64(a[i] - b[i])
			sum += d * d
		}
		return math.Sqrt(sum / float64(len(a)))
	}
	rmsMixed := rmsResidual(mixed, target)
	rmsOut := rmsResidual(out, target)
	if rmsOut >= rmsMixed {
		t.Errorf("TSE did not improve separation: rmsOut=%f >= rmsMixed=%f", rmsOut, rmsMixed)
	}
}
