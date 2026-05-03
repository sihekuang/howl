package speaker

import (
	"context"
	"testing"
)

// fakeTSE satisfies TSEExtractor for pipeline tests.
type fakeTSE struct {
	extractCalls  int
	returnSamples []float32
}

func (f *fakeTSE) Name() string    { return "fake-tse" }
func (f *fakeTSE) OutputRate() int { return 0 }

func (f *fakeTSE) Process(ctx context.Context, mixed []float32) ([]float32, error) {
	return f.Extract(ctx, mixed)
}

func (f *fakeTSE) Extract(_ context.Context, mixed []float32) ([]float32, error) {
	f.extractCalls++
	if f.returnSamples != nil {
		return f.returnSamples, nil
	}
	// default: return zeros of same length as mixed
	return make([]float32, len(mixed)), nil
}

func TestFakeTSE_ImplementsInterface(t *testing.T) {
	var _ TSEExtractor = &fakeTSE{}
}

func TestNewSpeakerGate_EmptyRefRejected(t *testing.T) {
	cases := [][]float32{nil, {}}
	for _, ref := range cases {
		// ModelPath irrelevant — empty-ref check happens first.
		_, err := NewSpeakerGate(SpeakerGateOptions{ModelPath: "does-not-matter.onnx", Reference: ref})
		if err == nil {
			t.Errorf("expected error for empty ref %#v, got nil", ref)
		}
	}
}

func TestCosineSimilarity_Identical(t *testing.T) {
	a := []float32{1, 0, 0} // already L2-normalized
	if got := cosineSimilarity(a, a); got < 0.999 || got > 1.001 {
		t.Errorf("got %v, want ~1.0", got)
	}
}

func TestCosineSimilarity_Orthogonal(t *testing.T) {
	a := []float32{1, 0}
	b := []float32{0, 1}
	if got := cosineSimilarity(a, b); got < -0.001 || got > 0.001 {
		t.Errorf("got %v, want ~0.0", got)
	}
}

func TestCosineSimilarity_LengthMismatchReturnsZero(t *testing.T) {
	a := []float32{1, 0}
	b := []float32{1, 0, 0}
	if got := cosineSimilarity(a, b); got != 0 {
		t.Errorf("got %v, want 0 for length mismatch", got)
	}
}

func TestApplyThreshold_BelowReturnsZeros(t *testing.T) {
	in := []float32{1, 2, 3, 4}
	out := applyThreshold(in, 0.3, 0.5)
	if len(out) != len(in) {
		t.Fatalf("len = %d, want %d", len(out), len(in))
	}
	for i, v := range out {
		if v != 0 {
			t.Errorf("out[%d] = %v, want 0", i, v)
		}
	}
}

func TestApplyThreshold_AboveReturnsInput(t *testing.T) {
	in := []float32{1, 2, 3, 4}
	out := applyThreshold(in, 0.7, 0.5)
	if len(out) != 4 || out[0] != 1 {
		t.Errorf("expected pass-through, got %v", out)
	}
}

func TestApplyThreshold_ZeroDisables(t *testing.T) {
	in := []float32{1, 2, 3, 4}
	out := applyThreshold(in, 0.0, 0.0)
	if out[0] != 1 {
		t.Errorf("threshold=0 should pass through, got %v", out)
	}
}

func TestFakeTSE_ReturnsZerosForMixed(t *testing.T) {
	f := &fakeTSE{}
	mixed := []float32{0.1, 0.2, 0.3}
	out, err := f.Extract(context.Background(), mixed)
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if len(out) != len(mixed) {
		t.Errorf("len(out) = %d, want %d", len(out), len(mixed))
	}
	for i, v := range out {
		if v != 0 {
			t.Errorf("out[%d] = %f, want 0", i, v)
		}
	}
	if f.extractCalls != 1 {
		t.Errorf("extractCalls = %d, want 1", f.extractCalls)
	}
}
