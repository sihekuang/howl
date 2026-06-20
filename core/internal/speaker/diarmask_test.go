package speaker

import (
	"reflect"
	"testing"
)

func TestPowersetToActivity_MapsClassesToSpeakerSets(t *testing.T) {
	// 3 frames, 7 classes each. Argmax picks class 1 ({0}), class 4 ({0,1}), class 0 (∅).
	hi := float32(9)
	data := []float32{
		0, hi, 0, 0, 0, 0, 0, // frame 0 → class 1 → {0}
		0, 0, 0, 0, hi, 0, 0, // frame 1 → class 4 → {0,1}
		hi, 0, 0, 0, 0, 0, 0, // frame 2 → class 0 → {}
	}
	act, err := powersetToActivity(data, []int64{1, 3, 7}, 256)
	if err != nil {
		t.Fatalf("powersetToActivity: %v", err)
	}
	if act.FrameHopSamples != 256 {
		t.Errorf("FrameHopSamples=%d, want 256", act.FrameHopSamples)
	}
	want := [][]bool{
		{true, false, false},
		{true, true, false},
		{false, false, false},
	}
	if !reflect.DeepEqual(act.Frames, want) {
		t.Errorf("Frames=%v, want %v", act.Frames, want)
	}
}

func TestPowersetToActivity_RejectsWrongClassCount(t *testing.T) {
	if _, err := powersetToActivity([]float32{0, 0, 0}, []int64{1, 3}, 256); err == nil {
		t.Errorf("expected error for last dim != 7")
	}
}
