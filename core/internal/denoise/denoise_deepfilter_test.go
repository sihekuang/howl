//go:build deepfilter

package denoise

import (
	"math"
	"os"
	"path/filepath"
	"testing"
)

func TestDeepFilter_AttenuatesNoise(t *testing.T) {
	modelPath := filepath.Join("..", "..", "third_party", "deepfilter", "models", "DeepFilterNet3.tar.gz")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("model not vendored at %s; see Task 11 Step 5b", modelPath)
	}
	d, err := NewDeepFilter(modelPath, 100)
	if err != nil {
		t.Fatalf("NewDeepFilter: %v", err)
	}
	defer d.Close()

	// Build 10 frames of a 1kHz sine at amplitude 0.3 plus white noise at 0.3.
	const frames = 10
	const sr = 48000
	in := make([][]float32, frames)
	noisyRMS := 0.0
	for f := 0; f < frames; f++ {
		frame := make([]float32, FrameSize)
		for i := 0; i < FrameSize; i++ {
			ts := float64(f*FrameSize+i) / float64(sr)
			tone := 0.3 * math.Sin(2*math.Pi*1000*ts)
			noise := 0.3 * (math.Mod(float64(i*9301+49297), 233280)/233280 - 0.5) * 2
			frame[i] = float32(tone + noise)
			noisyRMS += float64(frame[i] * frame[i])
		}
		in[f] = frame
	}
	noisyRMS = math.Sqrt(noisyRMS / float64(frames*FrameSize))

	cleanRMS := 0.0
	for _, f := range in {
		out := d.Process(f)
		for _, s := range out {
			cleanRMS += float64(s * s)
		}
	}
	cleanRMS = math.Sqrt(cleanRMS / float64(frames*FrameSize))

	if cleanRMS >= noisyRMS {
		t.Errorf("denoised RMS (%f) should be lower than noisy RMS (%f)", cleanRMS, noisyRMS)
	}
}

func TestNewDeepFilter_EmptyModelPathErrors(t *testing.T) {
	_, err := NewDeepFilter("", 100)
	if err == nil {
		t.Fatalf("expected error for empty modelPath, got nil")
	}
}
