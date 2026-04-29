package resample

import (
	"math"
	"testing"
)

func TestDecimate3_OutputLengthIsThird(t *testing.T) {
	in := make([]float32, 4800) // 100ms @ 48kHz
	d := NewDecimate3()
	out := d.Process(in)
	wantLen := 4800 / 3
	if len(out) < wantLen-1 || len(out) > wantLen+1 {
		t.Errorf("output length = %d, expected ~%d", len(out), wantLen)
	}
}

func TestDecimate3_DCSignalPreserved(t *testing.T) {
	// Constant signal should remain (close to) constant after decimation.
	in := make([]float32, 4800)
	for i := range in {
		in[i] = 0.5
	}
	d := NewDecimate3()
	out := d.Process(in)

	// Check the steady-state samples (skip initial filter delay).
	const skip = 200
	if len(out) <= skip+10 {
		t.Fatalf("output too short for steady-state check: %d", len(out))
	}
	for _, v := range out[skip : skip+10] {
		if math.Abs(float64(v-0.5)) > 0.01 {
			t.Errorf("steady-state sample = %f, want ~0.5", v)
		}
	}
}

func TestDecimate3_LowFrequencyPassesThrough(t *testing.T) {
	// 1kHz sine well below the 8kHz post-decimation Nyquist should
	// pass through with most of its amplitude intact.
	const fs = 48000
	const f = 1000.0
	in := make([]float32, fs/10) // 100ms
	for i := range in {
		in[i] = float32(math.Sin(2 * math.Pi * f * float64(i) / fs))
	}
	d := NewDecimate3()
	out := d.Process(in)

	// Compute peak amplitude in steady-state region.
	peak := 0.0
	for _, v := range out[100:] {
		if math.Abs(float64(v)) > peak {
			peak = math.Abs(float64(v))
		}
	}
	if peak < 0.7 {
		t.Errorf("1kHz peak amplitude %f, expected > 0.7", peak)
	}
}

func TestDecimate3_HighFrequencyAttenuated(t *testing.T) {
	// 12kHz sine is above the 8kHz post-decimation Nyquist; the
	// low-pass filter should attenuate it heavily before decimation.
	const fs = 48000
	const f = 12000.0
	in := make([]float32, fs/10)
	for i := range in {
		in[i] = float32(math.Sin(2 * math.Pi * f * float64(i) / fs))
	}
	d := NewDecimate3()
	out := d.Process(in)

	peak := 0.0
	for _, v := range out[100:] {
		if math.Abs(float64(v)) > peak {
			peak = math.Abs(float64(v))
		}
	}
	if peak > 0.2 {
		t.Errorf("12kHz peak amplitude %f, expected < 0.2", peak)
	}
}
