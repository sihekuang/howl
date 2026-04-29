// Package resample provides sample-rate conversion. Decimate3 implements
// a 3:1 FIR low-pass + decimator suitable for 48kHz → 16kHz.
//
// The filter is a 33-tap Hamming-windowed sinc with cutoff at 7.5kHz
// (slightly below the 8kHz post-decimation Nyquist to leave headroom).
// On each output sample (every 3rd input), the full 33-tap FIR is
// computed against the rolling delay line. A true polyphase decomposition
// would split the FIR into 3 sub-filters of 11 taps each and select one
// per output; the output is mathematically identical, the chosen
// direct-form is simpler. The 33-tap length keeps polyphase as a
// drop-in optimization later if needed.
package resample

import "math"

const (
	taps   = 33      // FIR length; 33 = 3×11 keeps a polyphase split as a future drop-in option
	decim  = 3       // 48000 / 16000
	cutoff = 7500.0  // Hz, slightly below 8kHz post-decim Nyquist
	srIn   = 48000.0 // input sample rate
)

// fir holds the FIR coefficients computed once at package init.
var fir = makeFir()

func makeFir() []float32 {
	coeffs := make([]float32, taps)
	mid := float64(taps-1) / 2.0
	for n := 0; n < taps; n++ {
		x := float64(n) - mid
		var sinc float64
		if x == 0 {
			sinc = 2.0 * cutoff / srIn
		} else {
			arg := 2.0 * math.Pi * cutoff * x / srIn
			sinc = math.Sin(arg) / (math.Pi * x)
		}
		hamming := 0.54 - 0.46*math.Cos(2.0*math.Pi*float64(n)/float64(taps-1))
		coeffs[n] = float32(sinc * hamming)
	}
	// Normalize to unity DC gain.
	sum := float32(0)
	for _, c := range coeffs {
		sum += c
	}
	for i := range coeffs {
		coeffs[i] /= sum
	}
	return coeffs
}

type Decimate3 struct {
	// rolling delay line of the last `taps` input samples
	delay []float32
	// counter for which input sample index we're on (0..decim-1);
	// we only emit an output when this reaches 0
	phase int
}

func NewDecimate3() *Decimate3 {
	return &Decimate3{delay: make([]float32, taps)}
}

// Process consumes input samples and returns output samples. State is
// preserved across calls so streamed audio works (no boundary glitches).
func (d *Decimate3) Process(in []float32) []float32 {
	out := make([]float32, 0, len(in)/decim+1)
	for _, x := range in {
		// shift delay line left, append new sample
		copy(d.delay, d.delay[1:])
		d.delay[len(d.delay)-1] = x

		d.phase++
		if d.phase < decim {
			continue
		}
		d.phase = 0

		// FIR convolution
		var acc float32
		for i, c := range fir {
			acc += c * d.delay[i]
		}
		out = append(out, acc)
	}
	return out
}

// Reset clears the internal delay line. Use at the start of a new utterance.
func (d *Decimate3) Reset() {
	for i := range d.delay {
		d.delay[i] = 0
	}
	d.phase = 0
}
