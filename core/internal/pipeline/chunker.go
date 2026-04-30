// Chunker splits a stream of 16kHz mono samples into utterance-aligned chunks
// suitable for one-shot whisper.cpp inference.
//
// State machine: idle → voiced (on first above-threshold 100ms window),
// voiced → idle (on SILENCE_HANG_MS of below-threshold). Pre-speech
// silence is dropped. Trailing silence under the hang is absorbed into
// the chunk. Long unbroken speech is force-cut at MAX_CHUNK_MS, with
// the cut placed at the lowest-energy 100ms window inside the last
// FORCE_CUT_SCAN_MS.
package pipeline

import "github.com/voice-keyboard/core/internal/audio"

const (
	chunkerSampleRate = 16000
	chunkerWindowMs   = 100
	chunkerWindowSize = chunkerSampleRate * chunkerWindowMs / 1000 // 1600 samples
)

// ChunkerOpts holds the tunable thresholds. DefaultChunkerOpts returns
// a sensible production set; tests pass smaller values.
type ChunkerOpts struct {
	VoiceThreshold float32
	SilenceHangMs  int
	MaxChunkMs     int
	ForceCutScanMs int
}

func DefaultChunkerOpts() ChunkerOpts {
	return ChunkerOpts{
		VoiceThreshold: 0.005,
		SilenceHangMs:  500,
		MaxChunkMs:     12_000,
		ForceCutScanMs: 800,
	}
}

// ChunkReason identifies why a chunk was emitted.
type ChunkReason string

const (
	ReasonVADCut   ChunkReason = "vad-cut"
	ReasonForceCut ChunkReason = "force-cut"
	ReasonTail     ChunkReason = "tail"
)

// ChunkEmission is one chunk handed off to the transcribe worker.
type ChunkEmission struct {
	Samples []float32   // 16kHz mono, defensively-copied
	Reason  ChunkReason // ReasonVADCut | ReasonForceCut | ReasonTail
}

type chunkerState int

const (
	stateIdle chunkerState = iota
	stateVoiced
)

// Chunker is NOT safe for concurrent calls. One instance per Pipeline.Run.
type Chunker struct {
	opts ChunkerOpts
	emit func(ChunkEmission)

	state     chunkerState
	chunkBuf  []float32
	silenceMs int

	// pending samples not yet aligned to a 100ms window
	pending []float32
}

func NewChunker(opts ChunkerOpts, emit func(ChunkEmission)) *Chunker {
	return &Chunker{
		opts:     opts,
		emit:     emit,
		chunkBuf: make([]float32, 0, chunkerSampleRate*opts.MaxChunkMs/1000),
	}
}

// Push feeds a slice of 16kHz mono samples. May synchronously call emit
// zero or more times.
func (c *Chunker) Push(samples []float32) {
	c.pending = append(c.pending, samples...)
	for len(c.pending) >= chunkerWindowSize {
		w := c.pending[:chunkerWindowSize]
		c.processWindow(w)
		c.pending = c.pending[chunkerWindowSize:]
	}
}

// Flush emits any accumulated tail chunk. Call once on input close.
// Pending sub-window samples are included in the tail chunk.
func (c *Chunker) Flush() {
	if c.state == stateVoiced {
		if len(c.pending) > 0 {
			c.chunkBuf = append(c.chunkBuf, c.pending...)
			c.pending = nil
		}
		c.emitChunk(ReasonTail)
	}
	c.state = stateIdle
	c.silenceMs = 0
	c.pending = nil
}

func (c *Chunker) chunkDurationMs() int {
	return len(c.chunkBuf) * 1000 / chunkerSampleRate
}

// forceCut emits a chunk ending at the lowest-energy 100ms window
// within the last ForceCutScanMs of chunkBuf. The remainder becomes
// the head of the next chunk; state stays voiced.
func (c *Chunker) forceCut() {
	scanWindows := c.opts.ForceCutScanMs / chunkerWindowMs
	totalWindows := len(c.chunkBuf) / chunkerWindowSize
	if scanWindows > totalWindows {
		scanWindows = totalWindows
	}
	if scanWindows < 1 {
		c.emitChunk(ReasonForceCut)
		return
	}

	startWindow := totalWindows - scanWindows
	bestWindow := startWindow
	bestRMS := float32(1.0)
	for w := startWindow; w < totalWindows; w++ {
		s := w * chunkerWindowSize
		e := s + chunkerWindowSize
		rms := audio.RMS(c.chunkBuf[s:e])
		if rms < bestRMS {
			bestRMS = rms
			bestWindow = w
		}
	}

	cutSample := bestWindow * chunkerWindowSize
	head := c.chunkBuf[:cutSample]
	tail := c.chunkBuf[cutSample:]

	out := make([]float32, len(head))
	copy(out, head)
	c.emit(ChunkEmission{Samples: out, Reason: ReasonForceCut})
	c.chunkBuf = append(c.chunkBuf[:0], tail...)
	c.silenceMs = 0
}

func (c *Chunker) processWindow(w []float32) {
	rms := audio.RMS(w)
	voiced := rms > c.opts.VoiceThreshold

	switch c.state {
	case stateIdle:
		if voiced {
			c.state = stateVoiced
			c.chunkBuf = append(c.chunkBuf, w...)
		}
		// else: drop pre-speech silence on the floor
	case stateVoiced:
		c.chunkBuf = append(c.chunkBuf, w...)
		if voiced {
			c.silenceMs = 0
		} else {
			c.silenceMs += chunkerWindowMs
			if c.silenceMs >= c.opts.SilenceHangMs {
				c.emitChunk(ReasonVADCut)
				c.state = stateIdle
				c.silenceMs = 0
				return
			}
		}

		if c.chunkDurationMs() >= c.opts.MaxChunkMs {
			c.forceCut()
		}
	}
}

func (c *Chunker) emitChunk(reason ChunkReason) {
	if len(c.chunkBuf) == 0 {
		return
	}
	out := make([]float32, len(c.chunkBuf))
	copy(out, c.chunkBuf)
	c.chunkBuf = c.chunkBuf[:0]
	c.emit(ChunkEmission{Samples: out, Reason: reason})
}
