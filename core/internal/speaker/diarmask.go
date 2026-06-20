package speaker

import (
	"fmt"
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
