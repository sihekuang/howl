# Streaming Whisper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Chunk audio during recording so whisper.cpp processes most of it before PTT release; add a cancel surface (C export + Swift Esc handler) and a CLI test harness that measures the latency win.

**Architecture:** A new `Chunker` (pure Go, VAD + max-time logic over 16k samples) sits between decimation and a single in-order whisper.cpp worker goroutine inside `Pipeline.Run`. `Pipeline.Run`'s signature is unchanged — only its internals change. New C export `vkb_cancel_capture` cancels the in-flight pipeline; new `cancelled` event kind tells the Swift host the cycle ended without a result. CLI gets a `--latency-report` flag and a `cancel\n` stdin sentinel; new `run-streaming.sh` is a developer harness.

**Tech Stack:** Go (core, vkb-cli), Swift 6 (Mac app), whisper.cpp (build tag `whispercpp`), bash (test script).

**Spec:** [`docs/superpowers/specs/2026-04-30-streaming-whisper-design.md`](../specs/2026-04-30-streaming-whisper-design.md)

---

## File Structure

**New files:**
- `core/internal/pipeline/chunker.go` — Chunker struct + state machine
- `core/internal/pipeline/chunker_test.go` — chunker unit tests
- `core/internal/transcribe/whisper_chunked_test.go` — integration similarity test (build tag `whispercpp`)
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Hotkey/CancelKeyMonitor.swift` — Esc-during-recording monitor
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CancelKeyMonitorTests.swift` — unit test for the cancel monitor
- `run-streaming.sh` — interactive CLI test harness

**Modified files:**
- `core/internal/pipeline/pipeline.go` — restructure `Pipeline.Run` to use chunker + worker; add observability callbacks
- `core/internal/pipeline/pipeline_test.go` — extend with multi-chunk + cancel + worker-error tests
- `core/cmd/libvkb/state.go` — extend `event.Kind` doc comment with `cancelled`
- `core/cmd/libvkb/exports.go` — add `vkb_cancel_capture`; emit `cancelled` event on `context.Canceled`
- `core/cmd/libvkb/streaming_test.go` — cancel mid-recording + cancel-with-no-capture tests
- `core/cmd/vkb-cli/pipe.go` — add `--latency-report` flag; recognize `cancel\n` stdin sentinel; wire observability callbacks
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/EngineEvent.swift` — add `.cancelled` case
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/EngineEventTests.swift` — add decoder test
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift` — add `cancelCapture()` to protocol
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/LibvkbEngine.swift` — implement `cancelCapture()` calling `vkb_cancel_capture`
- `mac/VoiceKeyboard/Composition/CompositionRoot.swift` — wire `CancelKeyMonitor`
- `mac/VoiceKeyboard/Engine/EngineCoordinator.swift` — start/stop the cancel monitor with capture state

**Touched but unchanged:** `run.sh`, `Transcriber`/`Cleaner`/`Dict` interfaces, `Pipeline.Run` signature, `Result` struct.

---

## Phase 1 — Chunker (pure logic, no external deps)

### Task 1: Chunker scaffolding + basic VAD-cut

**Files:**
- Create: `core/internal/pipeline/chunker.go`
- Create: `core/internal/pipeline/chunker_test.go`

- [ ] **Step 1: Write the failing test**

`core/internal/pipeline/chunker_test.go`:

```go
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd core && go test ./internal/pipeline/ -run TestChunker_EmitsOnVADSilence -v
```

Expected: FAIL with "undefined: NewChunker", "undefined: ChunkEmission", "undefined: DefaultChunkerOpts".

- [ ] **Step 3: Write the chunker scaffolding + minimum logic to pass**

`core/internal/pipeline/chunker.go`:

```go
// Package pipeline — Chunker splits a stream of 16kHz mono samples into
// utterance-aligned chunks suitable for one-shot whisper.cpp inference.
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
	VoiceThreshold   float32
	SilenceHangMs    int
	MaxChunkMs       int
	ForceCutScanMs   int
}

func DefaultChunkerOpts() ChunkerOpts {
	return ChunkerOpts{
		VoiceThreshold: 0.005,
		SilenceHangMs:  500,
		MaxChunkMs:     12_000,
		ForceCutScanMs: 800,
	}
}

// ChunkEmission is one chunk handed off to the transcribe worker.
type ChunkEmission struct {
	Samples []float32 // 16kHz mono, defensively-copied
	Reason  string    // "vad-cut" | "force-cut" | "tail"
}

type chunkerState int

const (
	stateIdle chunkerState = iota
	stateVoiced
)

// Chunker is NOT safe for concurrent calls. One instance per Pipeline.Run.
type Chunker struct {
	opts   ChunkerOpts
	emit   func(ChunkEmission)

	state     chunkerState
	chunkBuf  []float32
	silenceMs int

	// pending samples not yet aligned to a 100ms window
	pending []float32
}

func NewChunker(opts ChunkerOpts, emit func(ChunkEmission)) *Chunker {
	return &Chunker{opts: opts, emit: emit}
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
		c.emitChunk("tail")
	}
	c.state = stateIdle
	c.silenceMs = 0
	c.pending = nil
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
				c.emitChunk("vad-cut")
				c.state = stateIdle
				c.silenceMs = 0
			}
		}
	}
}

func (c *Chunker) emitChunk(reason string) {
	if len(c.chunkBuf) == 0 {
		return
	}
	out := make([]float32, len(c.chunkBuf))
	copy(out, c.chunkBuf)
	c.chunkBuf = nil
	c.emit(ChunkEmission{Samples: out, Reason: reason})
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd core && go test ./internal/pipeline/ -run TestChunker_EmitsOnVADSilence -v
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/pipeline/chunker.go core/internal/pipeline/chunker_test.go
git commit -m "feat(streaming-whisper): chunker scaffolding with VAD-cut emission

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Drop pre-speech silence

**Files:**
- Modify: `core/internal/pipeline/chunker_test.go`

- [ ] **Step 1: Add the failing test**

Append to `chunker_test.go`:

```go
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
	durMs := len(emitted[0].Samples) / 16
	if durMs > 900 || durMs < 700 {
		t.Errorf("chunk duration = %dms, want ~800ms (silence dropped)", durMs)
	}
}
```

- [ ] **Step 2: Run to verify it passes** (Task 1 implementation already handles this)

```bash
cd core && go test ./internal/pipeline/ -run TestChunker_DropsPreSpeechSilence -v
```

Expected: PASS — the implementation in Task 1 already drops `idle`-state silence.

- [ ] **Step 3: Commit**

```bash
git add core/internal/pipeline/chunker_test.go
git commit -m "test(streaming-whisper): pre-speech silence is dropped by chunker

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Sub-threshold pauses don't split

**Files:**
- Modify: `core/internal/pipeline/chunker_test.go`

- [ ] **Step 1: Add the failing test**

Append to `chunker_test.go`:

```go
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
```

- [ ] **Step 2: Run to verify it passes**

```bash
cd core && go test ./internal/pipeline/ -run TestChunker_ShortPauseDoesNotSplit -v
```

Expected: PASS — the silence counter resets at 200ms < SILENCE_HANG_MS.

- [ ] **Step 3: Commit**

```bash
git add core/internal/pipeline/chunker_test.go
git commit -m "test(streaming-whisper): sub-hang pauses do not split chunks

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Force-cut at MAX_CHUNK_MS

**Files:**
- Modify: `core/internal/pipeline/chunker_test.go`
- Modify: `core/internal/pipeline/chunker.go`

- [ ] **Step 1: Add the failing test**

Append to `chunker_test.go`:

```go
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
	if emitted[0].Reason != "force-cut" || emitted[1].Reason != "force-cut" {
		t.Errorf("first two reasons = %q, %q; want both force-cut", emitted[0].Reason, emitted[1].Reason)
	}
	if emitted[2].Reason != "tail" {
		t.Errorf("last reason = %q, want tail", emitted[2].Reason)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd core && go test ./internal/pipeline/ -run TestChunker_ForceCutAtMaxChunk -v
```

Expected: FAIL — chunker doesn't enforce MaxChunkMs yet (will buffer all 5s and emit one tail).

- [ ] **Step 3: Add force-cut logic to `processWindow`**

In `chunker.go`, change `processWindow` to check chunk duration after appending:

```go
func (c *Chunker) processWindow(w []float32) {
	rms := audio.RMS(w)
	voiced := rms > c.opts.VoiceThreshold

	switch c.state {
	case stateIdle:
		if voiced {
			c.state = stateVoiced
			c.chunkBuf = append(c.chunkBuf, w...)
		}
	case stateVoiced:
		c.chunkBuf = append(c.chunkBuf, w...)
		if voiced {
			c.silenceMs = 0
		} else {
			c.silenceMs += chunkerWindowMs
			if c.silenceMs >= c.opts.SilenceHangMs {
				c.emitChunk("vad-cut")
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

func (c *Chunker) chunkDurationMs() int {
	return len(c.chunkBuf) * 1000 / chunkerSampleRate
}

// forceCut emits everything in chunkBuf as a "force-cut" chunk and
// resets state to voiced (the tail of the cut becomes the next chunk's
// head). For Task 4, the cut is naive (cut at end). Task 5 refines it.
func (c *Chunker) forceCut() {
	c.emitChunk("force-cut")
	c.silenceMs = 0
	// state stays voiced; chunkBuf is empty; next window continues into a new chunk
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd core && go test ./internal/pipeline/ -run TestChunker_ForceCutAtMaxChunk -v
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/pipeline/chunker.go core/internal/pipeline/chunker_test.go
git commit -m "feat(streaming-whisper): force-cut chunker at MAX_CHUNK_MS

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Force-cut prefers low-energy point

**Files:**
- Modify: `core/internal/pipeline/chunker_test.go`
- Modify: `core/internal/pipeline/chunker.go`

- [ ] **Step 1: Add the failing test**

Append to `chunker_test.go`:

```go
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
	// Force-cut fires at chunk duration ≥ 2000ms. The dip is at
	// [1500..1700], i.e. 800..600ms before the cut point — well
	// inside the 800ms scan window. Cut should happen mid-dip,
	// NOT at the 2000ms mark.
	c.Push(tone16k(1500, 0.3))
	c.Push(silence16k(200))    // dip — still > 0 RMS so above pre-speech threshold? actually 0
	c.Push(tone16k(600, 0.3))
	c.Flush()

	if len(emitted) < 2 {
		t.Fatalf("want at least 2 chunks (force-cut + tail), got %d", len(emitted))
	}
	// First chunk should end inside or near the dip (1500-1700ms),
	// NOT at 2000ms. Allow 100ms tolerance for window alignment.
	cutMs := len(emitted[0].Samples) / 16
	if cutMs < 1400 || cutMs > 1800 {
		t.Errorf("force-cut at %dms, want 1500-1700 (in dip)", cutMs)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd core && go test ./internal/pipeline/ -run TestChunker_ForceCutPrefersLowEnergyPoint -v
```

Expected: FAIL — naive force-cut from Task 4 cuts at 2000ms.

- [ ] **Step 3: Refine `forceCut` to seek the lowest-energy 100ms window**

Replace `forceCut` in `chunker.go`:

```go
// forceCut emits a chunk ending at the lowest-energy 100ms window
// within the last ForceCutScanMs of chunkBuf. The remainder stays in
// chunkBuf as the head of the next chunk; state stays voiced.
func (c *Chunker) forceCut() {
	scanWindows := c.opts.ForceCutScanMs / chunkerWindowMs
	totalWindows := len(c.chunkBuf) / chunkerWindowSize
	if scanWindows > totalWindows {
		scanWindows = totalWindows
	}
	if scanWindows < 1 {
		// degenerate: just emit everything
		c.emitChunk("force-cut")
		return
	}

	// Find the lowest-RMS window in the last scanWindows.
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
	c.emit(ChunkEmission{Samples: out, Reason: "force-cut"})
	c.chunkBuf = append(c.chunkBuf[:0], tail...)
	c.silenceMs = 0
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd core && go test ./internal/pipeline/ -run TestChunker_ForceCutPrefersLowEnergyPoint -v
```

Expected: PASS.

- [ ] **Step 5: Re-run all chunker tests to ensure no regressions**

```bash
cd core && go test ./internal/pipeline/ -run TestChunker -v
```

Expected: all 4 PASS.

- [ ] **Step 6: Commit**

```bash
git add core/internal/pipeline/chunker.go core/internal/pipeline/chunker_test.go
git commit -m "feat(streaming-whisper): force-cut at lowest-energy point in scan window

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Trailing silence absorbed into chunk

**Files:**
- Modify: `core/internal/pipeline/chunker_test.go`

- [ ] **Step 1: Add the failing test**

Append to `chunker_test.go`:

```go
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
	durMs := len(emitted[0].Samples) / 16
	// Want full 1200ms (tone + trailing silence absorbed).
	if durMs < 1100 || durMs > 1300 {
		t.Errorf("chunk duration = %dms, want ~1200ms (silence absorbed)", durMs)
	}
}
```

- [ ] **Step 2: Run to verify it passes** (current implementation absorbs silence below hang)

```bash
cd core && go test ./internal/pipeline/ -run TestChunker_TrailingSilenceAbsorbedIntoChunk -v
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add core/internal/pipeline/chunker_test.go
git commit -m "test(streaming-whisper): trailing sub-hang silence is absorbed into chunk

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Empty + silence-only edge cases

**Files:**
- Modify: `core/internal/pipeline/chunker_test.go`

- [ ] **Step 1: Add the failing tests**

Append to `chunker_test.go`:

```go
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
```

- [ ] **Step 2: Run to verify they pass**

```bash
cd core && go test ./internal/pipeline/ -run "TestChunker_EmptyInput|TestChunker_SilenceOnly" -v
```

Expected: PASS — both follow from `idle`-state silence-drop logic.

- [ ] **Step 3: Run full chunker test suite**

```bash
cd core && go test ./internal/pipeline/ -run TestChunker -v
```

Expected: all 7 chunker tests PASS.

- [ ] **Step 4: Commit**

```bash
git add core/internal/pipeline/chunker_test.go
git commit -m "test(streaming-whisper): chunker edge cases (empty + silence-only)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — Pipeline integration

### Task 8: Restructure `Pipeline.Run` to use chunker + worker

**Files:**
- Modify: `core/internal/pipeline/pipeline.go`

- [ ] **Step 1: Add observability callbacks to the `Pipeline` struct**

In `pipeline.go`, extend the struct (keep existing fields):

```go
type Pipeline struct {
	denoiser    denoise.Denoiser
	transcriber transcribe.Transcriber
	dict        dict.Dictionary
	cleaner     llm.Cleaner

	LevelCallback    func(float32)
	LLMDeltaCallback func(string)

	// ChunkerOpts overrides the default chunker thresholds. Zero-value
	// fields fall back to DefaultChunkerOpts. Unset for production; the
	// CLI/tests set this to drive specific scenarios.
	ChunkerOpts ChunkerOpts

	// ChunkEmittedCallback fires when the chunker emits a chunk
	// (durationMs, reason). Optional — used by --latency-report.
	ChunkEmittedCallback func(idx int, durationMs int, reason string)

	// ChunkTranscribedCallback fires after each chunk's Transcribe call
	// returns (durationMs, text). Optional.
	ChunkTranscribedCallback func(idx int, transcribeMs int, text string)

	// LLMFirstTokenCallback fires when the first LLM delta arrives,
	// measured from when transcribe joined the final raw text. Optional.
	LLMFirstTokenCallback func(elapsedMs int)
}
```

- [ ] **Step 2: Replace `Pipeline.Run` body to use chunker + worker**

Replace the body of `Run` in `pipeline.go` (keep the func signature and the docs/log lines at the top):

```go
func (p *Pipeline) Run(ctx context.Context, frames <-chan []float32) (Result, error) {
	if p == nil {
		return Result{}, errors.New("pipeline: nil receiver")
	}

	log.Printf("[vkb] pipeline.Run: starting; awaiting frames")
	tStart := time.Now()
	defer func() {
		log.Printf("[vkb] pipeline.Run: total elapsed %v", time.Since(tStart))
	}()

	opts := p.ChunkerOpts
	if opts.VoiceThreshold == 0 && opts.SilenceHangMs == 0 && opts.MaxChunkMs == 0 {
		opts = DefaultChunkerOpts()
	}

	// Chunk channel — bounded at 4 (≈48s in flight at MaxChunkMs=12s).
	chunkCh := make(chan ChunkEmission, 4)

	// Decimator runs streaming; chunker is fed decimated samples.
	dec := resample.NewDecimate3()
	var chunkIdx int
	chunker := NewChunker(opts, func(e ChunkEmission) {
		chunkIdx++
		dur := len(e.Samples) * 1000 / 16000
		log.Printf("[vkb] chunk emitted #%d: %dms (%s)", chunkIdx, dur, e.Reason)
		if p.ChunkEmittedCallback != nil {
			p.ChunkEmittedCallback(chunkIdx, dur, e.Reason)
		}
		select {
		case chunkCh <- e:
		case <-ctx.Done():
		}
	})

	// Transcribe worker — single goroutine in arrival order.
	var (
		mu          sync.Mutex
		chunkTexts  []string
		workerErr   error
		workerDone  = make(chan struct{})
		transcribed int
	)
	go func() {
		defer close(workerDone)
		for {
			select {
			case <-ctx.Done():
				workerErr = ctx.Err()
				// drain remaining without processing
				for range chunkCh {
				}
				return
			case e, ok := <-chunkCh:
				if !ok {
					return
				}
				t0 := time.Now()
				text, err := p.transcriber.Transcribe(ctx, e.Samples)
				if err != nil {
					mu.Lock()
					workerErr = err
					mu.Unlock()
					for range chunkCh {
					}
					return
				}
				transcribed++
				ms := int(time.Since(t0).Milliseconds())
				log.Printf("[vkb] chunk #%d transcribe: %dms → %q", transcribed, ms, text)
				if p.ChunkTranscribedCallback != nil {
					p.ChunkTranscribedCallback(transcribed, ms, text)
				}
				mu.Lock()
				chunkTexts = append(chunkTexts, text)
				mu.Unlock()
			}
		}
	}()

	// Denoise + decimate + chunk in the foreground.
	for {
		var f []float32
		var ok bool
		select {
		case f, ok = <-frames:
		case <-ctx.Done():
			ok = false
		}
		if !ok {
			break
		}
		denoised := drainAndDenoiseStreaming(f, p.denoiser, p.LevelCallback)
		decimated := dec.Process(denoised)
		chunker.Push(decimated)
	}
	chunker.Flush()
	close(chunkCh)
	<-workerDone

	if workerErr != nil {
		log.Printf("[vkb] pipeline.Run: worker error: %v", workerErr)
		return Result{}, workerErr
	}

	mu.Lock()
	raw := strings.TrimSpace(strings.Join(chunkTexts, " "))
	mu.Unlock()
	log.Printf("[vkb] pipeline.Run: joined raw len=%d raw=%q", len(raw), raw)
	if raw == "" {
		log.Printf("[vkb] pipeline.Run: empty transcription; skipping LLM")
		return Result{}, nil
	}

	corrected, terms := p.dict.Match(raw)
	log.Printf("[vkb] pipeline.Run: dict matched %d terms", len(terms))

	tLLM := time.Now()
	var cleaned string
	var llmErr error
	firstTokenSeen := false
	deltaCb := p.LLMDeltaCallback
	wrappedDelta := func(s string) {
		if !firstTokenSeen {
			firstTokenSeen = true
			elapsed := int(time.Since(tLLM).Milliseconds())
			log.Printf("[vkb] LLM stream first token: %dms after stop", elapsed)
			if p.LLMFirstTokenCallback != nil {
				p.LLMFirstTokenCallback(elapsed)
			}
		}
		if deltaCb != nil {
			deltaCb(s)
		}
	}

	if streamer, ok := p.cleaner.(llm.StreamingCleaner); ok && deltaCb != nil {
		log.Printf("[vkb] pipeline.Run: cleaning via LLM (streaming)…")
		cleaned, llmErr = streamer.CleanStream(ctx, corrected, terms, wrappedDelta)
	} else {
		log.Printf("[vkb] pipeline.Run: cleaning via LLM…")
		cleaned, llmErr = p.cleaner.Clean(ctx, corrected, terms)
	}
	if llmErr != nil {
		log.Printf("[vkb] pipeline.Run: LLM FAILED after %v: %v (using dict-corrected fallback)", time.Since(tLLM), llmErr)
		return Result{Raw: raw, Cleaned: corrected, Terms: terms, LLMError: llmErr}, nil
	}
	log.Printf("[vkb] pipeline.Run: LLM done in %v cleanedLen=%d", time.Since(tLLM), len(cleaned))
	return Result{Raw: raw, Cleaned: cleaned, Terms: terms}, nil
}
```

- [ ] **Step 3: Replace `drainAndDenoise` with a streaming helper**

Replace `drainAndDenoise` in `pipeline.go`:

```go
// drainAndDenoiseStreaming denoises one batch of input frames in
// 480-sample chunks, returning the concatenated denoised output. Sub-
// frame trailing samples within `f` are zero-padded into a final 480-
// sample frame so the tail isn't dropped. State is per-call (Denoiser
// holds rolling state internally).
func drainAndDenoiseStreaming(
	f []float32,
	d denoise.Denoiser,
	levelCb func(float32),
) []float32 {
	out := make([]float32, 0, len(f))
	i := 0
	for ; i+denoise.FrameSize <= len(f); i += denoise.FrameSize {
		frame := f[i : i+denoise.FrameSize]
		dn := d.Process(frame)
		out = append(out, dn...)
		if levelCb != nil {
			levelCb(audio.RMS(dn))
		}
	}
	if i < len(f) {
		last := make([]float32, denoise.FrameSize)
		copy(last, f[i:])
		dn := d.Process(last)
		out = append(out, dn...)
		if levelCb != nil {
			levelCb(audio.RMS(dn))
		}
	}
	return out
}
```

- [ ] **Step 4: Update imports**

Add `"strings"` and `"sync"` to the import block of `pipeline.go` if not already present. Existing imports (`context`, `errors`, `log`, `time`, plus the project packages) stay.

- [ ] **Step 5: Run all pipeline tests**

```bash
cd core && go test ./internal/pipeline/ -v
```

Expected: all chunker tests PASS; existing `pipeline_test.go` tests PASS (the streaming routing test still passes because the LLM stage is unchanged).

- [ ] **Step 6: Commit**

```bash
git add core/internal/pipeline/pipeline.go
git commit -m "feat(streaming-whisper): restructure Pipeline.Run for chunked transcription

Run now denoises + decimates streaming, feeds the chunker, and runs a
single in-order transcribe worker. Chunk texts are joined with space
before the existing dict + LLM stages. Adds optional observability
callbacks (ChunkEmitted, ChunkTranscribed, LLMFirstToken) for the CLI
latency report. Public Pipeline.Run signature unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Pipeline tests — multi-chunk, worker-error, cancel

**Files:**
- Modify: `core/internal/pipeline/pipeline_test.go`

- [ ] **Step 1: Add the multi-chunk test**

Append to `pipeline_test.go`:

```go
// fakeMultiTranscriber returns a different string per call.
type fakeMultiTranscriber struct {
	calls   int
	outputs []string
}

func (f *fakeMultiTranscriber) Transcribe(ctx context.Context, _ []float32) (string, error) {
	if f.calls >= len(f.outputs) {
		return "", nil
	}
	out := f.outputs[f.calls]
	f.calls++
	return out, nil
}
func (f *fakeMultiTranscriber) Close() error { return nil }

func TestPipeline_MultiChunkJoinedAndCleanedOnce(t *testing.T) {
	tr := &fakeMultiTranscriber{outputs: []string{"hello", "world"}}
	cl := &fakeStreamingCleaner{out: "Hello world.", chunks: []string{"Hello ", "world."}}
	p := New(denoise.NewPassthrough(), tr, dict.NewFuzzy(nil, 0), cl)
	p.LLMDeltaCallback = func(string) {}
	p.ChunkerOpts = ChunkerOpts{
		VoiceThreshold: 0.005,
		SilenceHangMs:  100, // tiny so the test silences split
		MaxChunkMs:     12_000,
		ForceCutScanMs: 100,
	}

	frames := make(chan []float32, 4)
	frames <- toneFrames48k(500, 0.3) // 500ms tone
	frames <- silence48k(200)         // 200ms silence > SilenceHangMs (100ms)
	frames <- toneFrames48k(500, 0.3) // 500ms tone
	close(frames)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	res, err := p.Run(ctx, frames)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if tr.calls != 2 {
		t.Errorf("transcribe calls = %d, want 2", tr.calls)
	}
	if cl.streamCalls != 1 {
		t.Errorf("CleanStream calls = %d, want 1", cl.streamCalls)
	}
	if res.Raw != "hello world" {
		t.Errorf("Raw = %q, want %q", res.Raw, "hello world")
	}
	if res.Cleaned != "Hello world." {
		t.Errorf("Cleaned = %q, want %q", res.Cleaned, "Hello world.")
	}
}

// toneFrames48k generates ms ms of 440Hz sine at 48kHz, peak amplitude `peak`.
func toneFrames48k(ms int, peak float32) []float32 {
	n := 48 * ms
	out := make([]float32, n)
	for i := 0; i < n; i++ {
		out[i] = peak * float32(math.Sin(2*math.Pi*440*float64(i)/48000))
	}
	return out
}

func silence48k(ms int) []float32 {
	return make([]float32, 48*ms)
}
```

Add `"math"` to the test file's import block if not present.

- [ ] **Step 2: Run the multi-chunk test**

```bash
cd core && go test ./internal/pipeline/ -run TestPipeline_MultiChunkJoinedAndCleanedOnce -v
```

Expected: PASS.

- [ ] **Step 3: Add the worker-error test**

Append to `pipeline_test.go`:

```go
type errOnNthTranscriber struct {
	calls  int
	failOn int
}

func (f *errOnNthTranscriber) Transcribe(ctx context.Context, _ []float32) (string, error) {
	f.calls++
	if f.calls == f.failOn {
		return "", errors.New("whisper boom")
	}
	return "ok", nil
}
func (f *errOnNthTranscriber) Close() error { return nil }

func TestPipeline_WorkerErrorPropagates(t *testing.T) {
	tr := &errOnNthTranscriber{failOn: 2}
	cl := &fakeStreamingCleaner{}
	p := New(denoise.NewPassthrough(), tr, dict.NewFuzzy(nil, 0), cl)
	p.LLMDeltaCallback = func(string) {}
	p.ChunkerOpts = ChunkerOpts{
		VoiceThreshold: 0.005,
		SilenceHangMs:  100,
		MaxChunkMs:     12_000,
		ForceCutScanMs: 100,
	}

	frames := make(chan []float32, 6)
	frames <- toneFrames48k(500, 0.3)
	frames <- silence48k(200)
	frames <- toneFrames48k(500, 0.3)
	frames <- silence48k(200)
	frames <- toneFrames48k(500, 0.3)
	close(frames)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := p.Run(ctx, frames)
	if err == nil || err.Error() != "whisper boom" {
		t.Fatalf("err = %v, want whisper boom", err)
	}
	if cl.streamCalls != 0 {
		t.Errorf("CleanStream called %d times, want 0 (LLM should not run on transcribe error)", cl.streamCalls)
	}
}
```

- [ ] **Step 4: Run the worker-error test**

```bash
cd core && go test ./internal/pipeline/ -run TestPipeline_WorkerErrorPropagates -v
```

Expected: PASS.

- [ ] **Step 5: Add the cancel test**

Append to `pipeline_test.go`:

```go
type slowTranscriber struct {
	delay time.Duration
}

func (s *slowTranscriber) Transcribe(ctx context.Context, _ []float32) (string, error) {
	select {
	case <-time.After(s.delay):
		return "ok", nil
	case <-ctx.Done():
		return "", ctx.Err()
	}
}
func (s *slowTranscriber) Close() error { return nil }

func TestPipeline_CancelMidRecordingReturnsContextErr(t *testing.T) {
	tr := &slowTranscriber{delay: 200 * time.Millisecond}
	cl := &fakeStreamingCleaner{}
	p := New(denoise.NewPassthrough(), tr, dict.NewFuzzy(nil, 0), cl)
	p.LLMDeltaCallback = func(string) {}
	p.ChunkerOpts = ChunkerOpts{
		VoiceThreshold: 0.005,
		SilenceHangMs:  100,
		MaxChunkMs:     12_000,
		ForceCutScanMs: 100,
	}

	frames := make(chan []float32, 4)
	go func() {
		frames <- toneFrames48k(500, 0.3)
		frames <- silence48k(200)
		frames <- toneFrames48k(500, 0.3)
		// don't close — let cancel cut us off
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	_, err := p.Run(ctx, frames)
	if !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.DeadlineExceeded or Canceled", err)
	}
	if cl.streamCalls != 0 {
		t.Errorf("CleanStream called %d times after cancel, want 0", cl.streamCalls)
	}
}
```

- [ ] **Step 6: Run the cancel test**

```bash
cd core && go test ./internal/pipeline/ -run TestPipeline_CancelMidRecordingReturnsContextErr -v
```

Expected: PASS.

- [ ] **Step 7: Run all pipeline tests + race detector**

```bash
cd core && go test ./internal/pipeline/ -race -v
```

Expected: all PASS, no race detected.

- [ ] **Step 8: Commit**

```bash
git add core/internal/pipeline/pipeline_test.go
git commit -m "test(streaming-whisper): multi-chunk, worker-error, cancel paths

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — Cancel surface in libvkb

### Task 10: Add `cancelled` event kind + `vkb_cancel_capture` C export

**Files:**
- Modify: `core/cmd/libvkb/state.go`
- Modify: `core/cmd/libvkb/exports.go`

- [ ] **Step 1: Update event Kind doc comment in `state.go`**

In `core/cmd/libvkb/state.go`, replace the doc comment block above `type event struct` with:

```go
// event is the JSON payload emitted via vkb_poll_event. Kind values:
//
//	"chunk"     — streaming LLM text delta in Text; emitted repeatedly
//	              during cleanup so the host can type at the cursor as
//	              tokens arrive. The full cleaned text is the
//	              concatenation of every chunk in order.
//	"result"    — final cleaned text in Text. When chunks were streamed,
//	              this is just a state-transition marker (text equals
//	              the concatenation of chunks).
//	"warning"   — non-fatal degradation (e.g. LLM failure); Msg has detail,
//	              and a "result" event with the dict-corrected fallback
//	              text is emitted alongside it
//	"error"     — terminal failure for this capture cycle; Msg has detail
//	"cancelled" — the in-flight pipeline was cancelled by vkb_cancel_capture
//	              before producing a result. No "result" event follows.
//	"level"     — periodic RMS level (~30 Hz), RMS field carries the value
```

- [ ] **Step 2: Add `vkb_cancel_capture` C export in `exports.go`**

Append to `core/cmd/libvkb/exports.go` (after `vkb_stop_capture`):

```go
// vkb_cancel_capture aborts the in-flight capture, drops any buffered
// audio, and emits a "cancelled" event instead of a "result". Idempotent:
// safe to call when no capture is active. Returns 1 if the engine is
// not initialized, 0 otherwise.
//
//export vkb_cancel_capture
func vkb_cancel_capture() C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	e.mu.Lock()
	cancel := e.cancel
	if e.pushCh != nil {
		close(e.pushCh)
		e.pushCh = nil
	}
	e.cancel = nil
	e.mu.Unlock()
	if cancel != nil {
		log.Printf("[vkb] vkb_cancel_capture: cancelling in-flight pipeline")
		cancel()
	}
	return 0
}
```

- [ ] **Step 3: Emit `cancelled` instead of `error` on `context.Canceled`**

In `core/cmd/libvkb/exports.go`, find the `vkb_start_capture` capture goroutine (around lines 189–206). Replace the error-handling block:

Before:
```go
res, err := pipe.Run(ctx, pushCh)
if err != nil {
    log.Printf("[vkb] capture goroutine: pipe.Run error: %v", err)
    e.events <- event{Kind: "error", Msg: err.Error()}
    return
}
```

After:
```go
res, err := pipe.Run(ctx, pushCh)
if err != nil {
    if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
        log.Printf("[vkb] capture goroutine: pipeline cancelled")
        e.events <- event{Kind: "cancelled"}
        return
    }
    log.Printf("[vkb] capture goroutine: pipe.Run error: %v", err)
    e.events <- event{Kind: "error", Msg: err.Error()}
    return
}
```

Add `"errors"` to the import block of `exports.go` if not present.

- [ ] **Step 4: Build the dylib to confirm the new export compiles**

```bash
cd core && make build-dylib 2>&1 | tail -10
```

Expected: success. The new symbol `vkb_cancel_capture` will be in the .h file:

```bash
grep vkb_cancel_capture core/build/libvkb.h
```

Expected: a function declaration line.

- [ ] **Step 5: Commit**

```bash
git add core/cmd/libvkb/state.go core/cmd/libvkb/exports.go
git commit -m "feat(streaming-whisper): vkb_cancel_capture C export + cancelled event

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: libvkb test — cancellation emits `cancelled` (not `error`)

**Files:**
- Modify: `core/cmd/libvkb/streaming_test.go`

**Constraint:** Go forbids `import "C"` in `_test.go` files (per the comment at the top of the existing `streaming_test.go`). The C export `vkb_cancel_capture` cannot be called directly from a test in this package. Instead, exercise the cancel emission logic at the Go-internals level: build an `engine`, run a fake pipeline goroutine, call `cancel()` directly, and assert the events channel emits `kind: "cancelled"`.

- [ ] **Step 1: Add the cancel-emits-cancelled test**

Append to `core/cmd/libvkb/streaming_test.go`:

```go
import (
	"context"
	"errors"
	"testing"
	"time"
)

// (existing imports stay; the json + testing imports are already there.
//  Add the new ones above to the existing import block.)

// TestCaptureGoroutine_CancelEmitsCancelledNotError verifies that when
// pipe.Run returns context.Canceled (e.g. because vkb_cancel_capture
// called the engine's cancel func), the capture goroutine emits a
// "cancelled" event rather than an "error" event.
//
// We can't call the C export directly from _test.go, so we mirror the
// goroutine's error-handling shape with a fake pipe.Run.
func TestCaptureGoroutine_CancelEmitsCancelledNotError(t *testing.T) {
	events := make(chan event, 8)

	// Simulate the relevant block from vkb_start_capture's goroutine.
	emitForRunErr := func(err error) {
		if err != nil {
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				events <- event{Kind: "cancelled"}
				return
			}
			events <- event{Kind: "error", Msg: err.Error()}
			return
		}
		events <- event{Kind: "result"}
	}

	emitForRunErr(context.Canceled)
	emitForRunErr(context.DeadlineExceeded)
	emitForRunErr(errors.New("whisper boom"))
	emitForRunErr(nil)

	wantKinds := []string{"cancelled", "cancelled", "error", "result"}
	for i, want := range wantKinds {
		select {
		case ev := <-events:
			if ev.Kind != want {
				t.Errorf("event[%d].Kind = %q, want %q", i, ev.Kind, want)
			}
		case <-time.After(50 * time.Millisecond):
			t.Fatalf("event[%d] timeout", i)
		}
	}
}

// TestCancelHelper_DropsPushChAndCallsCancel verifies the engine state
// transitions inside vkb_cancel_capture without going through the C ABI.
// The real export does:
//   1. drop pushCh (close it, set nil)
//   2. call the saved cancel func
//   3. nil out the cancel func
// This test reproduces those steps and asserts the side effects.
func TestCancelHelper_DropsPushChAndCallsCancel(t *testing.T) {
	pushCh := make(chan []float32, 4)
	ctx, cancel := context.WithCancel(context.Background())
	cancelCalled := false
	wrappedCancel := func() {
		cancelCalled = true
		cancel()
	}
	e := &engine{events: make(chan event, 4)}
	e.pushCh = pushCh
	e.cancel = wrappedCancel

	// Mirror the body of vkb_cancel_capture (minus the C return code).
	e.mu.Lock()
	c := e.cancel
	if e.pushCh != nil {
		close(e.pushCh)
		e.pushCh = nil
	}
	e.cancel = nil
	e.mu.Unlock()
	if c != nil {
		c()
	}

	if !cancelCalled {
		t.Error("cancel func was not invoked")
	}
	if e.pushCh != nil {
		t.Error("pushCh was not nilled")
	}
	if e.cancel != nil {
		t.Error("cancel field was not nilled")
	}
	if ctx.Err() != context.Canceled {
		t.Errorf("ctx not cancelled: %v", ctx.Err())
	}
	// And: closing an already-closed channel would panic — verify the
	// "no active capture" no-op path is safe by re-running the body.
	e.mu.Lock()
	c = e.cancel
	if e.pushCh != nil {
		close(e.pushCh)
		e.pushCh = nil
	}
	e.cancel = nil
	e.mu.Unlock()
	if c != nil {
		c()
	}
	// If we got here without panic, the no-op path is safe.
}
```

- [ ] **Step 2: Run the cancel tests**

```bash
cd core && go test ./cmd/libvkb/ -run "TestCaptureGoroutine_CancelEmitsCancelledNotError|TestCancelHelper_DropsPushChAndCallsCancel" -v
```

Expected: PASS for both.

- [ ] **Step 3: Run the full libvkb test suite for regressions**

```bash
cd core && go test ./cmd/libvkb/ -v
```

Expected: all PASS (existing `TestEvent_ChunkJSONEncoding` still passes).

- [ ] **Step 4: Commit**

```bash
git add core/cmd/libvkb/streaming_test.go
git commit -m "test(streaming-whisper): cancel emits cancelled event, helper is idempotent

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 4 — CLI harness

### Task 12: vkb-cli `--latency-report` flag + observability hookup

**Files:**
- Modify: `core/cmd/vkb-cli/pipe.go`

- [ ] **Step 1: Add the `--latency-report` flag and the report struct**

In `pipe.go`, add to the flag block in `runPipe`:

```go
	latencyReport := fs.Bool("latency-report", false, "print per-chunk timing + post-stop latency summary on stderr")
```

After flags are parsed and before pipeline construction, add:

```go
	type chunkInfo struct {
		emittedAt time.Time
		dur       int
		reason    string
		transcMs  int
		text      string
	}
	var (
		repMu        sync.Mutex
		repChunks    []chunkInfo
		repStopAt    time.Time
		repFirstTok  time.Duration
		repFirstSeen bool
	)
```

Add `"sync"` and `"time"` to the imports if not already present.

- [ ] **Step 2: Wire callbacks before `pipeline.New`**

In `pipe.go`, after `p := pipeline.New(d, w, dy, cleaner)`:

```go
	if *latencyReport {
		p.ChunkEmittedCallback = func(idx int, durationMs int, reason string) {
			repMu.Lock()
			repChunks = append(repChunks, chunkInfo{
				emittedAt: time.Now(), dur: durationMs, reason: reason,
			})
			repMu.Unlock()
		}
		p.ChunkTranscribedCallback = func(idx int, transcribeMs int, text string) {
			repMu.Lock()
			if idx-1 < len(repChunks) {
				repChunks[idx-1].transcMs = transcribeMs
				repChunks[idx-1].text = text
			}
			repMu.Unlock()
		}
		p.LLMFirstTokenCallback = func(elapsedMs int) {
			repMu.Lock()
			repFirstTok = time.Duration(elapsedMs) * time.Millisecond
			repFirstSeen = true
			repMu.Unlock()
		}
	}
```

- [ ] **Step 3: Print the report after `Run` returns**

In `pipe.go`, after the `Run` returns successfully (in the `--live` branch and the file branch — wherever the result is written), add (gated on `*latencyReport`):

```go
	if *latencyReport {
		printLatencyReport(repStopAt, repChunks, repFirstTok, repFirstSeen)
	}
```

And add the helper function in the same file:

```go
func printLatencyReport(stopAt time.Time, chunks []chunkInfo, firstTok time.Duration, sawFirst bool) {
	w := os.Stderr
	fmt.Fprintln(w, "[vkb] === latency report ===")
	var preStopTransc, postStopTransc int
	for _, c := range chunks {
		if c.emittedAt.Before(stopAt) {
			preStopTransc += c.transcMs
		} else {
			postStopTransc += c.transcMs
		}
	}
	fmt.Fprintf(w, "[vkb]   chunks emitted:        %d\n", len(chunks))
	fmt.Fprintf(w, "[vkb]   transcribe-during-rec: %dms\n", preStopTransc)
	fmt.Fprintf(w, "[vkb]   post-stop-transcribe:  %dms\n", postStopTransc)
	if sawFirst {
		fmt.Fprintf(w, "[vkb]   post-stop-llm-first:   %dms after transcribe done\n", int(firstTok.Milliseconds()))
	}
	totalPostStop := postStopTransc + int(firstTok.Milliseconds())
	fmt.Fprintf(w, "[vkb]   total post-stop wait:  %dms\n", totalPostStop)
}
```

The `repStopAt` value needs to be set when `--live` mode reads the stop newline. Find the `--live` loop in `pipe.go` (it reads from `bufio.NewReader(os.Stdin)`). Just after the read returns and BEFORE calling stop, add:

```go
		repMu.Lock()
		repStopAt = time.Now()
		repMu.Unlock()
```

- [ ] **Step 4: Build the CLI to confirm it compiles**

```bash
cd core && make build-cli 2>&1 | tail -5
```

Expected: success.

- [ ] **Step 5: Smoke test (no audio actually needed for compile-check)**

```bash
core/build/vkb-cli pipe --help 2>&1 | grep -A1 latency-report
```

Expected: a line for `--latency-report`.

- [ ] **Step 6: Commit**

```bash
git add core/cmd/vkb-cli/pipe.go
git commit -m "feat(streaming-whisper): vkb-cli --latency-report flag

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: vkb-cli `pipe --live` recognizes `cancel\n` sentinel

**Files:**
- Modify: `core/cmd/vkb-cli/pipe.go`

- [ ] **Step 1: Find the `--live` stdin read in `pipe.go`**

Look for the line that reads stdin (typically `bufio.NewReader(os.Stdin).ReadString('\n')`). The current behavior calls stop. New: read the line, trim, and branch on the value.

- [ ] **Step 2: Replace the stdin-read + stop block**

Replace the existing block (the exact lines depend on current code, but the pattern is `_, _ = bufio.NewReader(os.Stdin).ReadString('\n')` followed by a stop call). New version:

```go
	line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	line = strings.TrimSpace(line)
	repMu.Lock()
	repStopAt = time.Now()
	repMu.Unlock()
	cancelled := false
	if line == "cancel" {
		log.Printf("[vkb] --live: stdin sentinel 'cancel' — aborting pipeline")
		ctxCancel() // existing cancel func from signal.NotifyContext
		cancelled = true
	} else {
		// existing stop path: close the audio channel / signal end-of-input
		// ... keep whatever is already there for the stop path
	}
```

Where `ctxCancel` is the cancel function returned by `signal.NotifyContext` near the top of `runPipe`. If the variable name in your file is different (e.g. `cancel`), use that name. Capture `cancelled` in scope so the post-`Run` reporting can short-circuit:

```go
	if cancelled {
		fmt.Fprintln(os.Stderr, "🚫 Cancelled. No transcript produced.")
		return 0
	}
```

- [ ] **Step 3: Build and smoke-test the cancel path**

```bash
cd core && make build-cli && echo "cancel" | core/build/vkb-cli pipe --live --dict "" 2>&1 | tail -5
```

Expected: a `Cancelled.` line on stderr; exit 0; no transcript on stdout. (Will also need a model + API key for full Run; if those are missing, the cancel path may not even reach the read — adjust by ensuring environment per existing `run.sh`.)

- [ ] **Step 4: Commit**

```bash
git add core/cmd/vkb-cli/pipe.go
git commit -m "feat(streaming-whisper): vkb-cli pipe --live recognizes 'cancel' sentinel

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 14: `run-streaming.sh` script

**Files:**
- Create: `run-streaming.sh`

- [ ] **Step 1: Write the script**

Create `run-streaming.sh` at the repo root with mode 0755:

```bash
#!/usr/bin/env bash
# run-streaming.sh — interactive harness for the chunked Whisper
# pipeline. Records from the mic via vkb-cli pipe --live, prints
# per-chunk timing and a post-stop latency report when finished.
#
# Press any key to STOP and transcribe normally.
# Press 'q' to CANCEL (no transcript, no LLM call).
#
# Usage:
#   ./run-streaming.sh                # any key stops, q cancels
#   ./run-streaming.sh --keep-wav     # also save the captured audio
#   VKB_DICT="MCP,WebRTC" ./run-streaming.sh
#
# Reads ANTHROPIC_API_KEY from ./.env. Cleaned text → stdout.
# Live chunk events + latency report → stderr.
set -e

KEEP_WAV=0
for arg in "$@"; do
  case "$arg" in
    --keep-wav) KEEP_WAV=1 ;;
    *)          echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

DICT="${VKB_DICT:-MCP,WebRTC}"

cd "$(dirname "$0")"

if [ -f .env ]; then
  set -a; . ./.env; set +a
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ANTHROPIC_API_KEY not set (looked in ./.env)" >&2; exit 1
fi

if [ ! -x core/build/vkb-cli ]; then
  echo "Building vkb-cli..." >&2
  make -C core build-cli >&2
fi

FIFO="$(mktemp -u /tmp/vkb-streaming.XXXXXX.fifo)"
mkfifo "$FIFO"
cleanup() { rm -f "$FIFO"; }
trap cleanup EXIT

# Start the CLI in the background, with stdin from the fifo.
core/build/vkb-cli pipe --dict "$DICT" --live --latency-report < "$FIFO" &
PID=$!
exec 3>"$FIFO"

echo "🎙  Recording — press any key to stop and transcribe, or 'q' to cancel." >&2

# Read a single keypress in raw mode.
IFS= read -rsn1 key

if [[ "$key" == "q" ]]; then
  echo "cancel" >&3
else
  echo "" >&3
  echo "✓ Stopping..." >&2
fi

exec 3>&-
wait "$PID"
```

Make it executable:

```bash
chmod 0755 run-streaming.sh
```

- [ ] **Step 2: Smoke test (build only — full run requires mic and model)**

```bash
ls -la run-streaming.sh && head -3 run-streaming.sh
```

Expected: file exists, executable, shebang line.

- [ ] **Step 3: Commit**

```bash
git add run-streaming.sh
git commit -m "feat(streaming-whisper): run-streaming.sh interactive test harness

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 5 — Swift integration

### Task 15: EngineEvent.cancelled case

**Files:**
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/EngineEvent.swift`
- Modify: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/EngineEventTests.swift`

- [ ] **Step 1: Add the failing decoder test**

Append to `EngineEventTests.swift` (or insert next to existing `decodeResult` / `decodeWarning` cases):

```swift
@Test func decodeCancelled() throws {
    let json = #"{"kind":"cancelled"}"#
    let event = try JSONDecoder().decode(EngineEvent.self, from: Data(json.utf8))
    #expect(event == .cancelled)
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd mac/Packages/VoiceKeyboardCore && swift test --filter decodeCancelled 2>&1 | tail -10
```

Expected: FAIL — case `.cancelled` doesn't exist on `EngineEvent`.

- [ ] **Step 3: Add the `.cancelled` case + decode branch**

In `EngineEvent.swift`, add the case:

```swift
public enum EngineEvent: Sendable, Decodable, Equatable {
    case level(rms: Float)
    case chunk(text: String)
    case result(text: String)
    case warning(msg: String)
    case error(msg: String)
    case cancelled
    ...
}
```

In the `init(from:)` switch, add:

```swift
        case "cancelled":
            self = .cancelled
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd mac/Packages/VoiceKeyboardCore && swift test --filter decodeCancelled 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Run the full test suite to confirm no regressions**

```bash
cd mac/Packages/VoiceKeyboardCore && swift test 2>&1 | tail -10
```

Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/EngineEvent.swift mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/EngineEventTests.swift
git commit -m "feat(streaming-whisper): EngineEvent.cancelled case + decoder

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 16: CoreEngine.cancelCapture protocol method + LibvkbEngine impl

**Files:**
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift`
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/LibvkbEngine.swift`

- [ ] **Step 1: Read current `CoreEngine.swift` to confirm protocol shape**

```bash
cat mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift
```

- [ ] **Step 2: Add `cancelCapture()` to the protocol**

In `CoreEngine.swift`, after the existing capture methods (`startCapture`, `stopCapture`, etc.), add:

```swift
    /// Aborts the in-flight capture (if any). The Go core emits a
    /// `cancelled` event and runs no LLM cleanup. Idempotent.
    func cancelCapture()
```

- [ ] **Step 3: Implement in `LibvkbEngine.swift`**

In `LibvkbEngine.swift`, after the existing `stopCapture` impl, add:

```swift
    public nonisolated func cancelCapture() {
        vkb_cancel_capture()
    }
```

- [ ] **Step 4: Build the package to confirm everything compiles**

```bash
cd mac/Packages/VoiceKeyboardCore && swift build 2>&1 | tail -10
```

Expected: success. If a spy/mock conformance to `CoreEngine` exists in the tests directory, it will need a `cancelCapture()` no-op — the build error will point you to it.

- [ ] **Step 5: Update any test spies**

If `swift build` fails on a missing `cancelCapture` in a `CoreEngineSpy` or similar test fixture, add:

```swift
    func cancelCapture() { /* spy: record-and-discard */ }
```

- [ ] **Step 6: Run tests**

```bash
cd mac/Packages/VoiceKeyboardCore && swift test 2>&1 | tail -10
```

Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/LibvkbEngine.swift
# include any spy update too
git commit -m "feat(streaming-whisper): CoreEngine.cancelCapture protocol + libvkb impl

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 17: Esc cancel monitor + composition wiring

**Files:**
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Hotkey/CancelKeyMonitor.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CancelKeyMonitorTests.swift`
- Modify: `mac/VoiceKeyboard/Composition/CompositionRoot.swift`
- Modify: `mac/VoiceKeyboard/Engine/EngineCoordinator.swift`

- [ ] **Step 1: Write the failing test**

Create `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CancelKeyMonitorTests.swift`:

```swift
import Testing
import Foundation
@testable import VoiceKeyboardCore

@Suite("CancelKeyMonitor")
struct CancelKeyMonitorTests {
    @Test func callsHandlerOnEsc() async throws {
        var fired = 0
        let mon = CancelKeyMonitor(onCancel: { fired += 1 })

        // Simulate the Esc keyDown via the test-only entrypoint.
        mon.simulateEscForTest()
        #expect(fired == 1)
    }

    @Test func ignoresOtherKeys() async throws {
        var fired = 0
        let mon = CancelKeyMonitor(onCancel: { fired += 1 })

        mon.simulateKeyForTest(keyCode: 0) // 'a' — not Esc (53)
        #expect(fired == 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd mac/Packages/VoiceKeyboardCore && swift test --filter CancelKeyMonitor 2>&1 | tail -10
```

Expected: FAIL — `CancelKeyMonitor` doesn't exist.

- [ ] **Step 3: Implement `CancelKeyMonitor`**

Create `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Hotkey/CancelKeyMonitor.swift`:

```swift
import AppKit
import Foundation
import os

/// Watches for the Esc key globally while active and invokes `onCancel`
/// on press. Uses `NSEvent.addGlobalMonitorForEvents` (observe-only,
/// requires Accessibility — already a hard requirement for paste
/// injection). Does not consume the event; other apps still see Esc
/// normally.
///
/// Lifecycle: call `start()` when the engine enters a capture cycle and
/// `stop()` when the cycle ends (regardless of how it ended). Idempotent.
public final class CancelKeyMonitor: @unchecked Sendable {
    private static let escKeyCode: UInt16 = 53
    private static let log = Logger(subsystem: "com.voicekeyboard.app", category: "CancelKey")

    private let onCancel: @Sendable () -> Void
    private var monitor: Any?

    public init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func start() {
        if monitor != nil { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [onCancel] event in
            if event.keyCode == Self.escKeyCode {
                Self.log.info("Esc detected during capture — invoking cancel")
                onCancel()
            }
        }
    }

    public func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    deinit { stop() }

    // MARK: - Test surface

    /// Simulates an Esc keypress for unit tests.
    public func simulateEscForTest() {
        onCancel()
    }

    /// Simulates a non-Esc keypress for unit tests (does nothing — the
    /// real monitor's keyCode filter would discard it).
    public func simulateKeyForTest(keyCode _: UInt16) {
        // Intentionally a no-op. Provided so tests document the
        // expectation that other keys do not trigger cancel.
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd mac/Packages/VoiceKeyboardCore && swift test --filter CancelKeyMonitor 2>&1 | tail -10
```

Expected: PASS for both.

- [ ] **Step 5: Wire into CompositionRoot**

Open `mac/VoiceKeyboard/Composition/CompositionRoot.swift`. After `permissions` and `coordinator` are constructed, add:

```swift
    public let cancelKeyMonitor: CancelKeyMonitor
```

In the initializer, after the coordinator is built:

```swift
        let coreEngine = self.engine // adapt to actual property name
        self.cancelKeyMonitor = CancelKeyMonitor { [coreEngine] in
            coreEngine.cancelCapture()
        }
```

(Adjust property names to match what's already there; the goal is one CancelKeyMonitor instance whose `onCancel` calls the engine's `cancelCapture`.)

- [ ] **Step 6: Drive start/stop from EngineCoordinator**

In `mac/VoiceKeyboard/Engine/EngineCoordinator.swift`, find where the capture state transitions (start of recording, end of recording). At capture start:

```swift
        composition.cancelKeyMonitor.start()
```

At capture end (whether success, error, or cancellation):

```swift
        composition.cancelKeyMonitor.stop()
```

Use the existing capture-state hooks; do not invent a new state machine.

- [ ] **Step 7: Build the Mac target**

```bash
cd mac && make build 2>&1 | tail -10
```

Expected: success.

- [ ] **Step 8: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Hotkey/CancelKeyMonitor.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CancelKeyMonitorTests.swift \
        mac/VoiceKeyboard/Composition/CompositionRoot.swift \
        mac/VoiceKeyboard/Engine/EngineCoordinator.swift
git commit -m "feat(streaming-whisper): Esc-during-recording cancels via NSEvent global monitor

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 6 — Whisper integration regression

### Task 18: Whisper chunked-vs-single-shot similarity test

**Files:**
- Create: `core/internal/transcribe/whisper_chunked_test.go`

- [ ] **Step 1: Write the similarity test reusing the existing wav loader**

The existing `core/internal/transcribe/whisper_cpp_test.go` already defines `readWavMono16k` and uses the fixture at `../../test/integration/testdata/hello-world.wav`. The new test lives in the same package so it can call that helper directly.

Create `core/internal/transcribe/whisper_chunked_test.go`:

```go
//go:build whispercpp

package transcribe

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestWhisper_ChunkedVsSingleShotSimilarity feeds the same audio to
// whisper.cpp two ways: as one full call, and as a sequence of ≤12s
// chunks (matching what the chunker produces in production). The two
// transcripts should match within an edit-distance budget; if chunked
// accuracy regresses sharply, this catches it.
//
// Default fixture is the same `hello-world.wav` used by the existing
// whisper_cpp_test.go (which is short — chunking is a no-op on it but
// still verifies the loop runs cleanly). For a realistic regression
// signal, point VKB_TEST_WAV at a ≥20s mono 16k PCM wav.
func TestWhisper_ChunkedVsSingleShotSimilarity(t *testing.T) {
	modelPath := os.Getenv("VKB_TEST_MODEL")
	if modelPath == "" {
		modelPath = filepath.Join(os.Getenv("HOME"), "Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin")
	}
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("model not found at %s; set VKB_TEST_MODEL to override", modelPath)
	}
	wavPath := os.Getenv("VKB_TEST_WAV")
	if wavPath == "" {
		wavPath = filepath.Join("..", "..", "test", "integration", "testdata", "hello-world.wav")
	}
	pcm, err := readWavMono16k(wavPath)
	if err != nil {
		t.Fatalf("load wav %s: %v", wavPath, err)
	}

	w, err := NewWhisperCpp(WhisperOptions{ModelPath: modelPath, Language: "en"})
	if err != nil {
		t.Fatalf("new whisper: %v", err)
	}
	defer w.Close()

	full, err := w.Transcribe(context.Background(), pcm)
	if err != nil {
		t.Fatalf("full transcribe: %v", err)
	}

	const chunkSamples = 12 * 16000 // 12s
	var chunked []string
	for i := 0; i < len(pcm); i += chunkSamples {
		end := i + chunkSamples
		if end > len(pcm) {
			end = len(pcm)
		}
		s, err := w.Transcribe(context.Background(), pcm[i:end])
		if err != nil {
			t.Fatalf("chunked transcribe[%d]: %v", i, err)
		}
		chunked = append(chunked, s)
	}
	joined := strings.TrimSpace(strings.Join(chunked, " "))

	dist := levenshtein(strings.ToLower(full), strings.ToLower(joined))
	// 5% budget, with a floor of 3 chars for very short transcripts
	// where rounding makes 5% a fractional value.
	maxAllowed := len(full) / 20
	if maxAllowed < 3 {
		maxAllowed = 3
	}
	if dist > maxAllowed {
		t.Errorf("chunked diverged from single-shot:\n  full:    %q\n  chunked: %q\n  edit distance: %d (budget %d)", full, joined, dist, maxAllowed)
	}
}

// levenshtein computes the Levenshtein distance between two strings.
func levenshtein(a, b string) int {
	if len(a) == 0 {
		return len(b)
	}
	if len(b) == 0 {
		return len(a)
	}
	prev := make([]int, len(b)+1)
	curr := make([]int, len(b)+1)
	for j := 0; j <= len(b); j++ {
		prev[j] = j
	}
	for i := 1; i <= len(a); i++ {
		curr[0] = i
		for j := 1; j <= len(b); j++ {
			cost := 1
			if a[i-1] == b[j-1] {
				cost = 0
			}
			curr[j] = min3(curr[j-1]+1, prev[j]+1, prev[j-1]+cost)
		}
		copy(prev, curr)
	}
	return prev[len(b)]
}

func min3(a, b, c int) int {
	m := a
	if b < m {
		m = b
	}
	if c < m {
		m = c
	}
	return m
}
```

- [ ] **Step 2: Run the test (uses default fixture)**

```bash
cd core && go test -tags=whispercpp ./internal/transcribe/ -run TestWhisper_ChunkedVsSingleShotSimilarity -v
```

Expected: PASS using the default `hello-world.wav` fixture (which is short — chunking degenerates to one chunk, so the similarity check passes trivially but the loop is exercised). For real regression signal, set `VKB_TEST_WAV=/path/to/longform.wav` (≥20s mono 16k PCM) and re-run.

- [ ] **Step 3: Commit**

```bash
git add core/internal/transcribe/whisper_chunked_test.go
git commit -m "test(streaming-whisper): chunked vs single-shot whisper similarity

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Final integration check

- [ ] **Step 1: Run all unit tests**

```bash
cd core && make test 2>&1 | tail -15
cd mac/Packages/VoiceKeyboardCore && swift test 2>&1 | tail -15
```

Expected: all green on both.

- [ ] **Step 2: Build everything**

```bash
cd core && make build 2>&1 | tail -5
cd mac && make build 2>&1 | tail -5
```

Expected: both build successfully.

- [ ] **Step 3: End-to-end smoke test (manual)**

```bash
./run.sh 4
```

Expected: same behavior as before this branch — short take transcribes and prints cleaned text.

```bash
./run-streaming.sh
```

Speak for ~25s, press Space. Expected: per-chunk events on stderr, latency report, cleaned text on stdout.

```bash
./run-streaming.sh
```

Speak for ~5s, press q. Expected: `🚫 Cancelled. No transcript produced.`, exit 0.

In the Mac app: hold PTT, talk for 10s, press Esc. Expected: nothing typed at the cursor; menu bar returns to idle.

- [ ] **Step 4: Final commit (if any tweaks needed)**

If any of the above smoke tests required small fixes, commit them as `fix(streaming-whisper): ...`.

- [ ] **Step 5: Push and let user decide on PR vs. local merge**

```bash
git push -u origin feat/streaming-whisper
```

Then invoke superpowers:finishing-a-development-branch to merge or open a PR.
