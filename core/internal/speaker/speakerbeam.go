package speaker

import (
	"context"
	"fmt"

	ort "github.com/yalue/onnxruntime_go"
)

// SpeakerGate implements TSEExtractor using the combined tse_model.onnx.
//
// The model separates mixed audio into 2 sources (ConvTasNet), embeds each
// source with the resemblyzer GE2E encoder, and soft-selects the source
// closest to the enrolled speaker embedding. It returns actual extracted audio,
// not a gated/zeroed copy.
//
// Inputs:  mixed         float32[1, T]   — 16 kHz mono audio
//
//	ref_embedding float32[1, 256] — L2-normalised enrolled speaker embedding
//
// Output:  extracted     float32[1, T]   — separated audio for enrolled speaker
type SpeakerGate struct {
	session *ort.DynamicAdvancedSession
}

// NewSpeakerGate loads tse_model.onnx from modelPath.
// Call InitONNXRuntime before this.
func NewSpeakerGate(modelPath string) (*SpeakerGate, error) {
	session, err := ort.NewDynamicAdvancedSession(
		modelPath,
		[]string{"mixed", "ref_embedding"},
		[]string{"extracted"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("speakergate: load %q: %w", modelPath, err)
	}
	return &SpeakerGate{session: session}, nil
}

// Extract runs speaker extraction inference.
//   - mixed: 16 kHz mono PCM chunk.
//   - ref:   L2-normalised 256-dim enrollment embedding (from enrollment.emb).
//
// Returns the separated audio for the enrolled speaker.
func (g *SpeakerGate) Extract(_ context.Context, mixed []float32, ref []float32) ([]float32, error) {
	mixedT, err := ort.NewTensor(ort.NewShape(1, int64(len(mixed))), mixed)
	if err != nil {
		return nil, fmt.Errorf("speakergate: mixed tensor: %w", err)
	}
	defer mixedT.Destroy()

	refT, err := ort.NewTensor(ort.NewShape(1, int64(len(ref))), ref)
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
