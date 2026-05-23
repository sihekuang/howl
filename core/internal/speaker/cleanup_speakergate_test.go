//go:build cleanupeval

package speaker

import (
	"context"
	"testing"
)

// TestSpeakerGateAdapter_Name verifies the adapter reports the right
// label for matrix output rows.
func TestSpeakerGateAdapter_Name(t *testing.T) {
	a := &SpeakerGateAdapter{} // empty adapter for name-only assertion
	if got := a.Name(); got != "speakergate" {
		t.Errorf("Name() = %q, want %q", got, "speakergate")
	}
}

// TestSpeakerGateAdapter_ProcessRunsWithModels gates the live
// inference path on the same env-var path the existing TSE harness
// uses. When models are absent, the test skips cleanly via
// resolveModelPath so CI / local runs without ONNX models still pass.
func TestSpeakerGateAdapter_ProcessRunsWithModels(t *testing.T) {
	tseModel := resolveModelPath(t, "TSE_MODEL_PATH", "tse_model.onnx")
	encoderModel := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
	initONNXOnce(t)

	// Use a libri voice clip as both reference and input — the
	// extracted output should be non-trivial (not zeros, not NaN).
	a, _ := newLibriSpeechFixture().Voices(t)
	emb, err := ComputeEmbedding(encoderModel, a.Samples, 192)
	if err != nil {
		t.Fatalf("ComputeEmbedding: %v", err)
	}

	adapter, err := NewSpeakerGateAdapter(tseModel, emb)
	if err != nil {
		t.Fatalf("NewSpeakerGateAdapter: %v", err)
	}
	defer func() {
		if err := adapter.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	}()

	out, err := adapter.Process(context.Background(), a.Samples)
	if err != nil {
		t.Fatalf("Process: %v", err)
	}
	if len(out) != len(a.Samples) {
		t.Errorf("len(out)=%d, want %d", len(out), len(a.Samples))
	}
	if rms(out) == 0 {
		t.Errorf("output is silent (RMS == 0)")
	}
}

// SpeakerGateAdapter wraps the existing SpeakerGate so it satisfies
// the harness Cleanup interface. Lives in the cleanupeval test files
// because it's a test-only adapter, not a production component.
type SpeakerGateAdapter struct {
	gate *SpeakerGate
}

// NewSpeakerGateAdapter builds a SpeakerGateAdapter from a TSE ONNX
// path and an L2-normalised reference embedding.
func NewSpeakerGateAdapter(tseModelPath string, refEmbedding []float32) (*SpeakerGateAdapter, error) {
	gate, err := NewSpeakerGate(SpeakerGateOptions{
		ModelPath: tseModelPath,
		Reference: refEmbedding,
	})
	if err != nil {
		return nil, err
	}
	return &SpeakerGateAdapter{gate: gate}, nil
}

func (a *SpeakerGateAdapter) Name() string { return "speakergate" }

func (a *SpeakerGateAdapter) Process(ctx context.Context, mixed []float32) ([]float32, error) {
	if a.gate == nil {
		// Empty adapter (used only for Name() in unit tests).
		out := make([]float32, len(mixed))
		copy(out, mixed)
		return out, nil
	}
	return a.gate.Extract(ctx, mixed)
}

func (a *SpeakerGateAdapter) Close() error {
	if a.gate == nil {
		return nil
	}
	return a.gate.Close()
}

// Compile-time interface check.
var _ Cleanup = (*SpeakerGateAdapter)(nil)
