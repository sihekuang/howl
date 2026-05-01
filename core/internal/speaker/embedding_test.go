package speaker

import "testing"

// fakeEmbedding satisfies any internal-only embed function we want to test
// in isolation. Currently we don't need a fake — the test below is a
// compile-time interface check.

func TestComputeEmbedding_SymbolExists(t *testing.T) {
	// Compile-time check that ComputeEmbedding has the expected signature.
	var fn func(string, []float32, int) ([]float32, error) = ComputeEmbedding
	_ = fn
}
