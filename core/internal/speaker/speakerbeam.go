package speaker

import (
	"context"
	"fmt"

	"github.com/voice-keyboard/core/internal/audio"
	ort "github.com/yalue/onnxruntime_go"
)

// SpeakerGate implements TSEExtractor using the combined tse_model.onnx.
//
// The model separates mixed audio into 2 sources (ConvTasNet Libri2Mix
// sep_noisy 16k), embeds each source with the Wespeaker ECAPA-TDNN-512
// encoder (Kaldi Fbank front-end + L2-norm baked into the same ONNX), and
// hard-selects the source whose embedding has the higher cosine similarity
// to the enrolled speaker embedding. It returns actual extracted audio,
// not a gated/zeroed copy.
//
// Inputs:  mixed         float32[1, T]   — 16 kHz mono audio
// Output:  extracted     float32[1, T]   — separated audio for enrolled speaker
type SpeakerGate struct {
	session *ort.DynamicAdvancedSession
	ref     []float32 // L2-normalised enrollment embedding, captured at construction
}

// NewSpeakerGate loads tse_model.onnx and binds the enrollment reference.
// Call InitONNXRuntime before this. ref must be non-empty; its length
// must match the backend's EmbeddingDim (validated lazily on first
// inference).
func NewSpeakerGate(modelPath string, ref []float32) (*SpeakerGate, error) {
	if len(ref) == 0 {
		return nil, fmt.Errorf("speakergate: empty reference embedding")
	}
	captured := make([]float32, len(ref))
	copy(captured, ref)
	session, err := ort.NewDynamicAdvancedSession(
		modelPath,
		[]string{"mixed", "ref_embedding"},
		[]string{"extracted"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("speakergate: load %q: %w", modelPath, err)
	}
	return &SpeakerGate{session: session, ref: captured}, nil
}

func (g *SpeakerGate) Name() string    { return "tse" }
func (g *SpeakerGate) OutputRate() int { return 0 } // preserves 16 kHz input

// Process satisfies audio.Stage. Equivalent to Extract.
func (g *SpeakerGate) Process(ctx context.Context, mixed []float32) ([]float32, error) {
	return g.Extract(ctx, mixed)
}

// Extract runs speaker extraction inference using the bound reference.
//   - mixed: 16 kHz mono PCM chunk.
func (g *SpeakerGate) Extract(_ context.Context, mixed []float32) ([]float32, error) {
	mixedT, err := ort.NewTensor(ort.NewShape(1, int64(len(mixed))), mixed)
	if err != nil {
		return nil, fmt.Errorf("speakergate: mixed tensor: %w", err)
	}
	defer mixedT.Destroy()

	refT, err := ort.NewTensor(ort.NewShape(1, int64(len(g.ref))), g.ref)
	if err != nil {
		return nil, fmt.Errorf("speakergate: ref tensor: %w", err)
	}
	defer refT.Destroy()

	outT, err := ort.NewEmptyTensor[float32](ort.NewShape(1, int64(len(mixed))))
	if err != nil {
		return nil, fmt.Errorf("speakergate: output tensor: %w", err)
	}
	defer outT.Destroy()

	if err := g.session.Run([]ort.Value{mixedT, refT}, []ort.Value{outT}); err != nil {
		return nil, fmt.Errorf("speakergate: inference: %w", err)
	}

	out := make([]float32, len(mixed))
	copy(out, outT.GetData())
	return out, nil
}

// Close releases the ONNX session.
func (g *SpeakerGate) Close() error {
	return g.session.Destroy()
}

// Compile-time interface checks.
var _ audio.Stage = (*SpeakerGate)(nil)
var _ TSEExtractor = (*SpeakerGate)(nil)
