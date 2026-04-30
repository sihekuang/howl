package pipeline

import (
	"math"
	"testing"
)

// tone16k generates `ms` milliseconds of a 440Hz sine wave at 16kHz, peak amplitude `peak`.
func tone16k(ms int, peak float32) []float32 {
	n := 16 * ms
	out := make([]float32, n)
	for i := 0; i < n; i++ {
		out[i] = peak * float32(math.Sin(2*math.Pi*440*float64(i)/16000))
	}
	return out
}

// silence16k generates `ms` milliseconds of zero samples at 16kHz.
func silence16k(ms int) []float32 {
	return make([]float32, 16*ms)
}

func TestChunker_EmitsOnVADSilence(t *testing.T) {
	var emitted []ChunkEmission
	c := NewChunker(DefaultChunkerOpts(), func(e ChunkEmission) {
		emitted = append(emitted, e)
	})

	c.Push(tone16k(1000, 0.3)) // 1s tone
	c.Push(silence16k(600))    // 600ms silence > SILENCE_HANG_MS
	c.Push(tone16k(1000, 0.3)) // 1s tone (start of next chunk)
	c.Flush()

	if len(emitted) != 2 {
		t.Fatalf("want 2 chunks, got %d", len(emitted))
	}
	if emitted[0].Reason != "vad-cut" {
		t.Errorf("chunk[0].Reason = %q, want vad-cut", emitted[0].Reason)
	}
	if emitted[1].Reason != "tail" {
		t.Errorf("chunk[1].Reason = %q, want tail", emitted[1].Reason)
	}
}
