package pipeline

import (
	"math"
	"testing"
)

// vadFunc wraps a plain function as a speaker.VAD — avoids importing speaker in tests.
type vadFunc func([]float32) bool

func (f vadFunc) IsVoiced(s []float32) bool { return f(s) }

func TestChunker_UsesVADWhenSet(t *testing.T) {
	// fakeVAD returns voiced=true for first 8 calls (800ms), then false.
	calls := 0
	callsVoiced := 8
	isVoiced := func(_ []float32) bool {
		calls++
		return calls <= callsVoiced
	}

	var emitted []ChunkEmission
	opts := ChunkerOpts{
		VAD:            vadFunc(isVoiced),
		SilenceHangMs:  100,
		MaxChunkMs:     12_000,
		ForceCutScanMs: 100,
	}
	c := NewChunker(opts, func(e ChunkEmission) { emitted = append(emitted, e) })

	// Push 16 windows of 1600 samples each at amplitude 0.1
	// (RMS would pass default threshold — testing VAD overrides it).
	window := make([]float32, 1600)
	for i := range window {
		window[i] = 0.1
	}
	for i := 0; i < 16; i++ {
		c.Push(window)
	}
	c.Flush()

	if len(emitted) != 1 {
		t.Fatalf("expected 1 chunk, got %d", len(emitted))
	}
	// 8 voiced windows + 1 silence window absorbed by hang = 9 * 1600 samples
	wantSamples := 9 * 1600
	if len(emitted[0].Samples) != wantSamples {
		t.Errorf("chunk samples = %d, want %d", len(emitted[0].Samples), wantSamples)
	}
}

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

func TestChunker_ForceCutPrefersLowEnergyPoint(t *testing.T) {
	opts := ChunkerOpts{
		VoiceThreshold: 0.005,
		SilenceHangMs:  500,
		MaxChunkMs:     2000,
		ForceCutScanMs: 800,
	}
	var emitted []ChunkEmission
	c := NewChunker(opts, func(e ChunkEmission) { emitted = append(emitted, e) })

	// 1500ms loud + 200ms quiet dip + 600ms loud = 2300ms total.
	// Force-cut fires at chunk duration >= 2000ms. The dip is at
	// [1500..1700], i.e. 800..600ms before the cut point — well
	// inside the 800ms scan window. Cut should happen mid-dip,
	// NOT at the 2000ms mark.
	c.Push(tone16k(1500, 0.3))
	c.Push(silence16k(200))   // dip — RMS is 0, lowest energy
	c.Push(tone16k(600, 0.3))
	c.Flush()

	if len(emitted) < 2 {
		t.Fatalf("want at least 2 chunks (force-cut + tail), got %d", len(emitted))
	}
	// First chunk should end inside or near the dip (1500-1700ms),
	// NOT at 2000ms. Allow 100ms tolerance for window alignment.
	cutMs := len(emitted[0].Samples) * 1000 / chunkerSampleRate
	if cutMs < 1400 || cutMs > 1800 {
		t.Errorf("force-cut at %dms, want 1500-1700 (in dip)", cutMs)
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
	if emitted[0].Reason != ReasonTail {
		t.Errorf("chunk[0].Reason = %q, want %q", emitted[0].Reason, ReasonTail)
	}
}

func TestChunker_TrailingSilenceAbsorbedIntoChunk(t *testing.T) {
	var emitted []ChunkEmission
	c := NewChunker(DefaultChunkerOpts(), func(e ChunkEmission) {
		emitted = append(emitted, e)
	})

	c.Push(tone16k(800, 0.3))
	c.Push(silence16k(400)) // < SILENCE_HANG_MS, gets absorbed
	c.Flush()

	if len(emitted) != 1 {
		t.Fatalf("want 1 chunk, got %d", len(emitted))
	}
	durMs := len(emitted[0].Samples) * 1000 / chunkerSampleRate
	// Want full 1200ms (tone + trailing silence absorbed).
	if durMs < 1100 || durMs > 1300 {
		t.Errorf("chunk duration = %dms, want ~1200ms (silence absorbed)", durMs)
	}
}

func TestChunker_EmptyInput(t *testing.T) {
	var emitted []ChunkEmission
	c := NewChunker(DefaultChunkerOpts(), func(e ChunkEmission) {
		emitted = append(emitted, e)
	})
	c.Flush()
	if len(emitted) != 0 {
		t.Errorf("want 0 chunks, got %d", len(emitted))
	}
}

func TestChunker_SilenceOnly(t *testing.T) {
	var emitted []ChunkEmission
	c := NewChunker(DefaultChunkerOpts(), func(e ChunkEmission) {
		emitted = append(emitted, e)
	})
	c.Push(silence16k(5000))
	c.Flush()
	if len(emitted) != 0 {
		t.Errorf("want 0 chunks, got %d", len(emitted))
	}
}

func TestChunker_ForceCutAtMaxChunk(t *testing.T) {
	opts := ChunkerOpts{
		VoiceThreshold: 0.005,
		SilenceHangMs:  500,
		MaxChunkMs:     2000, // small for test
		ForceCutScanMs: 200,
	}
	var emitted []ChunkEmission
	c := NewChunker(opts, func(e ChunkEmission) { emitted = append(emitted, e) })

	c.Push(tone16k(5000, 0.3)) // 5s continuous tone, no silences
	c.Flush()

	// MaxChunkMs=2000 → expect 3 chunks (~2s, ~2s, ~1s tail).
	if len(emitted) != 3 {
		t.Fatalf("want 3 chunks, got %d", len(emitted))
	}
	if emitted[0].Reason != ReasonForceCut || emitted[1].Reason != ReasonForceCut {
		t.Errorf("first two reasons = %q, %q; want both force-cut", emitted[0].Reason, emitted[1].Reason)
	}
	if emitted[2].Reason != ReasonTail {
		t.Errorf("last reason = %q, want tail", emitted[2].Reason)
	}
}
