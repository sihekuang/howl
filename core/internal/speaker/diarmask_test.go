package speaker

import (
	"math"
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

func TestBuildFrameMask_InclusionBias(t *testing.T) {
	act := SpeakerActivity{Frames: [][]bool{
		{true, false, false}, // target 0 active
		{true, true, false},  // target 0 + spk1 overlap → still kept
		{false, true, false}, // only spk1 → dropped
	}}
	got := buildFrameMask(act, 0)
	want := []bool{true, true, false}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("frame %d: got %v want %v", i, got[i], want[i])
		}
	}
}

func TestFrameMaskToSamples_RampEndpointsAndPlateau(t *testing.T) {
	// One active frame of 100 samples, hop=100, ramp=10. Gain rises 0→1, plateaus, no fall (ends active).
	gain := frameMaskToSamples([]bool{true}, 100, 100, 10)
	if len(gain) != 100 {
		t.Fatalf("len=%d want 100", len(gain))
	}
	if gain[0] != 0 {
		t.Errorf("gain[0]=%f want 0 (ramp start)", gain[0])
	}
	if math.Abs(float64(gain[50]-1)) > 1e-6 {
		t.Errorf("gain[50]=%f want 1 (plateau)", gain[50])
	}
	for i := 1; i < 10; i++ { // ramp is monotonic non-decreasing
		if gain[i] < gain[i-1] {
			t.Errorf("ramp not monotonic at %d: %f < %f", i, gain[i], gain[i-1])
		}
	}
}

func TestApplyMask_ScalesAndCopies(t *testing.T) {
	in := []float32{1, 1, 1, 1}
	gain := []float32{0, 0.5, 1, 0}
	out := applyMask(in, gain)
	want := []float32{0, 0.5, 1, 0}
	for i := range want {
		if out[i] != want[i] {
			t.Errorf("out[%d]=%f want %f", i, out[i], want[i])
		}
	}
	in[0] = 9 // mutation must not affect out
	if out[0] != 0 {
		t.Errorf("applyMask aliased input")
	}
}
