package speaker

import (
	"context"
	"fmt"

	ort "github.com/yalue/onnxruntime_go"
)

// SpeakerBeamSS implements TSEExtractor using tse_model.onnx.
// The model takes (mixed [1,T], ref_audio [1,R]) and returns extracted audio [1,T].
type SpeakerBeamSS struct {
	session *ort.DynamicAdvancedSession
}

// NewSpeakerBeamSS loads tse_model.onnx from modelPath.
// Call InitONNXRuntime before this.
func NewSpeakerBeamSS(modelPath string) (*SpeakerBeamSS, error) {
	session, err := ort.NewDynamicAdvancedSession(
		modelPath,
		[]string{"mixed", "ref_audio"},
		[]string{"output"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("speakerbeam: load %q: %w", modelPath, err)
	}
	return &SpeakerBeamSS{session: session}, nil
}

// Extract runs TSE inference. mixed and ref are 16kHz mono PCM.
// Returns extracted audio of the same length as mixed.
func (s *SpeakerBeamSS) Extract(_ context.Context, mixed []float32, ref []float32) ([]float32, error) {
	mixedT, err := ort.NewTensor(ort.NewShape(1, int64(len(mixed))), mixed)
	if err != nil {
		return nil, fmt.Errorf("speakerbeam: mixed tensor: %w", err)
	}
	defer mixedT.Destroy()

	refT, err := ort.NewTensor(ort.NewShape(1, int64(len(ref))), ref)
	if err != nil {
		return nil, fmt.Errorf("speakerbeam: ref tensor: %w", err)
	}
	defer refT.Destroy()

	outT, err := ort.NewEmptyTensor[float32](ort.NewShape(1, int64(len(mixed))))
	if err != nil {
		return nil, fmt.Errorf("speakerbeam: output tensor: %w", err)
	}
	defer outT.Destroy()

	if err := s.session.Run(
		[]ort.Value{mixedT, refT},
		[]ort.Value{outT},
	); err != nil {
		return nil, fmt.Errorf("speakerbeam: inference: %w", err)
	}

	out := make([]float32, len(mixed))
	copy(out, outT.GetData())
	return out, nil
}

// Close releases the ONNX session.
func (s *SpeakerBeamSS) Close() error {
	return s.session.Destroy()
}
