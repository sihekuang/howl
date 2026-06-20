package speaker

import (
	"context"
	"fmt"

	ort "github.com/yalue/onnxruntime_go"
)

// pyannoteSegmenter runs pyannote/segmentation-3.0 (ONNX) over a single 10 s
// window and decodes its powerset output into SpeakerActivity.
type pyannoteSegmenter struct {
	session *ort.DynamicAdvancedSession
}

// NewPyannoteSegmenter loads the segmentation ONNX. Call InitONNXRuntime first.
// The model must expose input "waveform" [1,1,160000] and output
// "segmentation" [1, frames, 7] (see core/BUILDING_PYANNOTE_SEG.md).
func NewPyannoteSegmenter(modelPath string) (*pyannoteSegmenter, error) {
	sess, err := ort.NewDynamicAdvancedSession(
		modelPath,
		[]string{"waveform"},
		[]string{"segmentation"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("pyannote_seg: load %q: %w", modelPath, err)
	}
	return &pyannoteSegmenter{session: sess}, nil
}

// Segment zero-pads window to 10 s, runs the model, and decodes the powerset
// output. The output frame count is read from the (auto-allocated) tensor
// shape, so no frame count is hardcoded.
func (s *pyannoteSegmenter) Segment(_ context.Context, window []float32) (SpeakerActivity, error) {
	buf := window
	if len(buf) < diarWindowLen {
		buf = make([]float32, diarWindowLen)
		copy(buf, window)
	} else if len(buf) > diarWindowLen {
		buf = buf[:diarWindowLen]
	}
	inT, err := ort.NewTensor(ort.NewShape(1, 1, int64(diarWindowLen)), buf)
	if err != nil {
		return SpeakerActivity{}, fmt.Errorf("pyannote_seg: input tensor: %w", err)
	}
	defer inT.Destroy()

	outputs := []ort.Value{nil} // ORT allocates the dynamic [1, frames, 7] output
	if err := s.session.Run([]ort.Value{inT}, outputs); err != nil {
		return SpeakerActivity{}, fmt.Errorf("pyannote_seg: inference: %w", err)
	}
	outT, ok := outputs[0].(*ort.Tensor[float32])
	if !ok {
		return SpeakerActivity{}, fmt.Errorf("pyannote_seg: unexpected output type %T", outputs[0])
	}
	defer outT.Destroy()

	shape := outT.GetShape()
	numFrames, err := framesFromShape(shape)
	if err != nil {
		return SpeakerActivity{}, err
	}
	hop := diarWindowLen / numFrames
	return powersetToActivity(outT.GetData(), shape, hop)
}

func (s *pyannoteSegmenter) Close() error {
	if s.session == nil {
		return nil
	}
	err := s.session.Destroy()
	s.session = nil
	return err
}

// framesFromShape derives the number of output frames from an ONNX output shape.
// It requires at least two dimensions (the last is the class dim) and every
// dimension must be positive. Returns the product of all dims except the last.
// For shape [1, 625, 7] it returns 625.
func framesFromShape(shape []int64) (int, error) {
	if len(shape) < 2 {
		return 0, fmt.Errorf("pyannote_seg: output rank %d < 2 (shape %v)", len(shape), shape)
	}
	numFrames := 1
	for _, d := range shape[:len(shape)-1] {
		if d <= 0 {
			return 0, fmt.Errorf("pyannote_seg: non-positive dimension %d in shape %v", d, shape)
		}
		numFrames *= int(d)
	}
	return numFrames, nil
}

// Compile-time interface check.
var _ Segmenter = (*pyannoteSegmenter)(nil)
