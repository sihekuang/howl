package speaker

import (
	"context"
	"fmt"
	"math"

	ort "github.com/yalue/onnxruntime_go"
)

// SpeakerGate implements TSEExtractor using the speaker encoder ONNX model.
// It computes cosine similarity between the enrolled speaker embedding and
// each incoming audio chunk's embedding; chunks below Threshold are zeroed.
//
// The ONNX model (tse_model.onnx) takes raw 16 kHz mono audio [1, T] and
// returns an L2-normalised 256-dim speaker embedding [1, 256].
type SpeakerGate struct {
	session   *ort.DynamicAdvancedSession
	Threshold float32
}

// NewSpeakerGate loads tse_model.onnx from modelPath.
// Call InitONNXRuntime before this.
// threshold is the cosine-similarity cutoff; chunks below it are silenced.
// 0.45 works well for typical indoor conditions.
func NewSpeakerGate(modelPath string, threshold float32) (*SpeakerGate, error) {
	session, err := ort.NewDynamicAdvancedSession(
		modelPath,
		[]string{"audio"},
		[]string{"embedding"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("speakergate: load %q: %w", modelPath, err)
	}
	return &SpeakerGate{session: session, Threshold: threshold}, nil
}

// Extract gates the chunk based on speaker identity.
//   - mixed: 16 kHz mono PCM chunk to check.
//   - ref:   L2-normalised 256-dim enrollment embedding (from enrollment.emb).
//
// Returns mixed unchanged when cosine similarity ≥ Threshold, or zeros otherwise.
func (g *SpeakerGate) Extract(_ context.Context, mixed []float32, ref []float32) ([]float32, error) {
	audioT, err := ort.NewTensor(ort.NewShape(1, int64(len(mixed))), mixed)
	if err != nil {
		return nil, fmt.Errorf("speakergate: audio tensor: %w", err)
	}
	defer audioT.Destroy()

	embT, err := ort.NewEmptyTensor[float32](ort.NewShape(1, 256))
	if err != nil {
		return nil, fmt.Errorf("speakergate: embedding tensor: %w", err)
	}
	defer embT.Destroy()

	if err := g.session.Run([]ort.Value{audioT}, []ort.Value{embT}); err != nil {
		return nil, fmt.Errorf("speakergate: inference: %w", err)
	}

	sim := cosineSimilarity(embT.GetData(), ref)
	if sim >= g.Threshold {
		return mixed, nil
	}
	return make([]float32, len(mixed)), nil
}

// Close releases the ONNX session.
func (g *SpeakerGate) Close() error {
	return g.session.Destroy()
}

func cosineSimilarity(a, b []float32) float32 {
	if len(a) != len(b) || len(a) == 0 {
		return 0
	}
	var dot, na, nb float64
	for i := range a {
		dot += float64(a[i]) * float64(b[i])
		na += float64(a[i]) * float64(a[i])
		nb += float64(b[i]) * float64(b[i])
	}
	denom := math.Sqrt(na) * math.Sqrt(nb)
	if denom == 0 {
		return 0
	}
	return float32(dot / denom)
}
