package audio

import "math"

// RMS returns the root-mean-square amplitude of a frame, clamped to [0, 1].
// Returns 0 for an empty frame.
func RMS(frame []float32) float32 {
	if len(frame) == 0 {
		return 0
	}
	var sum float64
	for _, s := range frame {
		sum += float64(s) * float64(s)
	}
	out := float32(math.Sqrt(sum / float64(len(frame))))
	if out > 1 {
		out = 1
	}
	return out
}
