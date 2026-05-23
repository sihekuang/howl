//go:build speakerbeam || cleanupeval

package speaker

import (
	"math"
	"testing"
)

func TestMixAtSNR_ZeroSNRMatchesEqualLevel(t *testing.T) {
	target := []float32{1, 0, 1, 0, 1, 0}
	noise := []float32{0, 1, 0, 1, 0, 1}
	mixed := mixAtSNR(target, noise, 0)
	if len(mixed) != len(target) {
		t.Fatalf("len(mixed)=%d, want %d", len(mixed), len(target))
	}
	// At 0 dB, noise gain == 1, so each sample is (target[i] + noise[i]) * 0.5.
	for i := range mixed {
		want := (target[i] + noise[i]) * 0.5
		if math.Abs(float64(mixed[i]-want)) > 1e-6 {
			t.Errorf("mixed[%d]=%f, want %f", i, mixed[i], want)
		}
	}
}

func TestMixAtSNR_NegativeSNRBoostsNoise(t *testing.T) {
	target := []float32{1, 1, 1, 1}
	noise := []float32{1, 1, 1, 1}
	// At -6 dB, noise gain ≈ 10^(6/20) ≈ 1.995.
	mixed := mixAtSNR(target, noise, -6)
	want := float32(0.5 * (1.0 + 1.995))
	if math.Abs(float64(mixed[0]-want)) > 0.01 {
		t.Errorf("mixed[0]=%f, want ~%f (noise should be ~2x amplitude)", mixed[0], want)
	}
}

func TestMixAtSNR_PadsShorterInput(t *testing.T) {
	target := []float32{1, 1, 1, 1, 1}
	noise := []float32{1, 1}
	mixed := mixAtSNR(target, noise, 0)
	if len(mixed) != 5 {
		t.Fatalf("len(mixed)=%d, want 5 (max of inputs)", len(mixed))
	}
	// First 2 samples have noise; last 3 have target only at gain 0.5.
	if mixed[3] != 0.5 || mixed[4] != 0.5 {
		t.Errorf("mixed[3:5]=%v, want [0.5 0.5]", mixed[3:5])
	}
}

func TestMixThree_AddsAllThreeSources(t *testing.T) {
	a := []float32{1, 1, 1, 1}
	b := []float32{1, 1, 1, 1}
	n := []float32{1, 1, 1, 1}
	// Voice B at 0 dB → gain 1; noise at 0 dB → gain 1.
	// mix = (a + b*1 + n*1) * 0.5 = 1.5
	mixed := mixThree(a, b, n, 0, 0)
	if mixed[0] != 1.5 {
		t.Errorf("mixed[0]=%f, want 1.5", mixed[0])
	}
}

// mixAtSNR scales noise so target_rms / noise_rms ≈ 10^(snrDB/20),
// then sums target + scaled_noise * 0.5 element-wise. Pads the
// shorter signal with zeros to the longer length.
//
// SNR convention: positive dB means target is louder than noise;
// negative dB means noise dominates.
func mixAtSNR(target, noise []float32, snrDB float64) []float32 {
	n := len(target)
	if len(noise) > n {
		n = len(noise)
	}
	gain := float32(math.Pow(10, -snrDB/20.0))
	out := make([]float32, n)
	for i := 0; i < n; i++ {
		var t, ns float32
		if i < len(target) {
			t = target[i]
		}
		if i < len(noise) {
			ns = noise[i]
		}
		out[i] = (t + ns*gain) * 0.5
	}
	return out
}

// mixThree adds a third signal at its own SNR relative to the
// target. Used for voice + voice + noise conditions. Pads to the
// longest input.
func mixThree(target, voiceB, noise []float32, snrVoiceDB, snrNoiseDB float64) []float32 {
	n := len(target)
	if len(voiceB) > n {
		n = len(voiceB)
	}
	if len(noise) > n {
		n = len(noise)
	}
	gainV := float32(math.Pow(10, -snrVoiceDB/20.0))
	gainN := float32(math.Pow(10, -snrNoiseDB/20.0))
	out := make([]float32, n)
	for i := 0; i < n; i++ {
		var t, b, ns float32
		if i < len(target) {
			t = target[i]
		}
		if i < len(voiceB) {
			b = voiceB[i]
		}
		if i < len(noise) {
			ns = noise[i]
		}
		out[i] = (t + b*gainV + ns*gainN) * 0.5
	}
	return out
}
