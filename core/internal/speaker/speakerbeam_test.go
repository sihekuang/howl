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
