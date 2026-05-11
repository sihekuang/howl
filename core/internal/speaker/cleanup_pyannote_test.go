//go:build cleanupeval

package speaker

import (
	"context"
	"fmt"
	"testing"

	ort "github.com/yalue/onnxruntime_go"
)

func TestPyannoteSepECAPA_Name(t *testing.T) {
	a := &PyannoteSepECAPA{}
	if got := a.Name(); got != "pyannote_sep_ecapa" {
		t.Errorf("Name() = %q, want %q", got, "pyannote_sep_ecapa")
	}
}

// TestPyannoteSepECAPA_LoadsWhenPresent uses resolveModelPath's
// skip behaviour — when PYANNOTE_SEP_PATH isn't set and no candidate
// path exists, the test skips rather than fails.
func TestPyannoteSepECAPA_LoadsWhenPresent(t *testing.T) {
	pyannoteModel := resolveModelPath(t, "PYANNOTE_SEP_PATH", "pyannote_sep.onnx")
	encoderModel := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
	initONNXOnce(t)

	a, _ := newLibriSpeechFixture().Voices(t)
	emb, err := ComputeEmbedding(encoderModel, a.Samples, 192)
	if err != nil {
		t.Fatalf("ComputeEmbedding: %v", err)
	}
	adapter, err := NewPyannoteSepECAPA(pyannoteModel, encoderModel, emb)
	if err != nil {
		t.Fatalf("NewPyannoteSepECAPA: %v", err)
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
	if len(out) == 0 {
		t.Errorf("Process returned empty output")
	}
	if rms(out) == 0 {
		t.Errorf("Process returned silent output")
	}
}

// PyannoteSepECAPA runs pyannote-sep ONNX on the input mixture
// (producing N source streams) and returns the source whose ECAPA
// embedding has the highest cosine similarity to a reference
// (enrolled) embedding.
//
// Model artefact: an ONNX export of pyannote/speech-separation-ami-1.0.
// See core/BUILDING_PYANNOTE_SEP.md for export instructions.
//
// Inputs:  mixed     float32[1, T]    — 16 kHz mono audio
// Outputs: sources   float32[1, N, T] — N separated source streams
type PyannoteSepECAPA struct {
	sepSession  *ort.DynamicAdvancedSession
	encoderPath string
	ref         []float32
	encoderDim  int
}

// NewPyannoteSepECAPA loads the separator and binds the reference
// embedding. encoderPath is the speaker encoder ONNX (used at
// inference time to embed each separated source for cosine pick).
func NewPyannoteSepECAPA(sepModelPath, encoderPath string, refEmbedding []float32) (*PyannoteSepECAPA, error) {
	if len(refEmbedding) == 0 {
		return nil, fmt.Errorf("pyannote_sep_ecapa: empty reference embedding")
	}
	captured := make([]float32, len(refEmbedding))
	copy(captured, refEmbedding)
	sess, err := ort.NewDynamicAdvancedSession(
		sepModelPath,
		[]string{"mixed"},
		[]string{"sources"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("pyannote_sep_ecapa: load %q: %w", sepModelPath, err)
	}
	return &PyannoteSepECAPA{
		sepSession:  sess,
		encoderPath: encoderPath,
		ref:         captured,
		encoderDim:  len(captured),
	}, nil
}

func (a *PyannoteSepECAPA) Name() string { return "pyannote_sep_ecapa" }

// Process runs the separator on mixed, embeds each emitted source
// with the speaker encoder, and returns the source whose embedding
// has highest cosine similarity to the bound reference.
//
// If the separator emits a single source (degenerate output), it is
// returned as-is — the cosine pick is a no-op in that case.
func (a *PyannoteSepECAPA) Process(_ context.Context, mixed []float32) ([]float32, error) {
	if a.sepSession == nil {
		// Empty adapter (used only for Name() in unit tests).
		out := make([]float32, len(mixed))
		copy(out, mixed)
		return out, nil
	}
	mixedT, err := ort.NewTensor(ort.NewShape(1, int64(len(mixed))), mixed)
	if err != nil {
		return nil, fmt.Errorf("pyannote_sep_ecapa: mixed tensor: %w", err)
	}
	defer mixedT.Destroy()

	// We don't know N (source count) at compile time; allocate output
	// for the model's documented max (3 for AMI-1.0). If your export
	// produces a different N, update both the shape and the iteration
	// below.
	const maxSources = 3
	outT, err := ort.NewEmptyTensor[float32](ort.NewShape(1, maxSources, int64(len(mixed))))
	if err != nil {
		return nil, fmt.Errorf("pyannote_sep_ecapa: output tensor: %w", err)
	}
	defer outT.Destroy()

	if err := a.sepSession.Run([]ort.Value{mixedT}, []ort.Value{outT}); err != nil {
		return nil, fmt.Errorf("pyannote_sep_ecapa: separator inference: %w", err)
	}

	// Slice the per-source streams out of the [1, N, T] tensor and pick
	// the best by ECAPA cosine.
	flat := outT.GetData()
	sampleStride := len(mixed)
	bestIdx := 0
	bestSim := float32(-2)
	bestSource := make([]float32, sampleStride)
	for i := 0; i < maxSources; i++ {
		offset := i * sampleStride
		source := flat[offset : offset+sampleStride]
		emb, err := ComputeEmbedding(a.encoderPath, source, a.encoderDim)
		if err != nil {
			return nil, fmt.Errorf("pyannote_sep_ecapa: embed source %d: %w", i, err)
		}
		sim := cosineSimilarity(emb, a.ref)
		if sim > bestSim {
			bestSim = sim
			bestIdx = i
			copy(bestSource, source)
		}
	}
	_ = bestIdx // available for log-line decoration in matrix runner
	return bestSource, nil
}

func (a *PyannoteSepECAPA) Close() error {
	if a.sepSession != nil {
		_ = a.sepSession.Destroy()
		a.sepSession = nil
	}
	return nil
}

// Compile-time interface check.
var _ Cleanup = (*PyannoteSepECAPA)(nil)
