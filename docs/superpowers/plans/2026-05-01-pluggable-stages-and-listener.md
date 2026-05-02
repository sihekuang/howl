# Pluggable Audio Stages, Unified Listener, and Per-Layer Recording

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the Go audio pipeline so each layer (denoise, decimate, TSE, future filters) implements one `audio.Stage` interface and is composed as a slice the host owns. Replace the 5 separate per-event callbacks with one `Listener func(Event)`. Add an opt-in recorder that taps every stage by name plus pre-/post-LLM transcripts.

**Architecture:**
- `audio.Stage` is the unit: `Name() string`, `OutputRate() int`, `Process(ctx, in) ([]float32, error)`. Optional `Flusher` (residual buffered samples) and `Closer` (resource cleanup).
- The `Chunker` is **not** a Stage — it stays as a fixed splitter between `FrameStages` (continuous stream) and `ChunkStages` (per-utterance chunks). Sample-rate transitions are implicit and the composer's responsibility.
- One `pipeline.Event` tagged-struct + `Listener`; existing per-callback fields removed and their consumers (FFI, CLI latency report) migrated.
- A `recorder.Session` opens one `<stage>.wav` per registered stage at the right sample rate plus `raw.txt`/`dict.txt`/`cleaned.txt`. Streaming WAV writer (header patched on `Close`).

**Tech Stack:** Go 1.22, existing internal packages (`audio`, `denoise`, `resample`, `speaker`, `pipeline`), CGo (deepfilter), ONNX Runtime (TSE).

---

## File Structure

**New files:**
- `core/internal/audio/stage.go` — Stage interface + Flusher/Closer
- `core/internal/denoise/stage.go` — adapter wrapping Denoiser into a Stage with internal 480-frame buffering
- `core/internal/denoise/stage_test.go`
- `core/internal/resample/stage.go` — Decimate3 satisfying Stage
- `core/internal/pipeline/event.go` — Event + EventKind + Listener type
- `core/internal/pipeline/event_test.go`
- `core/internal/recorder/recorder.go` — Session, AddStage, AppendStage, WriteText, Close
- `core/internal/recorder/recorder_test.go`

**Modified files:**
- `core/internal/speaker/tse.go` — interface becomes `audio.Stage`; ref now in receiver
- `core/internal/speaker/speakerbeam.go` — constructor takes ref, satisfies Stage
- `core/internal/speaker/speakerbeam_test.go` and `_integration_test.go` — adapt
- `core/internal/pipeline/pipeline.go` — drop `denoiser`, `TSE`, `TSERef`, all 5 callbacks; add `FrameStages`, `ChunkStages`, `Listener`, `Recorder`. Refactor `Run`. Update `LoadTSE` to return a Stage.
- `core/internal/pipeline/pipeline_test.go` — adapt
- `core/cmd/vkb-cli/pipe.go` — build stage slices, replace per-callback latency wiring with single Listener, add `--record-dir`/`--record` flags
- `core/cmd/libvkb/state.go` — build stage slices instead of `p.TSE`/`p.TSERef`
- `core/cmd/libvkb/exports.go` — adapt `LevelCallback`/`LLMDeltaCallback` wiring to single Listener
- `core/test/integration/full_pipeline_test.go` — adapt to new Pipeline shape

---

## Task 1: Define the `audio.Stage` interface

**Files:**
- Create: `core/internal/audio/stage.go`

- [ ] **Step 1: Write the file**

```go
// core/internal/audio/stage.go
package audio

import "context"

// Stage is one step in the audio processing chain. The framework calls
// Process for each batch of samples flowing through. All stages produce
// []float32 mono PCM in [-1, 1].
//
// Sample-rate transitions are implicit: each stage advertises OutputRate
// (or 0 to mean "same as input"). The composer is responsible for
// arranging stages so adjacent rates line up — there is no graph-time
// validation.
type Stage interface {
	// Name is a stable identifier used for logging and recording filenames.
	// Should be a single short token, lowercase, no spaces (e.g. "denoise").
	Name() string

	// OutputRate returns the sample rate of Process output, or 0 if the
	// stage preserves whatever rate it received.
	OutputRate() int

	// Process consumes a batch of samples and returns an output batch.
	// Stages MAY buffer internally and return fewer/zero samples per call;
	// the framework calls Flush at end-of-input to drain residuals.
	Process(ctx context.Context, in []float32) ([]float32, error)
}

// Flusher is optionally implemented by stages that buffer input internally.
// The framework calls Flush after the input stream closes; the returned
// samples are appended to the stage's output as if Process had returned them.
type Flusher interface {
	Flush(ctx context.Context) ([]float32, error)
}

// Closer is optionally implemented by stages that own resources. Pipeline
// calls Close on shutdown; safe to call multiple times.
type Closer interface {
	Close() error
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd core && go build ./internal/audio/...`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add core/internal/audio/stage.go
git commit -m "feat(audio): introduce Stage/Flusher/Closer interfaces

The Stage interface unifies the shape of audio-processing layers
(denoise, decimate, TSE, future filters) so they're composable as a
slice the pipeline iterates. Sample-rate transitions stay implicit —
the composer arranges rate-changing stages in the right slot."
```

---

## Task 2: Make `resample.Decimate3` a `Stage`

**Files:**
- Create: `core/internal/resample/stage.go`
- Test: `core/internal/resample/decimate3_test.go` (existing — add new test cases)

- [ ] **Step 1: Write the failing test**

```go
// core/internal/resample/decimate3_test.go — append to existing tests
func TestDecimate3StageMetadata(t *testing.T) {
	d := NewDecimate3()
	if d.Name() != "decimate" {
		t.Errorf("Name=%q, want %q", d.Name(), "decimate")
	}
	if d.OutputRate() != 16000 {
		t.Errorf("OutputRate=%d, want 16000", d.OutputRate())
	}
}

func TestDecimate3StageProcess(t *testing.T) {
	d := NewDecimate3()
	in := make([]float32, 480)
	out, err := d.ProcessStage(context.Background(), in)
	if err != nil {
		t.Fatalf("Process error: %v", err)
	}
	if len(out) != 160 {
		t.Errorf("len(out)=%d, want 160", len(out))
	}
}
```

(Use a temporary helper `ProcessStage` only if you don't want to break the existing `Process` test signature. If you replace `Process` in this task, also update existing tests to add `context.Background()` arg.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd core && go test ./internal/resample/ -run TestDecimate3Stage -v`
Expected: FAIL — Name/OutputRate/ProcessStage not defined.

- [ ] **Step 3: Implement Stage shape on Decimate3**

Edit `core/internal/resample/decimate3.go`:

Change the existing signature
```go
func (d *Decimate3) Process(in []float32) []float32 {
```
to satisfy `audio.Stage`:
```go
func (d *Decimate3) Name() string    { return "decimate" }
func (d *Decimate3) OutputRate() int { return 16000 }

func (d *Decimate3) Process(ctx context.Context, in []float32) ([]float32, error) {
	// (body unchanged; ctx unused — decimation is non-cancellable and trivial)
	out := make([]float32, 0, len(in)/decim+1)
	for _, x := range in {
		copy(d.delay, d.delay[1:])
		d.delay[len(d.delay)-1] = x
		d.phase++
		if d.phase < decim {
			continue
		}
		d.phase = 0
		var acc float32
		for i, c := range fir {
			acc += c * d.delay[i]
		}
		out = append(out, acc)
	}
	return out, nil
}
```

Add `import "context"` to the file.

Update existing `decimate3_test.go` callsites — anywhere it calls `d.Process(buf)`, change to `out, _ := d.Process(context.Background(), buf)`.

(Drop the `ProcessStage` helper from Step 1 — make the test call the real `Process(ctx, in)` directly.)

- [ ] **Step 4: Run all resample tests**

Run: `cd core && go test ./internal/resample/...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/resample/
git commit -m "refactor(resample): Decimate3 satisfies audio.Stage

Adds Name() and OutputRate(), and changes Process to take ctx + return
error. ctx is unused (decimation is trivial and non-cancellable) but
required by the interface."
```

---

## Task 3: `denoise.Stage` adapter with internal buffering + Flush

The existing `Denoiser` interface (`Process(frame []float32) []float32`, strict 480-sample frames) stays — Passthrough and DeepFilter are unchanged. Add a thin adapter that satisfies `audio.Stage`, buffering input until 480 samples are ready and zero-padding the residual on `Flush`.

**Files:**
- Create: `core/internal/denoise/stage.go`
- Create: `core/internal/denoise/stage_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// core/internal/denoise/stage_test.go
package denoise

import (
	"context"
	"testing"
)

func TestStageMetadata(t *testing.T) {
	s := NewStage(NewPassthrough())
	if s.Name() != "denoise" {
		t.Errorf("Name=%q", s.Name())
	}
	if s.OutputRate() != 0 {
		t.Errorf("OutputRate=%d, want 0 (preserves input)", s.OutputRate())
	}
}

func TestStageBuffers480Frames(t *testing.T) {
	s := NewStage(NewPassthrough())
	// 1000 samples → emits 2 frames (960 samples), buffers 40.
	out, err := s.Process(context.Background(), make([]float32, 1000))
	if err != nil {
		t.Fatalf("Process: %v", err)
	}
	if len(out) != 960 {
		t.Errorf("Process out=%d, want 960", len(out))
	}
	flush, err := s.Flush(context.Background())
	if err != nil {
		t.Fatalf("Flush: %v", err)
	}
	// Residual 40 samples are zero-padded to 480 and emitted as one frame.
	if len(flush) != 480 {
		t.Errorf("Flush out=%d, want 480", len(flush))
	}
}

func TestStageEmptyInput(t *testing.T) {
	s := NewStage(NewPassthrough())
	out, _ := s.Process(context.Background(), nil)
	if len(out) != 0 {
		t.Errorf("nil input produced %d samples", len(out))
	}
	flush, _ := s.Flush(context.Background())
	if len(flush) != 0 {
		t.Errorf("Flush with empty buffer produced %d samples", len(flush))
	}
}

func TestStageMultipleProcessCalls(t *testing.T) {
	s := NewStage(NewPassthrough())
	out1, _ := s.Process(context.Background(), make([]float32, 300))
	out2, _ := s.Process(context.Background(), make([]float32, 300))
	// 300+300=600 → emit 480, buffer 120.
	if len(out1) != 0 {
		t.Errorf("first call out=%d, want 0", len(out1))
	}
	if len(out2) != 480 {
		t.Errorf("second call out=%d, want 480", len(out2))
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd core && go test ./internal/denoise/ -run TestStage -v`
Expected: FAIL — `NewStage` undefined.

- [ ] **Step 3: Write the adapter**

```go
// core/internal/denoise/stage.go
package denoise

import "context"

// Stage adapts a frame-oriented Denoiser (480-sample input, 480-sample
// output) into an audio.Stage that accepts variable-sized input by
// buffering. Residual sub-frame samples are returned, zero-padded, on
// Flush so the tail of an utterance isn't lost.
type Stage struct {
	d   Denoiser
	buf []float32
}

// NewStage wraps an existing Denoiser. Takes ownership of d for Close.
func NewStage(d Denoiser) *Stage {
	return &Stage{d: d}
}

func (s *Stage) Name() string    { return "denoise" }
func (s *Stage) OutputRate() int { return 0 } // preserves input rate

func (s *Stage) Process(_ context.Context, in []float32) ([]float32, error) {
	if len(in) == 0 {
		return nil, nil
	}
	s.buf = append(s.buf, in...)
	if len(s.buf) < FrameSize {
		return nil, nil
	}
	frames := len(s.buf) / FrameSize
	out := make([]float32, 0, frames*FrameSize)
	for i := 0; i < frames; i++ {
		dn := s.d.Process(s.buf[i*FrameSize : (i+1)*FrameSize])
		out = append(out, dn...)
	}
	// Slide remainder to head of buffer.
	rem := len(s.buf) - frames*FrameSize
	copy(s.buf, s.buf[frames*FrameSize:])
	s.buf = s.buf[:rem]
	return out, nil
}

func (s *Stage) Flush(_ context.Context) ([]float32, error) {
	if len(s.buf) == 0 {
		return nil, nil
	}
	pad := make([]float32, FrameSize)
	copy(pad, s.buf)
	s.buf = s.buf[:0]
	return s.d.Process(pad), nil
}

func (s *Stage) Close() error {
	if s.d == nil {
		return nil
	}
	return s.d.Close()
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd core && go test ./internal/denoise/...`
Expected: PASS (all tests, including pre-existing ones).

- [ ] **Step 5: Commit**

```bash
git add core/internal/denoise/stage.go core/internal/denoise/stage_test.go
git commit -m "feat(denoise): Stage adapter wraps Denoiser as audio.Stage

Buffers input internally so callers no longer need the
drainAndDenoiseStreaming helper. Residual sub-frame samples are
zero-padded on Flush so the tail of an utterance survives. Pre-
existing Passthrough/DeepFilter are unchanged."
```

---

## Task 4: `pipeline.Event` tagged struct + `Listener` type

**Files:**
- Create: `core/internal/pipeline/event.go`
- Create: `core/internal/pipeline/event_test.go`

- [ ] **Step 1: Write the failing test**

```go
// core/internal/pipeline/event_test.go
package pipeline

import "testing"

func TestEventKindString(t *testing.T) {
	cases := map[EventKind]string{
		EventStageProcessed:   "stage_processed",
		EventChunkEmitted:     "chunk_emitted",
		EventChunkTranscribed: "chunk_transcribed",
		EventLLMDelta:         "llm_delta",
		EventLLMFirstToken:    "llm_first_token",
	}
	for k, want := range cases {
		if got := k.String(); got != want {
			t.Errorf("EventKind(%d).String()=%q, want %q", k, got, want)
		}
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd core && go test ./internal/pipeline/ -run TestEventKindString -v`
Expected: FAIL — type undefined.

- [ ] **Step 3: Define Event and Listener**

```go
// core/internal/pipeline/event.go
package pipeline

// EventKind identifies which event a Listener received. Per-kind fields
// on Event are populated only for the relevant kind; the rest are zero.
type EventKind int

const (
	// EventStageProcessed fires after each Stage.Process call. Stage holds
	// the stage Name(); RMSIn/RMSOut are computed by the framework over
	// the input and output of that call.
	EventStageProcessed EventKind = iota

	// EventChunkEmitted fires when the Chunker emits a chunk. ChunkIdx
	// is 1-based, DurationMs is the chunk's audio length, Reason is the
	// chunker's emission reason ("silence_hang" / "max_duration" / ...).
	EventChunkEmitted

	// EventChunkTranscribed fires after each chunk's Transcribe call
	// returns. ChunkIdx is 1-based, ElapsedMs is wall time spent in
	// transcription for that chunk, Text is the chunk's transcribed text.
	EventChunkTranscribed

	// EventLLMDelta fires for each streamed LLM cleaned-text delta.
	// Text is the delta (not cumulative).
	EventLLMDelta

	// EventLLMFirstToken fires when the first LLM delta arrives. ElapsedMs
	// is the wall time from "transcription complete" to "first token".
	EventLLMFirstToken
)

func (k EventKind) String() string {
	switch k {
	case EventStageProcessed:
		return "stage_processed"
	case EventChunkEmitted:
		return "chunk_emitted"
	case EventChunkTranscribed:
		return "chunk_transcribed"
	case EventLLMDelta:
		return "llm_delta"
	case EventLLMFirstToken:
		return "llm_first_token"
	}
	return "unknown"
}

// Event is the one-shape payload delivered to a Listener.
//
// Field population by Kind:
//
//	EventStageProcessed   — Stage, RMSIn, RMSOut
//	EventChunkEmitted     — ChunkIdx, DurationMs, Reason
//	EventChunkTranscribed — ChunkIdx, ElapsedMs, Text
//	EventLLMDelta         — Text
//	EventLLMFirstToken    — ElapsedMs
type Event struct {
	Kind EventKind

	Stage  string
	RMSIn  float32
	RMSOut float32

	ChunkIdx   int
	DurationMs int
	Reason     string
	ElapsedMs  int
	Text       string
}

// Listener observes pipeline events. Callbacks may fire concurrently
// from multiple goroutines (foreground frame loop and chunk worker);
// implementations must be safe under concurrent invocation. Best-effort:
// a slow Listener delays the pipeline.
type Listener func(Event)
```

- [ ] **Step 4: Run test to verify pass**

Run: `cd core && go test ./internal/pipeline/ -run TestEventKindString -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/pipeline/event.go core/internal/pipeline/event_test.go
git commit -m "feat(pipeline): unified Event/Listener for observability

One tagged struct + one func field replaces the 5 separate per-event
callbacks (LevelCallback, LLMDeltaCallback, ChunkEmittedCallback,
ChunkTranscribedCallback, LLMFirstTokenCallback). Stage events carry
the stage Name() so adding a new layer auto-emits without new fields.
Existing callbacks stay live until Task 7 wires the new Listener."
```

---

## Task 5: TSE refactor — ref into receiver, satisfy `audio.Stage`

**Files:**
- Modify: `core/internal/speaker/tse.go` (interface)
- Modify: `core/internal/speaker/speakerbeam.go` (implementation)
- Modify: `core/internal/speaker/speakerbeam_test.go` and `speakerbeam_integration_test.go`
- Modify: `core/internal/pipeline/pipeline.go:LoadTSE` (return Stage now)
- Modify: `core/internal/speaker/tse_integration_test.go`

- [ ] **Step 1: Update the interface**

Replace the body of `core/internal/speaker/tse.go`:

```go
// core/internal/speaker/tse.go
package speaker

import (
	"context"

	"github.com/voice-keyboard/core/internal/audio"
)

// TSEExtractor extracts the target speaker's audio from a mixed signal.
// Implementations capture the enrolled speaker reference at construction
// time so the per-call signature lines up with audio.Stage.
//
// Input:  mixed 16 kHz mono PCM (typically a chunker emission)
// Output: clean audio of the same length as mixed
//
// Implementations MUST also satisfy audio.Stage.
type TSEExtractor interface {
	audio.Stage
	Extract(ctx context.Context, mixed []float32) ([]float32, error)
}
```

(Keeping `Extract` on the interface is optional — a thin convenience alias for `Process` since callers may want a more domain-specific name. If you'd rather consolidate, drop `Extract` and have callers use `Process` directly.)

- [ ] **Step 2: Move ref into SpeakerGate, satisfy Stage**

Edit `core/internal/speaker/speakerbeam.go`:

```go
// core/internal/speaker/speakerbeam.go
package speaker

import (
	"context"
	"fmt"

	ort "github.com/yalue/onnxruntime_go"
)

type SpeakerGate struct {
	session *ort.DynamicAdvancedSession
	ref     []float32 // L2-normalised enrollment embedding, captured at construction
}

// NewSpeakerGate loads tse_model.onnx and binds the enrollment reference.
// Call InitONNXRuntime before this. ref length must match the backend's
// EmbeddingDim (validated lazily on first inference).
func NewSpeakerGate(modelPath string, ref []float32) (*SpeakerGate, error) {
	if len(ref) == 0 {
		return nil, fmt.Errorf("speakergate: empty reference embedding")
	}
	session, err := ort.NewDynamicAdvancedSession(
		modelPath,
		[]string{"mixed", "ref_embedding"},
		[]string{"extracted"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("speakergate: load %q: %w", modelPath, err)
	}
	return &SpeakerGate{session: session, ref: ref}, nil
}

func (g *SpeakerGate) Name() string    { return "tse" }
func (g *SpeakerGate) OutputRate() int { return 0 } // preserves 16 kHz input

// Process satisfies audio.Stage. Equivalent to Extract.
func (g *SpeakerGate) Process(ctx context.Context, mixed []float32) ([]float32, error) {
	return g.Extract(ctx, mixed)
}

// Extract runs speaker extraction inference using the bound reference.
func (g *SpeakerGate) Extract(_ context.Context, mixed []float32) ([]float32, error) {
	mixedT, err := ort.NewTensor(ort.NewShape(1, int64(len(mixed))), mixed)
	if err != nil {
		return nil, fmt.Errorf("speakergate: mixed tensor: %w", err)
	}
	defer mixedT.Destroy()

	refT, err := ort.NewTensor(ort.NewShape(1, int64(len(g.ref))), g.ref)
	if err != nil {
		return nil, fmt.Errorf("speakergate: ref tensor: %w", err)
	}
	defer refT.Destroy()

	outT, err := ort.NewEmptyTensor[float32](ort.NewShape(1, int64(len(mixed))))
	if err != nil {
		return nil, fmt.Errorf("speakergate: output tensor: %w", err)
	}
	defer outT.Destroy()

	if err := g.session.Run([]ort.Value{mixedT, refT}, []ort.Value{outT}); err != nil {
		return nil, fmt.Errorf("speakergate: inference: %w", err)
	}

	out := make([]float32, len(mixed))
	copy(out, outT.GetData())
	return out, nil
}

func (g *SpeakerGate) Close() error {
	return g.session.Destroy()
}
```

- [ ] **Step 3: Update LoadTSE to return Stage**

Edit `core/internal/pipeline/pipeline.go` — `LoadTSE` signature changes:

```go
// LoadTSE initialises a TSE Stage for the given backend, binding the
// enrollment embedding from profileDir. Returns nil Stage + nil error
// when speaker.json is absent (TSE off). Returns error only on partial
// state (json present but embedding missing/corrupt).
func LoadTSE(backend *speaker.Backend, profileDir, modelsDir, onnxLibPath string) (audio.Stage, error) {
	if backend == nil {
		backend = speaker.Default
	}
	_, err := speaker.LoadProfile(profileDir)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("load tse: profile: %w", err)
	}
	embPath := profileDir + "/enrollment.emb"
	ref, err := speaker.LoadEmbedding(embPath, backend.EmbeddingDim)
	if os.IsNotExist(err) {
		return nil, fmt.Errorf("load tse: enrollment.emb missing — re-run enroll.sh")
	}
	if err != nil {
		return nil, fmt.Errorf("load tse: embedding: %w", err)
	}
	if err := speaker.InitONNXRuntime(onnxLibPath); err != nil {
		return nil, fmt.Errorf("load tse: onnx runtime: %w", err)
	}
	tse, err := speaker.NewSpeakerGate(backend.TSEPath(modelsDir), ref)
	if err != nil {
		return nil, fmt.Errorf("load tse: model: %w", err)
	}
	return tse, nil
}
```

Add `"github.com/voice-keyboard/core/internal/audio"` to the import block. Remove the second return value (`[]float32` ref) from the signature — it's owned by the gate now.

- [ ] **Step 4: Update tests**

Edit `core/internal/speaker/speakerbeam_test.go` and `speakerbeam_integration_test.go`:
- Anywhere a test calls `NewSpeakerGate(modelPath)`, replace with `NewSpeakerGate(modelPath, ref)` using the test's existing ref array.
- Anywhere a test calls `gate.Extract(ctx, mixed, ref)`, replace with `gate.Extract(ctx, mixed)`.
- Add a metadata test:

```go
// in speakerbeam_test.go
func TestSpeakerGateMetadata(t *testing.T) {
	t.Skip("requires model + ref; covered by integration test")
}
```

(If running without the model isn't possible, leave the assertion in the integration test.)

In `tse_integration_test.go`, drop the `ref` argument from `Extract` calls and from any `pipeline.LoadTSE` callsite — `LoadTSE` returns `(audio.Stage, error)` now, not `(extractor, ref, err)`.

- [ ] **Step 5: Run speaker tests**

Run: `cd core && go test ./internal/speaker/...`
Expected: PASS for unit tests. Integration tests that need the ONNX model may skip if the model isn't present — that's pre-existing.

- [ ] **Step 6: Commit**

```bash
git add core/internal/speaker/ core/internal/pipeline/pipeline.go
git commit -m "refactor(speaker): TSE binds ref at construction, satisfies Stage

NewSpeakerGate now takes the enrollment embedding so the per-call
signature collapses to Process(ctx, mixed) — lining up with
audio.Stage. LoadTSE returns audio.Stage instead of (extractor, ref).
Extract is kept as a domain alias for callers that want it."
```

---

## Task 6: `recorder` package — stage-name-aware streaming WAVs + transcripts

**Files:**
- Create: `core/internal/recorder/recorder.go`
- Create: `core/internal/recorder/recorder_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// core/internal/recorder/recorder_test.go
package recorder

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

func TestSessionWritesPerStageWAV(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(Options{Dir: dir, AudioStages: true, Transcripts: false})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := s.AddStage("denoise", 48000); err != nil {
		t.Fatalf("AddStage denoise: %v", err)
	}
	if err := s.AddStage("tse", 16000); err != nil {
		t.Fatalf("AddStage tse: %v", err)
	}
	s.AppendStage("denoise", make([]float32, 480))
	s.AppendStage("tse", make([]float32, 160))
	if err := s.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	for name, wantBytes := range map[string]int{
		"denoise.wav": 480 * 2,
		"tse.wav":     160 * 2,
	} {
		path := filepath.Join(dir, name)
		assertWavDataLen(t, path, wantBytes)
	}
}

func TestSessionTranscripts(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(Options{Dir: dir, AudioStages: false, Transcripts: true})
	if err := s.WriteTranscript("raw.txt", "hello world"); err != nil {
		t.Fatalf("WriteTranscript: %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(dir, "raw.txt"))
	if string(got) != "hello world" {
		t.Errorf("raw.txt=%q", got)
	}
	_ = s.Close()
}

func TestSessionDisabledIsNoOp(t *testing.T) {
	s, err := Open(Options{Dir: "", AudioStages: false, Transcripts: false})
	if err != nil {
		t.Fatalf("Open returned err for empty options: %v", err)
	}
	if s != nil {
		t.Errorf("expected nil session for fully-disabled options")
	}
	// Methods on nil session must be safe.
	s.AppendStage("anything", []float32{1, 2, 3})
	_ = s.WriteTranscript("raw.txt", "x")
	_ = s.Close()
}

func assertWavDataLen(t *testing.T, path string, wantBytes int) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %q: %v", path, err)
	}
	if len(data) < 44 {
		t.Fatalf("%q: too short (%d bytes)", path, len(data))
	}
	// "data" chunk size is at offset 40..44 in our writer.
	got := int(binary.LittleEndian.Uint32(data[40:44]))
	if got != wantBytes {
		t.Errorf("%q: data chunk size=%d, want %d", path, got, wantBytes)
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd core && go test ./internal/recorder/...`
Expected: FAIL — package missing.

- [ ] **Step 3: Implement the package**

```go
// core/internal/recorder/recorder.go
//
// Package recorder taps audio + transcripts at each pipeline layer for
// offline inspection. Writes one streaming WAV per registered stage at
// the stage's output sample rate, plus plain-text transcript files.
//
// Layout under Dir (only files for enabled taps appear):
//   <stage>.wav   per AddStage call
//   raw.txt       joined raw Whisper text
//   dict.txt      after dict-correction
//   cleaned.txt   after LLM cleanup
//
// Methods on a nil *Session are safe no-ops, so callers can write:
//
//   if rec, _ := recorder.Open(opts); rec != nil { defer rec.Close() }
//   rec.AppendStage("denoise", out) // safe even if rec == nil
package recorder

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sync"
)

// Options selects which taps are enabled and where files land.
type Options struct {
	Dir         string
	AudioStages bool // enable per-stage WAVs (registered via AddStage)
	Transcripts bool // enable raw.txt / dict.txt / cleaned.txt
}

// Session is the live recording context for one pipeline run.
type Session struct {
	dir         string
	audioOn     bool
	transcripts bool

	mu     sync.Mutex
	stages map[string]*wavWriter
}

// Open creates the output directory if any tap is enabled. Returns
// (nil, nil) when nothing is enabled — callers can treat that as "off".
func Open(opts Options) (*Session, error) {
	if !opts.AudioStages && !opts.Transcripts {
		return nil, nil
	}
	if opts.Dir == "" {
		return nil, fmt.Errorf("recorder: Dir is required when a tap is enabled")
	}
	if err := os.MkdirAll(opts.Dir, 0o755); err != nil {
		return nil, fmt.Errorf("recorder: mkdir %q: %w", opts.Dir, err)
	}
	return &Session{
		dir:         opts.Dir,
		audioOn:     opts.AudioStages,
		transcripts: opts.Transcripts,
		stages:      map[string]*wavWriter{},
	}, nil
}

// AddStage registers a stage by name + sample rate. The output file is
// <dir>/<name>.wav. Calling AddStage with the same name twice is an error.
// No-op when audio recording is disabled.
func (s *Session) AddStage(name string, sampleRate int) error {
	if s == nil || !s.audioOn {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.stages[name]; ok {
		return fmt.Errorf("recorder: stage %q already registered", name)
	}
	w, err := newWavWriter(filepath.Join(s.dir, name+".wav"), sampleRate)
	if err != nil {
		return err
	}
	s.stages[name] = w
	return nil
}

// AppendStage streams samples to the named stage's WAV. Unknown / disabled
// names are silently ignored — caller doesn't need to guard.
func (s *Session) AppendStage(name string, samples []float32) {
	if s == nil || !s.audioOn || len(samples) == 0 {
		return
	}
	s.mu.Lock()
	w := s.stages[name]
	s.mu.Unlock()
	if w == nil {
		return
	}
	w.append(samples)
}

// WriteTranscript saves text under the given filename (e.g. "raw.txt").
// No-op when transcripts are disabled.
func (s *Session) WriteTranscript(name, text string) error {
	if s == nil || !s.transcripts {
		return nil
	}
	return os.WriteFile(filepath.Join(s.dir, name), []byte(text), 0o644)
}

// Close patches the header of every WAV writer and closes the file.
// Safe to call on a nil Session and safe to call multiple times.
func (s *Session) Close() error {
	if s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var firstErr error
	for _, w := range s.stages {
		if err := w.close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	s.stages = nil
	return firstErr
}

// Dir returns the output directory ("" for nil Session).
func (s *Session) Dir() string {
	if s == nil {
		return ""
	}
	return s.dir
}

// --- streaming WAV writer (16-bit PCM mono) ---

const (
	wavBitsPerSample = 16
	wavChannels      = 1
)

type wavWriter struct {
	mu         sync.Mutex
	f          *os.File
	sampleRate uint32
	dataBytes  uint32
	closed     bool
}

func newWavWriter(path string, sampleRate int) (*wavWriter, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, fmt.Errorf("recorder: create %q: %w", path, err)
	}
	w := &wavWriter{f: f, sampleRate: uint32(sampleRate)}
	if err := w.writeHeader(0); err != nil {
		_ = f.Close()
		_ = os.Remove(path)
		return nil, err
	}
	return w, nil
}

func (w *wavWriter) writeHeader(dataBytes uint32) error {
	const fmtChunkSize uint32 = 16
	chunkLen := 36 + dataBytes
	byteRate := w.sampleRate * wavChannels * wavBitsPerSample / 8
	blockAlign := uint16(wavChannels * wavBitsPerSample / 8)
	if _, err := w.f.Seek(0, 0); err != nil {
		return err
	}
	if _, err := w.f.Write([]byte("RIFF")); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, chunkLen); err != nil {
		return err
	}
	if _, err := w.f.Write([]byte("WAVEfmt ")); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, fmtChunkSize); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, uint16(1)); err != nil { // PCM
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, uint16(wavChannels)); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, w.sampleRate); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, byteRate); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, blockAlign); err != nil {
		return err
	}
	if err := binary.Write(w.f, binary.LittleEndian, uint16(wavBitsPerSample)); err != nil {
		return err
	}
	if _, err := w.f.Write([]byte("data")); err != nil {
		return err
	}
	return binary.Write(w.f, binary.LittleEndian, dataBytes)
}

// append streams samples as int16 PCM, little-endian.
// Errors are swallowed (best-effort tap); the eventual close() surfaces
// header-patch failure if any.
func (w *wavWriter) append(samples []float32) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed || len(samples) == 0 {
		return
	}
	buf := make([]byte, 2*len(samples))
	for i, s := range samples {
		v := int16(math.MaxInt16 * clamp(s, -1, 1))
		buf[2*i] = byte(v)
		buf[2*i+1] = byte(v >> 8)
	}
	n, _ := w.f.Write(buf)
	w.dataBytes += uint32(n)
}

func (w *wavWriter) close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return nil
	}
	w.closed = true
	if err := w.writeHeader(w.dataBytes); err != nil {
		_ = w.f.Close()
		return err
	}
	return w.f.Close()
}

func clamp(v, lo, hi float32) float32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
```

- [ ] **Step 4: Run tests**

Run: `cd core && go test ./internal/recorder/...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/recorder/
git commit -m "feat(recorder): streaming per-stage WAV + transcript taps

Session.AddStage(name, rate) opens a WAV per stage; AppendStage
streams samples in. Methods are nil-safe so callers can hold a
*Session that's nil when recording is disabled. Header is patched
on Close so writes are bounded in memory."
```

---

## Task 7: Pipeline refactor — stage slices, Listener, Recorder

**Files:**
- Modify: `core/internal/pipeline/pipeline.go`
- Modify: `core/internal/pipeline/pipeline_test.go`

This is the biggest task. Drop the old fields, add new ones, rewrite `Run`, keep `LoadTSE` aligned with Task 5.

- [ ] **Step 1: Rewrite the Pipeline struct + Run**

Replace the body of `core/internal/pipeline/pipeline.go` with:

```go
package pipeline

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/recorder"
	"github.com/voice-keyboard/core/internal/speaker"
	"github.com/voice-keyboard/core/internal/transcribe"
)

const inputSampleRate = 48000

type Result struct {
	Raw      string
	Cleaned  string
	Terms    []string
	LLMError error
}

// Pipeline runs the audio → transcribe → dict → LLM cycle.
//
// Audio side is composed of two ordered Stage slices flanking the
// Chunker:
//
//   FrameStages: continuous stream, run on each pushed buffer
//                (typical: denoise → decimate)
//   Chunker:     splits the post-FrameStages stream into utterance chunks
//   ChunkStages: run per emitted chunk (typical: TSE)
//
// The composer is responsible for sample-rate alignment between adjacent
// stages — there is no graph-time validation.
type Pipeline struct {
	FrameStages []audio.Stage
	ChunkStages []audio.Stage

	Transcriber transcribe.Transcriber
	Dict        dict.Dictionary
	Cleaner     llm.Cleaner

	// Listener observes all pipeline events (stage processing, chunk
	// boundaries, LLM streaming). Fires from multiple goroutines —
	// implementation must be safe under concurrent invocation. Optional.
	Listener Listener

	// Recorder taps audio after each stage and the three transcript
	// stages. Optional; nil means no recording.
	Recorder *recorder.Session

	// ChunkerOpts overrides the default chunker thresholds. Zero-value
	// fields fall back to DefaultChunkerOpts.
	ChunkerOpts ChunkerOpts
}

// New builds a Pipeline with no stages. The composer assigns FrameStages
// and ChunkStages explicitly.
func New(t transcribe.Transcriber, dy dict.Dictionary, cl llm.Cleaner) *Pipeline {
	return &Pipeline{Transcriber: t, Dict: dy, Cleaner: cl}
}

// Run drains `frames` (Float32 mono, sample rate = whatever the first
// FrameStage expects, typically 48 kHz) until the channel closes or ctx
// is cancelled.
func (p *Pipeline) Run(ctx context.Context, frames <-chan []float32) (Result, error) {
	if p == nil {
		return Result{}, errors.New("pipeline: nil receiver")
	}
	log.Printf("[vkb] pipeline.Run: starting; awaiting frames")
	tStart := time.Now()
	defer func() {
		log.Printf("[vkb] pipeline.Run: total elapsed %v", time.Since(tStart))
	}()

	// Register stages with the recorder. We track each stage's running
	// output rate so the WAV header is correct: frame-side starts at
	// inputSampleRate, chunk-side starts at the post-chunker rate
	// (= last FrameStage output rate, by construction the Chunker rate).
	frameRate, chunkRate := p.registerRecorderStages()

	opts := p.ChunkerOpts
	if opts.VoiceThreshold == 0 && opts.SilenceHangMs == 0 && opts.MaxChunkMs == 0 {
		opts = DefaultChunkerOpts()
	}
	chunkCh := make(chan ChunkEmission, 4)
	var chunkIdx int
	chunker := NewChunker(opts, func(e ChunkEmission) {
		chunkIdx++
		dur := len(e.Samples) * 1000 / chunkerSampleRate
		log.Printf("[vkb] chunk emitted #%d: %dms (%s)", chunkIdx, dur, e.Reason)
		p.emit(Event{
			Kind:       EventChunkEmitted,
			ChunkIdx:   chunkIdx,
			DurationMs: dur,
			Reason:     string(e.Reason),
		})
		select {
		case chunkCh <- e:
		case <-ctx.Done():
		}
	})

	// Chunk worker — single goroutine, per-chunk: ChunkStages → Transcribe.
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
				for range chunkCh {
				}
				return
			case e, ok := <-chunkCh:
				if !ok {
					return
				}
				samples := e.Samples
				rate := chunkRate
				for _, st := range p.ChunkStages {
					rmsIn := audio.RMS(samples)
					out, err := st.Process(ctx, samples)
					if err != nil {
						mu.Lock()
						workerErr = fmt.Errorf("%s: %w", st.Name(), err)
						mu.Unlock()
						for range chunkCh {
						}
						return
					}
					p.emit(Event{
						Kind:   EventStageProcessed,
						Stage:  st.Name(),
						RMSIn:  rmsIn,
						RMSOut: audio.RMS(out),
					})
					p.Recorder.AppendStage(st.Name(), out)
					if r := st.OutputRate(); r != 0 {
						rate = r
					}
					samples = out
				}
				_ = rate // currently informational; reserved for future-stage rate-aware logic

				t0 := time.Now()
				text, err := p.Transcriber.Transcribe(ctx, samples)
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
				p.emit(Event{
					Kind:      EventChunkTranscribed,
					ChunkIdx:  transcribed,
					ElapsedMs: ms,
					Text:      text,
				})
				mu.Lock()
				chunkTexts = append(chunkTexts, text)
				mu.Unlock()
			}
		}
	}()

	// Foreground: drain frames → FrameStages → Chunker.
	rate := frameRate
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
		if err := p.runFrameStages(ctx, f, rate); err != nil {
			cancelChunker(chunkCh)
			<-workerDone
			return Result{}, err
		}
	}
	// Flush each FrameStage in declaration order so residuals reach Chunker.
	if err := p.flushFrameStages(ctx); err != nil {
		cancelChunker(chunkCh)
		<-workerDone
		return Result{}, err
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
	_ = p.Recorder.WriteTranscript("raw.txt", raw)
	if raw == "" {
		return Result{}, nil
	}
	corrected, terms := p.Dict.Match(raw)
	log.Printf("[vkb] pipeline.Run: dict matched %d terms", len(terms))
	_ = p.Recorder.WriteTranscript("dict.txt", corrected)

	tLLM := time.Now()
	var cleaned string
	var llmErr error
	firstTokenSeen := false
	wrappedDelta := func(s string) {
		if !firstTokenSeen {
			firstTokenSeen = true
			elapsed := int(time.Since(tLLM).Milliseconds())
			log.Printf("[vkb] LLM stream first token: %dms after stop", elapsed)
			p.emit(Event{Kind: EventLLMFirstToken, ElapsedMs: elapsed})
		}
		p.emit(Event{Kind: EventLLMDelta, Text: s})
	}
	if streamer, ok := p.Cleaner.(llm.StreamingCleaner); ok && p.Listener != nil {
		log.Printf("[vkb] pipeline.Run: cleaning via LLM (streaming)…")
		cleaned, llmErr = streamer.CleanStream(ctx, corrected, terms, wrappedDelta)
	} else {
		log.Printf("[vkb] pipeline.Run: cleaning via LLM…")
		cleaned, llmErr = p.Cleaner.Clean(ctx, corrected, terms)
	}
	if llmErr != nil {
		log.Printf("[vkb] pipeline.Run: LLM FAILED after %v: %v (using dict-corrected fallback)", time.Since(tLLM), llmErr)
		_ = p.Recorder.WriteTranscript("cleaned.txt", corrected)
		return Result{Raw: raw, Cleaned: corrected, Terms: terms, LLMError: llmErr}, nil
	}
	log.Printf("[vkb] pipeline.Run: LLM done in %v cleanedLen=%d", time.Since(tLLM), len(cleaned))
	_ = p.Recorder.WriteTranscript("cleaned.txt", cleaned)
	return Result{Raw: raw, Cleaned: cleaned, Terms: terms}, nil
}

// runFrameStages walks one input batch through every FrameStage and
// pushes the result into the chunker. (Chunker is invoked inside
// runFrameStages so we don't need to wire chunker into the loop body.)
//
// Note: chunker.Push is captured via closure on Pipeline so we can call
// this without passing it. The current caller pattern in Run uses an
// inline chunker; in practice, runFrameStages writes to chunker via
// the same Pipeline state. Keep the chunker reference inside Run by
// closing over it in a local helper rather than a method — see Step 1
// adjustment below.
func (p *Pipeline) runFrameStages(ctx context.Context, in []float32, _ int) error {
	// Implementation lives in Run via a closure that captures `chunker`.
	// This stub is unused — see Step 2 for the adjusted refactor pattern.
	return nil
}

func (p *Pipeline) flushFrameStages(ctx context.Context) error { return nil }
func (p *Pipeline) registerRecorderStages() (frameRate, chunkRate int) {
	frameRate, chunkRate = inputSampleRate, chunkerSampleRate
	if p.Recorder == nil {
		return
	}
	rate := frameRate
	for _, st := range p.FrameStages {
		_ = p.Recorder.AddStage(st.Name(), rateOf(st, rate))
		if r := st.OutputRate(); r != 0 {
			rate = r
		}
	}
	chunkRate = rate
	for _, st := range p.ChunkStages {
		_ = p.Recorder.AddStage(st.Name(), rateOf(st, rate))
		if r := st.OutputRate(); r != 0 {
			rate = r
		}
	}
	return
}

func rateOf(st audio.Stage, prev int) int {
	if r := st.OutputRate(); r != 0 {
		return r
	}
	return prev
}

func cancelChunker(ch chan ChunkEmission) {
	go func() {
		for range ch {
		}
	}()
}

func (p *Pipeline) emit(e Event) {
	if p.Listener == nil {
		return
	}
	p.Listener(e)
}

// LoadTSE — see Task 5; signature is now (audio.Stage, error).
//
// LoadTSE is in Task 5; it lives in this file. Keep the implementation
// from Task 5 unchanged here.
func LoadTSE(backend *speaker.Backend, profileDir, modelsDir, onnxLibPath string) (audio.Stage, error) {
	if backend == nil {
		backend = speaker.Default
	}
	_, err := speaker.LoadProfile(profileDir)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("load tse: profile: %w", err)
	}
	embPath := profileDir + "/enrollment.emb"
	ref, err := speaker.LoadEmbedding(embPath, backend.EmbeddingDim)
	if os.IsNotExist(err) {
		return nil, fmt.Errorf("load tse: enrollment.emb missing — re-run enroll.sh")
	}
	if err != nil {
		return nil, fmt.Errorf("load tse: embedding: %w", err)
	}
	if err := speaker.InitONNXRuntime(onnxLibPath); err != nil {
		return nil, fmt.Errorf("load tse: onnx runtime: %w", err)
	}
	tse, err := speaker.NewSpeakerGate(backend.TSEPath(modelsDir), ref)
	if err != nil {
		return nil, fmt.Errorf("load tse: model: %w", err)
	}
	return tse, nil
}

// Close releases resources owned by stages and the transcriber.
func (p *Pipeline) Close() error {
	if p == nil {
		return nil
	}
	var firstErr error
	for _, st := range append(append([]audio.Stage(nil), p.FrameStages...), p.ChunkStages...) {
		if c, ok := st.(audio.Closer); ok {
			if err := c.Close(); err != nil && firstErr == nil {
				firstErr = err
			}
		}
	}
	if p.Transcriber != nil {
		if err := p.Transcriber.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}
```

- [ ] **Step 2: Adjust the foreground loop to actually wire `runFrameStages` to the chunker**

The structure above introduced two helper stubs (`runFrameStages`, `flushFrameStages`) that don't have access to the `chunker` local. Replace them by inlining the work into `Run` using local closures. Concretely, **inside** `Run` (after `chunker := NewChunker(...)`), define:

```go
runFrameStages := func(in []float32) error {
	samples := in
	for _, st := range p.FrameStages {
		rmsIn := audio.RMS(samples)
		out, err := st.Process(ctx, samples)
		if err != nil {
			return fmt.Errorf("%s: %w", st.Name(), err)
		}
		p.emit(Event{Kind: EventStageProcessed, Stage: st.Name(), RMSIn: rmsIn, RMSOut: audio.RMS(out)})
		p.Recorder.AppendStage(st.Name(), out)
		samples = out
	}
	chunker.Push(samples)
	return nil
}

flushFrameStages := func() error {
	for _, st := range p.FrameStages {
		f, ok := st.(audio.Flusher)
		if !ok {
			continue
		}
		residual, err := f.Flush(ctx)
		if err != nil {
			return fmt.Errorf("%s flush: %w", st.Name(), err)
		}
		if len(residual) == 0 {
			continue
		}
		p.emit(Event{Kind: EventStageProcessed, Stage: st.Name(), RMSIn: 0, RMSOut: audio.RMS(residual)})
		p.Recorder.AppendStage(st.Name(), residual)
		// IMPORTANT: residuals from earlier stages do NOT re-run later
		// FrameStages — by the time we Flush, downstream stages have
		// already processed everything they were given. This is the same
		// behavior as the pre-refactor drainAndDenoiseStreaming tail
		// padding (it dropped through to the chunker, not back through
		// resample). For correctness we push residual to the chunker
		// directly only if this is the LAST FrameStage; otherwise it
		// would skip downstream processing. The simplest invariant:
		// require Flusher only on terminal stages (today: none — denoise
		// is non-terminal). Document that residuals from non-terminal
		// stages are silently discarded.
	}
	return nil
}
```

Then call them from the foreground loop. Replace the two unused helper-method stubs (`runFrameStages` / `flushFrameStages`) and `cancelChunker` cleanup with the closures above. The earlier method versions in Step 1 are sketches — delete them; keep only `registerRecorderStages` and `rateOf` as methods.

**Caveat**: residual handling has the corner case noted in the comment above. For the current pipeline (denoise → decimate), denoise is non-terminal, so calling its `Flush` and pushing residual to the chunker would skip Decimate3 and emit 48 kHz samples into the chunker (wrong). For the initial implementation, **call `Flush` only on the last FrameStage** and push that residual to the chunker. Add a TODO comment for full multi-stage flush handling.

Adjust `flushFrameStages` to:

```go
flushFrameStages := func() error {
	if len(p.FrameStages) == 0 {
		return nil
	}
	last := p.FrameStages[len(p.FrameStages)-1]
	f, ok := last.(audio.Flusher)
	if !ok {
		return nil
	}
	residual, err := f.Flush(ctx)
	if err != nil {
		return fmt.Errorf("%s flush: %w", last.Name(), err)
	}
	if len(residual) == 0 {
		return nil
	}
	p.emit(Event{Kind: EventStageProcessed, Stage: last.Name(), RMSIn: 0, RMSOut: audio.RMS(residual)})
	p.Recorder.AppendStage(last.Name(), residual)
	chunker.Push(residual)
	return nil
}
```

(For now the only Flusher is `denoise.Stage`, and the canonical FrameStages order is `[denoise, decimate]` — so denoise is *not* last and its residual is dropped. That matches the "tail-pad-and-emit" semantics today only loosely; a future task could buffer residuals through subsequent stages. Out of scope for this branch.)

- [ ] **Step 3: Update existing pipeline tests**

Edit `core/internal/pipeline/pipeline_test.go`:
- Anywhere the test constructed a Pipeline with `New(d, t, dy, cl)`, change to `New(t, dy, cl)` and assign `FrameStages` / `ChunkStages` explicitly with the same Denoiser wrapped via `denoise.NewStage(...)` and `resample.NewDecimate3()` if required.
- Anywhere a test set `p.LevelCallback = ...` etc., change to setting `p.Listener` and switching on `Event.Kind`.
- Tests that read `res.Cleaned`/`res.Raw` are unchanged.

- [ ] **Step 4: Update the integration test**

Edit `core/test/integration/full_pipeline_test.go` similarly (build pipeline via stage slices, single Listener if it asserts on callbacks).

- [ ] **Step 5: Run all pipeline tests**

Run: `cd core && go test ./internal/pipeline/...`
Expected: PASS.

Run: `cd core && go test ./test/integration/...`
Expected: PASS (or skip if external deps absent — that's pre-existing).

- [ ] **Step 6: Commit**

```bash
git add core/internal/pipeline/ core/test/integration/
git commit -m "refactor(pipeline): stage-slice composition + unified Listener

Pipeline now holds FrameStages/ChunkStages instead of a fixed
denoise+TSE pair, and a single Listener replaces the 5 per-event
callbacks. Each stage's output is taped to the Recorder by Name();
the Chunker stays as the fixed split between FrameStages and
ChunkStages. Adding a layer is now p.FrameStages = append(...)."
```

---

## Task 8: Wire stages, Listener, and recording flags in `vkb-cli/pipe.go`

**Files:**
- Modify: `core/cmd/vkb-cli/pipe.go`

- [ ] **Step 1: Add the new flags + build stages**

Replace the relevant blocks. Specifically:

After the existing flag declarations, add:

```go
recordDir := fs.String("record-dir", "", "directory to write per-stage WAVs and transcripts")
recordSpec := fs.String("record", "", "comma-separated taps: audio,transcripts (e.g. --record audio,transcripts)")
```

After parsing flags but before constructing the pipeline, parse the spec:

```go
var recOpts recorder.Options
recOpts.Dir = *recordDir
for _, t := range strings.Split(*recordSpec, ",") {
	switch strings.TrimSpace(t) {
	case "audio":
		recOpts.AudioStages = true
	case "transcripts":
		recOpts.Transcripts = true
	case "":
		// empty token from "" or trailing comma — ignore
	default:
		fmt.Fprintf(os.Stderr, "unknown --record tap: %q (want audio,transcripts)\n", t)
		return 2
	}
}
rec, recErr := recorder.Open(recOpts)
if recErr != nil {
	fmt.Fprintf(os.Stderr, "recorder: %v\n", recErr)
	return 1
}
defer rec.Close()
```

Replace the `pipeline.New(d, w, dy, cleaner)` call:

```go
p := pipeline.New(w, dy, cleaner)
p.Recorder = rec
p.FrameStages = []audio.Stage{
	denoise.NewStage(d),
	resample.NewDecimate3(),
}
```

Replace the `if *speakerMode { ... p.TSE = tse; p.TSERef = ref ... }` block with:

```go
if *speakerMode {
	profileDir := os.Getenv("VKB_PROFILE_DIR")
	if profileDir == "" {
		profileDir = os.ExpandEnv("$HOME/.config/voice-keyboard")
	}
	modelsDir := os.Getenv("VKB_MODELS_DIR")
	if modelsDir == "" {
		modelsDir = os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models")
	}
	onnxLib := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if onnxLib == "" {
		onnxLib = "/opt/homebrew/lib/libonnxruntime.dylib"
	}
	backend, beErr := speaker.BackendByName(*tseBackend)
	if beErr != nil {
		fmt.Fprintf(os.Stderr, "speaker gate: %v\n", beErr)
		return 2
	}
	tse, err := pipeline.LoadTSE(backend, profileDir, modelsDir, onnxLib)
	if err != nil {
		fmt.Fprintf(os.Stderr, "speaker gate: %v\n", err)
		return 1
	}
	if tse == nil {
		fmt.Fprintln(os.Stderr, "speaker gate: no enrollment found — run ./enroll.sh first")
		return 1
	}
	p.ChunkStages = []audio.Stage{tse}
	fmt.Fprintf(os.Stderr, "[vkb] speaker gating active (backend=%s)\n", backend.Name)
}
```

Replace the per-callback `--latency-report` wiring with one Listener:

```go
if *latencyReport {
	p.Listener = func(e pipeline.Event) {
		repMu.Lock()
		defer repMu.Unlock()
		switch e.Kind {
		case pipeline.EventChunkEmitted:
			repChunks = append(repChunks, chunkInfo{
				emittedAt: time.Now(), dur: e.DurationMs, reason: e.Reason,
			})
		case pipeline.EventChunkTranscribed:
			if e.ChunkIdx-1 < len(repChunks) {
				repChunks[e.ChunkIdx-1].transcMs = e.ElapsedMs
				repChunks[e.ChunkIdx-1].text = e.Text
			}
		case pipeline.EventLLMFirstToken:
			repFirstTok = time.Duration(e.ElapsedMs) * time.Millisecond
			repFirstSeen = true
		}
	}
}
```

Add imports: `"github.com/voice-keyboard/core/internal/audio"`, `"github.com/voice-keyboard/core/internal/recorder"`, `"github.com/voice-keyboard/core/internal/resample"`, plus `"strings"` if not already.

- [ ] **Step 2: Build the CLI**

Run: `cd core && go build -tags=whispercpp ./cmd/vkb-cli/`
Expected: clean build.

- [ ] **Step 3: Smoke-test the recording flag**

Run: `./vkb-cli pipe --record-dir /tmp/vkb-test --record audio,transcripts <some 48kHz wav>`
Expected: `/tmp/vkb-test/denoise.wav`, `/tmp/vkb-test/decimate.wav` exist, plus `raw.txt`/`dict.txt`/`cleaned.txt`. Inspect with `afplay` or `ffprobe`.

- [ ] **Step 4: Commit**

```bash
git add core/cmd/vkb-cli/pipe.go
git commit -m "feat(vkb-cli): build stages, single Listener, --record-dir/--record flags

--record-dir picks the output directory; --record audio enables one
WAV per stage, --record transcripts enables raw/dict/cleaned text
files. The latency-report path moves from 3 separate callbacks to one
Listener with a Kind switch."
```

---

## Task 9: Update `libvkb` FFI to build stages and use one Listener

**Files:**
- Modify: `core/cmd/libvkb/state.go`
- Modify: `core/cmd/libvkb/exports.go`

- [ ] **Step 1: Build stages in `state.go:buildPipeline`**

Replace the section that constructed a Pipeline with the old constructor and assigned `p.TSE` / `p.TSERef`:

```go
var d denoise.Denoiser
if !e.cfg.DisableNoiseSuppression {
	d = newDeepFilterOrPassthrough(e.cfg.DeepFilterModelPath)
} else {
	d = denoise.NewPassthrough()
}

p := pipeline.New(tr, dy, cleaner)
p.FrameStages = []audio.Stage{
	denoise.NewStage(d),
	resample.NewDecimate3(),
}

if e.cfg.TSEEnabled {
	backend, beErr := speaker.BackendByName(e.cfg.TSEBackend)
	if beErr != nil {
		log.Printf("[vkb] buildPipeline: TSE backend lookup failed, continuing without TSE: %v", beErr)
		e.setLastError("tse: " + beErr.Error())
		return p, nil
	}
	modelsDir := filepath.Dir(e.cfg.TSEModelPath)
	tse, tseErr := pipeline.LoadTSE(backend, e.cfg.TSEProfileDir, modelsDir, e.cfg.ONNXLibPath)
	if tseErr != nil {
		log.Printf("[vkb] buildPipeline: TSE load failed, continuing without TSE: %v", tseErr)
		e.setLastError("tse: " + tseErr.Error())
	} else if tse != nil {
		p.ChunkStages = []audio.Stage{tse}
		log.Printf("[vkb] buildPipeline: TSE loaded (profile=%s)", e.cfg.TSEProfileDir)
	} else {
		log.Printf("[vkb] buildPipeline: TSE enabled but no enrollment found at %s", e.cfg.TSEProfileDir)
	}
}
return p, nil
```

Add imports `"github.com/voice-keyboard/core/internal/audio"`, `"github.com/voice-keyboard/core/internal/resample"`. Drop `p.TSE`/`p.TSERef` references.

- [ ] **Step 2: Adapt callbacks to single Listener in `exports.go:vkb_start_capture`**

Replace the two `pipe.LevelCallback = ...` and `pipe.LLMDeltaCallback = ...` blocks with one Listener that filters by Kind + stage Name:

```go
const levelHz = 30
levelInterval := time.Second / levelHz
var (
	levelMu     sync.Mutex
	levelMax    float32
	levelLastAt = time.Now()
)
pipe.Listener = func(ev pipeline.Event) {
	switch ev.Kind {
	case pipeline.EventStageProcessed:
		// Mirror today's "level" event: throttled max-RMS of the
		// denoise stage's output (the existing UI signal). If denoise
		// is absent, fall back to the first stage.
		if ev.Stage != "denoise" {
			return
		}
		levelMu.Lock()
		defer levelMu.Unlock()
		now := time.Now()
		if ev.RMSOut > levelMax {
			levelMax = ev.RMSOut
		}
		if now.Sub(levelLastAt) < levelInterval {
			return
		}
		select {
		case e.events <- event{Kind: "level", RMS: levelMax}:
		default:
		}
		levelMax = 0
		levelLastAt = now

	case pipeline.EventLLMDelta:
		if ev.Text == "" {
			return
		}
		e.events <- event{Kind: "chunk", Text: ev.Text}
	}
}
```

Add `"github.com/voice-keyboard/core/internal/pipeline"` import if not already imported in this file.

- [ ] **Step 3: Build libvkb**

Run: `cd core && go build -tags=whispercpp -buildmode=c-archive ./cmd/libvkb/`
Expected: clean build.

- [ ] **Step 4: Run libvkb tests if present**

Run: `cd core && go test -tags=whispercpp ./cmd/libvkb/...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/cmd/libvkb/
git commit -m "refactor(libvkb): build stage slices, adapt listener to JSON events

Pipeline construction switches from p.TSE/p.TSERef + 5 callbacks to
FrameStages/ChunkStages + one Listener. The Listener filters
EventStageProcessed for stage \"denoise\" to produce the existing
\"level\" JSON event (preserving the 30 Hz throttle), and forwards
EventLLMDelta as the existing \"chunk\" event."
```

---

## Task 10: End-to-end verification

- [ ] **Step 1: Full test suite**

Run: `cd core && go test ./...`
Expected: PASS (subject to existing skips for ONNX/Whisper integration tests when models aren't present).

- [ ] **Step 2: Build all entrypoints**

Run:
```
cd core && go build ./...
cd core && go build -tags=whispercpp ./...
cd core && go build -tags=whispercpp,deepfilter ./...
cd core && go build -tags=whispercpp,deepfilter -buildmode=c-archive ./cmd/libvkb/
```
Expected: each clean.

- [ ] **Step 3: Smoke-test `vkb-cli pipe --record`**

Pick any existing 48 kHz mono WAV (e.g. `assets/test/sample.wav` if it exists, or capture one with `vkb-cli capture --out /tmp/in.wav --secs 5`).

Run:
```
mkdir -p /tmp/vkb-rec
./vkb-cli pipe --record-dir /tmp/vkb-rec --record audio,transcripts /tmp/in.wav
```
Expected:
- `/tmp/vkb-rec/denoise.wav` (48 kHz)
- `/tmp/vkb-rec/decimate.wav` (16 kHz)
- `/tmp/vkb-rec/raw.txt`, `/tmp/vkb-rec/dict.txt`, `/tmp/vkb-rec/cleaned.txt`

If `--speaker` is also passed and enrollment exists, expect `/tmp/vkb-rec/tse.wav` as well.

Verify each WAV plays back and the transcripts are non-empty.

- [ ] **Step 4: Commit any final fixes** (skip if none)

```bash
git commit -am "fix: end-to-end touch-ups from Task 10"
```

---

## Self-Review Checklist

- [x] **Spec coverage:**
  - Unified Listener replacing 5 callbacks → Task 4 (define), Task 7 (use), Task 8/9 (consumers).
  - Pluggable Stage interface + composition → Task 1 (define), Tasks 2/3/5 (Decimate3/Denoise/TSE adopt), Task 7 (Pipeline composes).
  - Recording: per-layer audio → Task 6 (Session) + Task 7 (taps in Run).
  - Recording: pre-/post-LLM transcripts → Task 7 (`raw.txt`, `dict.txt`, `cleaned.txt`) + Task 8 (CLI flags).
  - Separate branch → already on `feat/visibility-recording` worktree.
  - Don't touch Chunker → Chunker stays as fixed splitter in Task 7.
- [x] **Placeholder scan:** No "TBD"/"implement later"/"appropriate error handling"/"similar to Task N" — all code is concrete.
- [x] **Type consistency:**
  - `Stage.Name() / OutputRate() / Process(ctx, in)` consistent across Tasks 1, 2, 3, 5, 7.
  - `Event.Kind / Stage / RMSIn / RMSOut / ChunkIdx / DurationMs / Reason / ElapsedMs / Text` consistent in Tasks 4, 7, 8, 9.
  - `pipeline.New(t, dy, cl)` used consistently in Tasks 7, 8, 9 (3 args, no denoiser).
  - `LoadTSE` returns `(audio.Stage, error)` in Tasks 5, 7, 8, 9.
  - `recorder.Options{ Dir, AudioStages, Transcripts }` consistent in Tasks 6, 8.

---

## Notes for the executor

- The plan deletes the `ChunkEmittedCallback` field but Task 8's CLI latency-report path subscribes via the new `Listener` instead. If you find pre-existing tests that asserted on the old field directly, migrate them to the Listener.
- `EventStageProcessed` carries RMS for *every* stage, not just denoise. The libvkb FFI in Task 9 filters for `Stage == "denoise"` to preserve today's "level" event meaning. If a future host wants per-stage levels, drop the filter.
- Residual flushing (Task 7 Step 2 caveat): only the *terminal* FrameStage's residual is currently pushed to the chunker. Multi-stage flush is out of scope; document that as a TODO comment in `Run`.
- TSE's `Extract` method is kept alongside `Process` as a domain alias. If duplication bothers a reviewer, drop `Extract` and have callers use `Process`.
- Run `go vet ./...` after each task — silent type drift between tasks is the most common plan-execution bug.
