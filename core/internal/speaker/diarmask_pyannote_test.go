//go:build speakerbeam || cleanupeval

package speaker

import (
	"context"
	"testing"
)

func TestPyannoteSegmenter_RealModelSmoke(t *testing.T) {
	modelPath := resolveModelPath(t, "PYANNOTE_SEG_PATH", "pyannote_seg.onnx") // t.Skip if absent
	initONNXOnce(t)
	seg, err := NewPyannoteSegmenter(modelPath)
	if err != nil {
		t.Fatalf("NewPyannoteSegmenter: %v", err)
	}
	defer seg.Close()
	// 10 s of low-level noise; we only assert shape sanity, not labels.
	window := make([]float32, diarWindowLen)
	for i := range window {
		window[i] = float32((i%7))*0.001 - 0.003
	}
	act, err := seg.Segment(context.Background(), window)
	if err != nil {
		t.Fatalf("Segment: %v", err)
	}
	if len(act.Frames) == 0 {
		t.Errorf("no frames returned")
	}
	if act.FrameHopSamples <= 0 {
		t.Errorf("FrameHopSamples=%d, want > 0", act.FrameHopSamples)
	}
	for _, fr := range act.Frames {
		if len(fr) != diarMaxSpeakers {
			t.Fatalf("frame has %d speakers, want %d", len(fr), diarMaxSpeakers)
		}
	}
}
