package pipeline

import (
	"math"
	"testing"
)

// tone16k generates `ms` milliseconds of a 440Hz sine wave at 16kHz, peak amplitude `peak`.
func tone16k(ms int, peak float32) []float32 {
	n := chunkerSampleRate / 1000 * ms
	out := make([]float32, n)
	for i := 0; i < n; i++ {
		out[i] = peak * float32(math.Sin(2*math.Pi*440*float64(i)/chunkerSampleRate))
	}
	return out
}

// silence16k generates `ms` milliseconds of zero samples at 16kHz.
func silence16k(ms int) []float32 {
	return make([]float32, chunkerSampleRate/1000*ms)
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
	if emitted[0].Reason != ReasonVADCut {
		t.Errorf("chunk[0].Reason = %q, want %q", emitted[0].Reason, ReasonVADCut)
	}
	if emitted[1].Reason != ReasonTail {
		t.Errorf("chunk[1].Reason = %q, want %q", emitted[1].Reason, ReasonTail)
	}
}

func TestChunker_SilenceOnly_FlushEmitsNothing(t *testing.T) {
	var got []ChunkEmission
	c := NewChunker(DefaultChunkerOpts(), func(e ChunkEmission) {
		got = append(got, e)
	})
	c.Push(silence16k(2000))
	c.Flush()
	if len(got) != 0 {
		t.Fatalf("expected no emissions, got %d", len(got))
	}
}

func TestChunker_ShortSpeech_FlushEmitsTail(t *testing.T) {
	var got []ChunkEmission
	c := NewChunker(DefaultChunkerOpts(), func(e ChunkEmission) {
		got = append(got, e)
	})
	c.Push(tone16k(200, 0.3)) // 200ms of speech, shorter than silence hang
	c.Flush()
	if len(got) != 1 {
		t.Fatalf("expected 1 tail emission, got %d", len(got))
	}
	if got[0].Reason != ReasonTail {
		t.Errorf("expected reason %q, got %q", ReasonTail, got[0].Reason)
	}
}

func TestChunker_DropsPreSpeechSilence(t *testing.T) {
	var emitted []ChunkEmission
	c := NewChunker(DefaultChunkerOpts(), func(e ChunkEmission) {
		emitted = append(emitted, e)
	})

	c.Push(silence16k(1000)) // 1s pre-speech silence
	c.Push(tone16k(800, 0.3))
	c.Flush()

	if len(emitted) != 1 {
		t.Fatalf("want 1 chunk, got %d", len(emitted))
	}
	// Chunk should be ~800ms (the tone), NOT 1800ms (silence + tone).
	durMs := len(emitted[0].Samples) * 1000 / chunkerSampleRate
	if durMs > 900 || durMs < 700 {
		t.Errorf("chunk duration = %dms, want ~800ms (silence dropped)", durMs)
	}
}

func TestChunker_ShortPauseDoesNotSplit(t *testing.T) {
	var emitted []ChunkEmission
	c := NewChunker(DefaultChunkerOpts(), func(e ChunkEmission) {
		emitted = append(emitted, e)
	})

	c.Push(tone16k(800, 0.3))
	c.Push(silence16k(200)) // 200ms pause < SILENCE_HANG_MS (500ms)
	c.Push(tone16k(800, 0.3))
	c.Flush()

	if len(emitted) != 1 {
		t.Fatalf("want 1 chunk (pause too short to split), got %d", len(emitted))
	}
}
