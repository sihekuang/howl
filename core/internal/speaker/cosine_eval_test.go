//go:build cleanupeval

package speaker

import (
	"context"
	"testing"
)

// cosineResult holds everything the cleanup harness's cosine
// assertions need from one (cleanup, mixture) run.
type cosineResult struct {
	SimTarget     float32 // cos(cleaned, target_embed)
	SimInterferer float32 // cos(cleaned, interferer_embed)  — for voice+voice; cos(cleaned, noise_embed) for voice+noise
	RMSIn         float32
	RMSOut        float32
}

// evaluateCosineRMS is the no-ONNX subset of evaluateCosine, used
// in unit tests where loading the encoder isn't desired.
func evaluateCosineRMS(mixed, target, interferer []float32, cleanup Cleanup) cosineResult {
	out, err := cleanup.Process(context.Background(), mixed)
	if err != nil {
		return cosineResult{}
	}
	return cosineResult{
		RMSIn:  rms(mixed),
		RMSOut: rms(out),
	}
}

// evaluateCosine runs the full cosine evaluator: invokes the cleanup
// adapter, computes ECAPA embeddings on the cleaned output and the
// two reference signals (target, interferer), and returns the four
// numbers.
//
// targetEmb and interfererEmb are precomputed so the matrix runner
// can amortise embedding cost across rows that share fixtures.
// encoderPath is the speaker encoder ONNX, used to embed the cleaned
// output.
//
// No assertions inside — caller decides pass/fail.
func evaluateCosine(t *testing.T, cleanup Cleanup, mixed []float32,
	targetEmb, interfererEmb []float32, encoderPath string) cosineResult {
	t.Helper()
	out, err := cleanup.Process(context.Background(), mixed)
	if err != nil {
		t.Fatalf("cleanup.Process(%s): %v", cleanup.Name(), err)
	}
	cleanedEmb, err := ComputeEmbedding(encoderPath, out, 192)
	if err != nil {
		t.Fatalf("ComputeEmbedding(cleaned): %v", err)
	}
	return cosineResult{
		SimTarget:     cosineSimilarity(cleanedEmb, targetEmb),
		SimInterferer: cosineSimilarity(cleanedEmb, interfererEmb),
		RMSIn:         rms(mixed),
		RMSOut:        rms(out),
	}
}
