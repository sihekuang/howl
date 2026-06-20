package speaker

import (
	"fmt"
	"math"
)

const (
	diarSampleRate  = 16000
	diarWindowLen   = diarSampleRate * 10 // 160000 samples = 10 s
	diarNumClasses  = 7
	diarMaxSpeakers = 3
)

// powersetClasses maps each of the 7 output classes to the set of local
// speakers (0-based) active in that class, per pyannote/segmentation-3.0.
var powersetClasses = [diarNumClasses][]int{
	{},     // 0: non-speech
	{0},    // 1
	{1},    // 2
	{2},    // 3
	{0, 1}, // 4
	{0, 2}, // 5
	{1, 2}, // 6
}

// SpeakerActivity is per-frame local-speaker activity for one window.
type SpeakerActivity struct {
	Frames          [][]bool // [frame][localSpeaker] active? (len diarMaxSpeakers)
	FrameHopSamples int      // samples per frame at 16 kHz
}

// powersetToActivity decodes a pyannote powerset segmentation tensor into
// per-frame speaker activity. data is the flat output; shape is its ONNX
// shape (leading size-1 dims allowed); the final dim must be 7.
func powersetToActivity(data []float32, shape []int64, hopSamples int) (SpeakerActivity, error) {
	if len(shape) == 0 || shape[len(shape)-1] != diarNumClasses {
		return SpeakerActivity{}, fmt.Errorf("diarmask: expected last dim %d, got shape %v", diarNumClasses, shape)
	}
	numFrames := 1
	for _, d := range shape[:len(shape)-1] {
		numFrames *= int(d)
	}
	if numFrames*diarNumClasses != len(data) {
		return SpeakerActivity{}, fmt.Errorf("diarmask: shape %v implies %d values, got %d", shape, numFrames*diarNumClasses, len(data))
	}
	frames := make([][]bool, numFrames)
	for f := 0; f < numFrames; f++ {
		row := data[f*diarNumClasses : (f+1)*diarNumClasses]
		best := 0
		for c := 1; c < diarNumClasses; c++ {
			if row[c] > row[best] {
				best = c
			}
		}
		active := make([]bool, diarMaxSpeakers)
		for _, spk := range powersetClasses[best] {
			active[spk] = true
		}
		frames[f] = active
	}
	return SpeakerActivity{Frames: frames, FrameHopSamples: hopSamples}, nil
}

// buildFrameMask returns per-frame keep/drop for the target track. A frame is
// kept whenever the target is active (including overlap with other speakers).
func buildFrameMask(act SpeakerActivity, targetIdx int) []bool {
	m := make([]bool, len(act.Frames))
	for f, active := range act.Frames {
		if targetIdx >= 0 && targetIdx < len(active) {
			m[f] = active[targetIdx]
		}
	}
	return m
}

// frameMaskToSamples upsamples a frame-level boolean mask to an n-sample gain
// curve in [0,1], applying a raised-cosine fade of rampSamples at the start and
// end of every active run (including the signal boundaries) to avoid clicks.
// At the center of a long run the gain is exactly 1; at a run edge it is 0.
func frameMaskToSamples(frameMask []bool, hopSamples, n, rampSamples int) []float32 {
	gain := make([]float32, n)
	if hopSamples <= 0 {
		return gain
	}
	on := func(i int) bool {
		if i < 0 || i >= n {
			return false // off the ends of the signal → treat as inactive
		}
		f := i / hopSamples
		return f < len(frameMask) && frameMask[f]
	}
	for i := 0; i < n; i++ {
		if !on(i) {
			continue
		}
		if rampSamples <= 0 {
			gain[i] = 1
			continue
		}
		// d = distance to the nearer edge of this active run, capped at
		// rampSamples (symmetric expansion stops when either side turns off).
		d := 0
		for d < rampSamples && on(i-d-1) && on(i+d+1) {
			d++
		}
		t := float64(d) / float64(rampSamples)
		gain[i] = float32(0.5 * (1 - math.Cos(math.Pi*t)))
	}
	return gain
}

// applyMask multiplies mixed by gain element-wise. Returns a fresh slice.
func applyMask(mixed, gain []float32) []float32 {
	out := make([]float32, len(mixed))
	for i := range mixed {
		if i < len(gain) {
			out[i] = mixed[i] * gain[i]
		}
	}
	return out
}
