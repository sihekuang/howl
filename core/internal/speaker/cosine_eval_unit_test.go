//go:build cleanupeval

package speaker

import (
	"testing"
)

// TestEvaluateCosine_PassthroughReturnsRMSEqual is a unit test that
// doesn't need ONNX models. With Passthrough as the cleanup,
// RMSIn should equal RMSOut.
func TestEvaluateCosine_PassthroughReturnsRMSEqual(t *testing.T) {
	mixed := make([]float32, 16000)
	for i := range mixed {
		mixed[i] = 0.5
	}
	target := mixed   // unused for RMS axis but required by signature
	interferer := mixed
	res := evaluateCosineRMS(mixed, target, interferer, NewPassthrough())
	if res.RMSIn == 0 {
		t.Fatalf("RMSIn should be nonzero for nonzero input")
	}
	if res.RMSOut != res.RMSIn {
		t.Errorf("Passthrough should preserve RMS: in=%f out=%f", res.RMSIn, res.RMSOut)
	}
}

func TestLibriSpeechFixture_TranscriptsLoad(t *testing.T) {
	fix := newLibriSpeechFixture()
	tA, tB := fix.Transcripts(t)
	if tA == "" || tB == "" {
		t.Fatalf("transcripts empty: A=%q B=%q", tA, tB)
	}
	if tA == tB {
		t.Errorf("transcripts identical — wrong files?")
	}
	// Sanity: transcripts should each be at least a few words.
	if len(tA) < 5 || len(tB) < 5 {
		t.Errorf("transcripts suspiciously short: A=%q B=%q", tA, tB)
	}
}
