package audio

import (
	"math"
	"testing"
)

func TestRMS_DC(t *testing.T) {
	// All-0.5 signal has RMS = 0.5
	frame := make([]float32, 480)
	for i := range frame {
		frame[i] = 0.5
	}
	got := RMS(frame)
	if math.Abs(float64(got-0.5)) > 1e-5 {
		t.Errorf("RMS(0.5) = %f, want 0.5", got)
	}
}

func TestRMS_Sine(t *testing.T) {
	// A sine wave with amplitude A has RMS = A/sqrt(2)
	const N = 4800
	const A = 0.8
	frame := make([]float32, N)
	for i := range frame {
		frame[i] = float32(A * math.Sin(2*math.Pi*float64(i)/100))
	}
	got := RMS(frame)
	want := float32(A / math.Sqrt(2))
	if math.Abs(float64(got-want)) > 0.01 {
		t.Errorf("RMS(sine A=%f) = %f, want %f", A, got, want)
	}
}

func TestRMS_Empty(t *testing.T) {
	if got := RMS(nil); got != 0 {
		t.Errorf("RMS(nil) = %f, want 0", got)
	}
	if got := RMS([]float32{}); got != 0 {
		t.Errorf("RMS([]) = %f, want 0", got)
	}
}
