# diar_mask Target Selection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `diar_mask`, a speaker-cleanup component that diarizes a mixture, cosine-*selects* the enrolled speaker's track, and time-masks — keeping the user's original audio verbatim — and measure it against `SpeakerGate` in the existing cleanup eval harness.

**Architecture:** A new production `DiarMask` type in `core/internal/speaker/` implements the same interfaces as `SpeakerGate` (`Cleanup`, `audio.Stage`, `LastSimilarity()`). It splits the input into ≤10 s windows, runs an injected `Segmenter` (pyannote/segmentation-3.0 ONNX) per window to get per-frame local-speaker activity, embeds each local speaker's exclusive frames with the existing ECAPA encoder, cosine-selects the track matching the enrolled reference, builds a target-activity mask, and multiplies it against the original samples. Pure decode/mask/select logic is unit-tested via a fake segmenter + injected embedder (no ONNX); the real ONNX path and the head-to-head comparison run in the harness, skipping cleanly when models are absent.

**Tech Stack:** Go 1.26, `github.com/yalue/onnxruntime_go` v1.29.0, the existing ECAPA `speaker_encoder.onnx`, whisper.cpp (WER), the LibriSpeech/MUSAN fixtures + mix machinery in `core/internal/speaker`.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-06-20-diarization-mask-select-design.md` is the source of truth. Honor it.
- **Scope:** Harness experiment only. NO live pipeline wiring, NO preset/config changes, NO `build.FromOptions` branch, NO C-ABI/Mac changes, NO modification of `speakerbeam.go`/`SpeakerGate`. `diar_mask` is added *alongside* TSE.
- **Interfaces (verbatim, must match):**
  - `audio.Stage` (core/internal/audio/stage.go:14): `Name() string`, `OutputRate() int`, `Process(ctx context.Context, in []float32) ([]float32, error)`.
  - `Cleanup` (core/internal/speaker/cleanup.go:10): `Process(ctx context.Context, mixed []float32) ([]float32, error)`, `Name() string`, `Close() error`.
  - Score hook (type-asserted at pipeline.go:156): `LastSimilarity() float32`.
- **Audio contract:** All stages produce `[]float32` mono PCM in [-1,1]; `DiarMask.Process` returns **same length** as input; 16 kHz; `OutputRate()` returns 0 (preserve).
- **Sample rate:** 16000 Hz. Window length: 160000 samples (10 s).
- **Reuse, do not reinvent:** `ComputeEmbedding(modelPath string, samples16k []float32, dim int) ([]float32, error)` (embedding.go:18); `cosineSimilarity(a, b []float32) float32` (speakerbeam.go:232, same package); `InitONNXRuntime` / `resolveModelPath` / `optionalModelPath` / `initONNXOnce` (test helpers); harness `cleanupAdapters`/`matrixConditions`/`mixAtSNR`/`mixThree`/`rms` (test files). ECAPA `EmbeddingDim` = 192.
- **ONNX dynamic output:** `DynamicAdvancedSession.Run(inputs, outputs []Value)` allocates any `nil` output and writes it back into the slice (onnxruntime_go.go:3011); caller must `Destroy()` it. Use this for pyannote's dynamic `[1, frames, 7]` output — never hardcode a frame count.
- **Powerset classes (pyannote/segmentation-3.0), 7 classes in order:** `∅, {0}, {1}, {2}, {0,1}, {0,2}, {1,2}` (0-based local speakers; max 2 active per frame).
- TDD: write the failing test first, watch it fail, implement minimally, watch it pass, commit. Frequent commits. DRY. YAGNI.

---

## File Structure

- `core/internal/speaker/diarmask.go` — NEW (production, no build tag). Types: `SpeakerActivity`, `Segmenter`, `DiarMaskOptions`, `DiarMask`. Pure helpers: `powersetToActivity`, `buildFrameMask`, `frameMaskToSamples`, `applyMask`, `selectTarget`. Methods: `NewDiarMask`, `Process`, `Name`, `OutputRate`, `Close`, `LastSimilarity`.
- `core/internal/speaker/diarmask_pyannote.go` — NEW (production, no build tag). `pyannoteSegmenter` (real `Segmenter` over ONNX); `NewPyannoteSegmenter`.
- `core/internal/speaker/diarmask_test.go` — NEW (no build tag; runs always in CI). `fakeSegmenter`; unit tests for every pure helper + `Process` orchestration/fallbacks via fake segmenter + injected embedder; interface compile checks. Plus a real-model `pyannoteSegmenter` smoke test that `t.Skip`s without `PYANNOTE_SEG_PATH`.
- `core/internal/speaker/cleanup_eval_test.go` — MODIFY. Register `diar_mask` adapter; add `evaluateRetention` + a retention column to the matrix.
- `core/BUILDING_PYANNOTE_SEG.md` — NEW (doc). Export recipe for `pyannote/segmentation-3.0` → `pyannote_seg.onnx` (mirrors `BUILDING_PYANNOTE_SEP.md`).

---

## Task 1: Powerset → SpeakerActivity decode

**Files:**
- Create: `core/internal/speaker/diarmask.go`
- Test: `core/internal/speaker/diarmask_test.go`

**Interfaces:**
- Produces: `type SpeakerActivity struct { Frames [][]bool; FrameHopSamples int }`; `func powersetToActivity(data []float32, shape []int64, hopSamples int) (SpeakerActivity, error)` — squeezes leading size-1 dims, requires last dim == 7, argmaxes each frame's 7 logits, maps to a `[]bool` of length 3 via the powerset table.

- [ ] **Step 1: Write the failing test**

```go
// core/internal/speaker/diarmask_test.go
package speaker

import (
	"reflect"
	"testing"
)

func TestPowersetToActivity_MapsClassesToSpeakerSets(t *testing.T) {
	// 3 frames, 7 classes each. Argmax picks class 1 ({0}), class 4 ({0,1}), class 0 (∅).
	hi := float32(9)
	data := []float32{
		0, hi, 0, 0, 0, 0, 0, // frame 0 → class 1 → {0}
		0, 0, 0, 0, hi, 0, 0, // frame 1 → class 4 → {0,1}
		hi, 0, 0, 0, 0, 0, 0, // frame 2 → class 0 → {}
	}
	act, err := powersetToActivity(data, []int64{1, 3, 7}, 256)
	if err != nil {
		t.Fatalf("powersetToActivity: %v", err)
	}
	if act.FrameHopSamples != 256 {
		t.Errorf("FrameHopSamples=%d, want 256", act.FrameHopSamples)
	}
	want := [][]bool{
		{true, false, false},
		{true, true, false},
		{false, false, false},
	}
	if !reflect.DeepEqual(act.Frames, want) {
		t.Errorf("Frames=%v, want %v", act.Frames, want)
	}
}

func TestPowersetToActivity_RejectsWrongClassCount(t *testing.T) {
	if _, err := powersetToActivity([]float32{0, 0, 0}, []int64{1, 3}, 256); err == nil {
		t.Errorf("expected error for last dim != 7")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./core/internal/speaker/ -run TestPowersetToActivity -v`
Expected: FAIL — `undefined: powersetToActivity` / `SpeakerActivity`.

- [ ] **Step 3: Write minimal implementation**

```go
// core/internal/speaker/diarmask.go
package speaker

import (
	"fmt"
)

const (
	diarSampleRate  = 16000
	diarWindowLen   = diarSampleRate * 10 // 160000 samples = 10 s
	diarNumClasses  = 7
	diarMaxSpeakers = 3
)

// powersetClasses maps each of the 7 output classes to the set of local
// speakers (0-based) active in that class, per pyannote/segmentation-3.0.
var powersetClasses = [diarNumClasses][]int{
	{},     // 0: non-speech
	{0},    // 1
	{1},    // 2
	{2},    // 3
	{0, 1}, // 4
	{0, 2}, // 5
	{1, 2}, // 6
}

// SpeakerActivity is per-frame local-speaker activity for one window.
type SpeakerActivity struct {
	Frames          [][]bool // [frame][localSpeaker] active? (len diarMaxSpeakers)
	FrameHopSamples int      // samples per frame at 16 kHz
}

// powersetToActivity decodes a pyannote powerset segmentation tensor into
// per-frame speaker activity. data is the flat output; shape is its ONNX
// shape (leading size-1 dims allowed); the final dim must be 7.
func powersetToActivity(data []float32, shape []int64, hopSamples int) (SpeakerActivity, error) {
	if len(shape) == 0 || shape[len(shape)-1] != diarNumClasses {
		return SpeakerActivity{}, fmt.Errorf("diarmask: expected last dim %d, got shape %v", diarNumClasses, shape)
	}
	numFrames := 1
	for _, d := range shape[:len(shape)-1] {
		numFrames *= int(d)
	}
	if numFrames*diarNumClasses != len(data) {
		return SpeakerActivity{}, fmt.Errorf("diarmask: shape %v implies %d values, got %d", shape, numFrames*diarNumClasses, len(data))
	}
	frames := make([][]bool, numFrames)
	for f := 0; f < numFrames; f++ {
		row := data[f*diarNumClasses : (f+1)*diarNumClasses]
		best := 0
		for c := 1; c < diarNumClasses; c++ {
			if row[c] > row[best] {
				best = c
			}
		}
		active := make([]bool, diarMaxSpeakers)
		for _, spk := range powersetClasses[best] {
			active[spk] = true
		}
		frames[f] = active
	}
	return SpeakerActivity{Frames: frames, FrameHopSamples: hopSamples}, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./core/internal/speaker/ -run TestPowersetToActivity -v`
Expected: PASS (both subtests).

- [ ] **Step 5: Commit**

```bash
git add core/internal/speaker/diarmask.go core/internal/speaker/diarmask_test.go
git commit -m "feat(speaker): powerset segmentation decode for diar_mask"
```

---

## Task 2: Mask building, frame→sample upsample with ramps, apply

**Files:**
- Modify: `core/internal/speaker/diarmask.go`
- Test: `core/internal/speaker/diarmask_test.go`

**Interfaces:**
- Consumes: `SpeakerActivity` (Task 1).
- Produces:
  - `func buildFrameMask(act SpeakerActivity, targetIdx int) []bool` — `m[f] = act.Frames[f][targetIdx]` (inclusion bias: true whenever the target is active, including overlap frames).
  - `func frameMaskToSamples(frameMask []bool, hopSamples, n, rampSamples int) []float32` — upsample to `n` samples, raised-cosine ramps at on/off transitions.
  - `func applyMask(mixed, gain []float32) []float32` — element-wise product, same length, never aliases input.

- [ ] **Step 1: Write the failing test**

```go
// append to core/internal/speaker/diarmask_test.go
import "math"

func TestBuildFrameMask_InclusionBias(t *testing.T) {
	act := SpeakerActivity{Frames: [][]bool{
		{true, false, false}, // target 0 active
		{true, true, false},  // target 0 + spk1 overlap → still kept
		{false, true, false}, // only spk1 → dropped
	}}
	got := buildFrameMask(act, 0)
	want := []bool{true, true, false}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("frame %d: got %v want %v", i, got[i], want[i])
		}
	}
}

func TestFrameMaskToSamples_RampEndpointsAndPlateau(t *testing.T) {
	// One active frame of 100 samples, hop=100, ramp=10. Gain rises 0→1, plateaus, no fall (ends active).
	gain := frameMaskToSamples([]bool{true}, 100, 100, 10)
	if len(gain) != 100 {
		t.Fatalf("len=%d want 100", len(gain))
	}
	if gain[0] != 0 {
		t.Errorf("gain[0]=%f want 0 (ramp start)", gain[0])
	}
	if math.Abs(float64(gain[50]-1)) > 1e-6 {
		t.Errorf("gain[50]=%f want 1 (plateau)", gain[50])
	}
	for i := 1; i < 10; i++ { // ramp is monotonic non-decreasing
		if gain[i] < gain[i-1] {
			t.Errorf("ramp not monotonic at %d: %f < %f", i, gain[i], gain[i-1])
		}
	}
}

func TestApplyMask_ScalesAndCopies(t *testing.T) {
	in := []float32{1, 1, 1, 1}
	gain := []float32{0, 0.5, 1, 0}
	out := applyMask(in, gain)
	want := []float32{0, 0.5, 1, 0}
	for i := range want {
		if out[i] != want[i] {
			t.Errorf("out[%d]=%f want %f", i, out[i], want[i])
		}
	}
	in[0] = 9 // mutation must not affect out
	if out[0] != 0 {
		t.Errorf("applyMask aliased input")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./core/internal/speaker/ -run 'TestBuildFrameMask|TestFrameMaskToSamples|TestApplyMask' -v`
Expected: FAIL — undefined functions.

- [ ] **Step 3: Write minimal implementation**

```go
// append to core/internal/speaker/diarmask.go
import "math" // add to the import block

// buildFrameMask returns per-frame keep/drop for the target track. A frame is
// kept whenever the target is active (including overlap with other speakers).
func buildFrameMask(act SpeakerActivity, targetIdx int) []bool {
	m := make([]bool, len(act.Frames))
	for f, active := range act.Frames {
		if targetIdx >= 0 && targetIdx < len(active) {
			m[f] = active[targetIdx]
		}
	}
	return m
}

// frameMaskToSamples upsamples a frame-level boolean mask to an n-sample gain
// curve in [0,1], applying a raised-cosine fade of rampSamples at the start and
// end of every active run (including the signal boundaries) to avoid clicks.
// At the center of a long run the gain is exactly 1; at a run edge it is 0.
func frameMaskToSamples(frameMask []bool, hopSamples, n, rampSamples int) []float32 {
	gain := make([]float32, n)
	if hopSamples <= 0 {
		return gain
	}
	on := func(i int) bool {
		if i < 0 || i >= n {
			return false // off the ends of the signal → treat as inactive
		}
		f := i / hopSamples
		return f < len(frameMask) && frameMask[f]
	}
	for i := 0; i < n; i++ {
		if !on(i) {
			continue
		}
		if rampSamples <= 0 {
			gain[i] = 1
			continue
		}
		// d = distance to the nearer edge of this active run, capped at
		// rampSamples (symmetric expansion stops when either side turns off).
		d := 0
		for d < rampSamples && on(i-d-1) && on(i+d+1) {
			d++
		}
		t := float64(d) / float64(rampSamples)
		gain[i] = float32(0.5 * (1 - math.Cos(math.Pi*t)))
	}
	return gain
}

// applyMask multiplies mixed by gain element-wise. Returns a fresh slice.
func applyMask(mixed, gain []float32) []float32 {
	out := make([]float32, len(mixed))
	for i := range mixed {
		if i < len(gain) {
			out[i] = mixed[i] * gain[i]
		}
	}
	return out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./core/internal/speaker/ -run 'TestBuildFrameMask|TestFrameMaskToSamples|TestApplyMask' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/speaker/diarmask.go core/internal/speaker/diarmask_test.go
git commit -m "feat(speaker): mask build + raised-cosine ramp + apply for diar_mask"
```

---

## Task 3: Target track selection by cosine

**Files:**
- Modify: `core/internal/speaker/diarmask.go`
- Test: `core/internal/speaker/diarmask_test.go`

**Interfaces:**
- Consumes: `SpeakerActivity` (Task 1).
- Produces: `func selectTarget(act SpeakerActivity, window []float32, embed func([]float32) ([]float32, error), ref []float32, minExclusiveSamples int) (idx int, cos float32, ok bool, err error)`. Gathers each local speaker's **exclusive** frames (that speaker active, no other), embeds them when total ≥ `minExclusiveSamples`, returns the max-cosine track. `ok=false` when fewer than 2 speakers qualify (single-track → caller passes through).

- [ ] **Step 1: Write the failing test**

```go
// append to core/internal/speaker/diarmask_test.go

func TestSelectTarget_PicksHighestCosineTrack(t *testing.T) {
	// Frames: spk0 exclusive on [0,2), spk1 exclusive on [2,4). hop=100 → 200 samples each.
	act := SpeakerActivity{
		Frames: [][]bool{
			{true, false, false}, {true, false, false},
			{false, true, false}, {false, true, false},
		},
		FrameHopSamples: 100,
	}
	window := make([]float32, 400)
	ref := []float32{1, 0}
	embed := func(s []float32) ([]float32, error) {
		// Embedding encodes which half had energy via length heuristic:
		// caller hands us spk0's samples (idx 0..199) vs spk1's (200..399).
		// We can't see indices, so key off a marker: spk0 region is all 0.25,
		// spk1 region all 0.75 (set below).
		if s[0] == 0.25 {
			return []float32{1, 0}, nil // matches ref
		}
		return []float32{0, 1}, nil // orthogonal to ref
	}
	for i := 0; i < 200; i++ {
		window[i] = 0.25
	}
	for i := 200; i < 400; i++ {
		window[i] = 0.75
	}
	idx, cos, ok, err := selectTarget(act, window, embed, ref, 100)
	if err != nil {
		t.Fatalf("selectTarget: %v", err)
	}
	if !ok {
		t.Fatalf("ok=false, want true (two qualifying tracks)")
	}
	if idx != 0 {
		t.Errorf("idx=%d want 0 (spk0 matches ref)", idx)
	}
	if cos < 0.99 {
		t.Errorf("cos=%f want ~1.0", cos)
	}
}

func TestSelectTarget_SingleSpeakerNotOK(t *testing.T) {
	act := SpeakerActivity{
		Frames:          [][]bool{{true, false, false}, {true, false, false}},
		FrameHopSamples: 100,
	}
	window := make([]float32, 200)
	embed := func(s []float32) ([]float32, error) { return []float32{1, 0}, nil }
	_, _, ok, err := selectTarget(act, window, embed, []float32{1, 0}, 100)
	if err != nil {
		t.Fatalf("selectTarget: %v", err)
	}
	if ok {
		t.Errorf("ok=true, want false (only one track)")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./core/internal/speaker/ -run TestSelectTarget -v`
Expected: FAIL — `undefined: selectTarget`.

- [ ] **Step 3: Write minimal implementation**

```go
// append to core/internal/speaker/diarmask.go

// selectTarget embeds each local speaker's exclusive-frame audio and returns
// the track whose embedding has the highest cosine to ref. ok is false when
// fewer than two tracks have enough exclusive audio to embed (nothing to
// separate → caller should pass through).
func selectTarget(act SpeakerActivity, window []float32, embed func([]float32) ([]float32, error), ref []float32, minExclusiveSamples int) (int, float32, bool, error) {
	hop := act.FrameHopSamples
	// Gather exclusive samples per speaker.
	exclusive := make([][]float32, diarMaxSpeakers)
	for f, active := range act.Frames {
		count := 0
		only := -1
		for spk, on := range active {
			if on {
				count++
				only = spk
			}
		}
		if count != 1 {
			continue // non-speech or overlap → not exclusive
		}
		start := f * hop
		end := start + hop
		if start >= len(window) {
			break
		}
		if end > len(window) {
			end = len(window)
		}
		exclusive[only] = append(exclusive[only], window[start:end]...)
	}
	bestIdx, bestCos, qualifying := -1, float32(-2), 0
	for spk := 0; spk < diarMaxSpeakers; spk++ {
		if len(exclusive[spk]) == 0 || len(exclusive[spk]) < minExclusiveSamples {
			continue // never embed an empty track (ComputeEmbedding rejects empty input)
		}
		qualifying++
		emb, err := embed(exclusive[spk])
		if err != nil {
			return 0, 0, false, fmt.Errorf("diarmask: embed track %d: %w", spk, err)
		}
		c := cosineSimilarity(ref, emb)
		if c > bestCos {
			bestCos, bestIdx = c, spk
		}
	}
	if qualifying < 2 {
		return bestIdx, bestCos, false, nil
	}
	return bestIdx, bestCos, true, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./core/internal/speaker/ -run TestSelectTarget -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/speaker/diarmask.go core/internal/speaker/diarmask_test.go
git commit -m "feat(speaker): cosine target-track selection for diar_mask"
```

---

## Task 4: DiarMask orchestration, windowing, fallbacks, interfaces

**Files:**
- Modify: `core/internal/speaker/diarmask.go`
- Test: `core/internal/speaker/diarmask_test.go`

**Interfaces:**
- Consumes: Tasks 1–3 helpers; `cosineSimilarity`.
- Produces:
  - `type Segmenter interface { Segment(ctx context.Context, window []float32) (SpeakerActivity, error); Close() error }`
  - `type DiarMaskOptions struct { Segmenter Segmenter; Embed func([]float32) ([]float32, error); Reference []float32; MinSelectCosine float32; MinExclusiveSeconds float32; FallbackPassthrough bool; BoundaryRampMs int }`
  - `func NewDiarMask(opts DiarMaskOptions) (*DiarMask, error)`
  - `DiarMask` methods `Process`, `Name() (=="diar_mask")`, `OutputRate() (==0)`, `Close`, `LastSimilarity`.
- Later tasks rely on: the `Segmenter` interface (Task 5 implements it) and `NewDiarMask` (Task 6 constructs it).

- [ ] **Step 1: Write the failing test**

```go
// append to core/internal/speaker/diarmask_test.go
import "context"

// fakeSegmenter returns a scripted activity, ignoring audio content.
type fakeSegmenter struct {
	act SpeakerActivity
}

func (f *fakeSegmenter) Segment(_ context.Context, _ []float32) (SpeakerActivity, error) {
	return f.act, nil
}
func (f *fakeSegmenter) Close() error { return nil }

func newTestDiarMask(t *testing.T, seg Segmenter, embed func([]float32) ([]float32, error), fallback bool) *DiarMask {
	t.Helper()
	d, err := NewDiarMask(DiarMaskOptions{
		Segmenter:           seg,
		Embed:               embed,
		Reference:           []float32{1, 0},
		MinSelectCosine:     0.40,
		MinExclusiveSeconds: 0, // 0 → any non-empty exclusive audio qualifies
		FallbackPassthrough: fallback,
		// BoundaryRampMs unset → defaults to 15 ms; assertions below sample
		// run interiors, where gain is exactly 1 regardless of edge ramps.
	})
	if err != nil {
		t.Fatalf("NewDiarMask: %v", err)
	}
	return d
}

func TestDiarMask_MasksNonTargetFramesKeepsTarget(t *testing.T) {
	// hop = diarWindowLen / 4 so 4 frames cover a full 10 s window.
	hop := diarWindowLen / 4
	act := SpeakerActivity{
		Frames: [][]bool{
			{true, false, false},  // target only → keep
			{true, true, false},   // overlap → keep
			{false, true, false},  // interferer only → drop
			{false, false, false}, // silence → drop
		},
		FrameHopSamples: hop,
	}
	embed := func(s []float32) ([]float32, error) {
		// spk0 exclusive region is marked 0.5; spk1 region 0.9.
		if len(s) > 0 && s[0] == 0.5 {
			return []float32{1, 0}, nil
		}
		return []float32{0, 1}, nil
	}
	mixed := make([]float32, diarWindowLen)
	for i := 0; i < hop; i++ {
		mixed[i] = 0.5 // spk0 exclusive frame 0
	}
	for i := 2 * hop; i < 3*hop; i++ {
		mixed[i] = 0.9 // spk1 exclusive frame 2
	}
	d := newTestDiarMask(t, &fakeSegmenter{act: act}, embed, true)
	out, err := d.Process(context.Background(), mixed)
	if err != nil {
		t.Fatalf("Process: %v", err)
	}
	if len(out) != len(mixed) {
		t.Fatalf("len(out)=%d want %d", len(out), len(mixed))
	}
	// Sample run interiors (gain is exactly 1 inside an active run, 0 inside a
	// dropped run) so the assertions are robust to the default edge ramp.
	if out[hop/2] != 0.5 { // target frame kept verbatim
		t.Errorf("target sample dropped: out[%d]=%f want 0.5", hop/2, out[hop/2])
	}
	if out[2*hop+hop/2] != 0 { // interferer frame silenced
		t.Errorf("interferer sample kept: out[%d]=%f want 0", 2*hop+hop/2, out[2*hop+hop/2])
	}
	if got := d.LastSimilarity(); got < 0.99 {
		t.Errorf("LastSimilarity=%f want ~1.0", got)
	}
}

func TestDiarMask_SingleSpeakerPassesThrough(t *testing.T) {
	hop := diarWindowLen / 2
	act := SpeakerActivity{
		Frames:          [][]bool{{true, false, false}, {true, false, false}},
		FrameHopSamples: hop,
	}
	embed := func(s []float32) ([]float32, error) { return []float32{1, 0}, nil }
	mixed := make([]float32, diarWindowLen)
	for i := range mixed {
		mixed[i] = 0.3
	}
	d := newTestDiarMask(t, &fakeSegmenter{act: act}, embed, true)
	out, err := d.Process(context.Background(), mixed)
	if err != nil {
		t.Fatalf("Process: %v", err)
	}
	for i := range out {
		if out[i] != mixed[i] {
			t.Fatalf("single-speaker should pass through; out[%d]=%f", i, out[i])
		}
	}
}

func TestDiarMask_LowConfidenceFallbackPassthrough(t *testing.T) {
	hop := diarWindowLen / 4
	act := SpeakerActivity{
		Frames: [][]bool{
			{true, false, false}, {false, true, false},
			{true, false, false}, {false, true, false},
		},
		FrameHopSamples: hop,
	}
	// Both tracks orthogonal to ref → best cos ~0 < MinSelectCosine.
	embed := func(s []float32) ([]float32, error) { return []float32{0, 1}, nil }
	mixed := make([]float32, diarWindowLen)
	for i := range mixed {
		mixed[i] = 0.2
	}
	d := newTestDiarMask(t, &fakeSegmenter{act: act}, embed, true)
	out, err := d.Process(context.Background(), mixed)
	if err != nil {
		t.Fatalf("Process: %v", err)
	}
	for i := range out {
		if out[i] != mixed[i] {
			t.Fatalf("low-confidence should pass through; out[%d]=%f", i, out[i])
		}
	}
}

func TestDiarMask_InterfaceCompliance(t *testing.T) {
	d := newTestDiarMask(t, &fakeSegmenter{}, func(s []float32) ([]float32, error) { return []float32{1, 0}, nil }, true)
	if d.Name() != "diar_mask" {
		t.Errorf("Name()=%q want diar_mask", d.Name())
	}
	if d.OutputRate() != 0 {
		t.Errorf("OutputRate()=%d want 0", d.OutputRate())
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./core/internal/speaker/ -run TestDiarMask -v`
Expected: FAIL — `undefined: NewDiarMask` / `Segmenter` / `DiarMaskOptions`.

- [ ] **Step 3: Write minimal implementation**

```go
// append to core/internal/speaker/diarmask.go

// Segmenter produces per-frame local-speaker activity for ONE ≤10 s window of
// 16 kHz mono audio (implementations zero-pad short input to the model length).
// DiarMask owns windowing across longer buffers.
type Segmenter interface {
	Segment(ctx context.Context, window []float32) (SpeakerActivity, error)
	Close() error
}

// DiarMaskOptions configures NewDiarMask. See the design spec for semantics.
type DiarMaskOptions struct {
	Segmenter           Segmenter
	Embed               func([]float32) ([]float32, error) // embeds 16 kHz mono → L2-normalised vector
	Reference           []float32                          // enrolled L2-normalised embedding
	MinSelectCosine     float32                            // below → low-confidence passthrough (default 0.40)
	MinExclusiveSeconds float32                            // min exclusive speech to embed a track (default 0.75)
	FallbackPassthrough bool                               // default true; false → mask even when low-confidence
	BoundaryRampMs      int                                // raised-cosine ramp at mask edges (default 15)
}

// DiarMask is a Cleanup + audio.Stage that isolates the enrolled speaker by
// time-masking the original audio (no separation, no threshold gate).
type DiarMask struct {
	opts           DiarMaskOptions
	rampSamples    int
	minExclusive   int
	lastSimilarity float32
}

// NewDiarMask validates options and applies defaults.
func NewDiarMask(opts DiarMaskOptions) (*DiarMask, error) {
	if opts.Segmenter == nil {
		return nil, fmt.Errorf("diarmask: nil Segmenter")
	}
	if opts.Embed == nil {
		return nil, fmt.Errorf("diarmask: nil Embed")
	}
	if len(opts.Reference) == 0 {
		return nil, fmt.Errorf("diarmask: empty Reference")
	}
	if opts.MinSelectCosine == 0 {
		opts.MinSelectCosine = 0.40
	}
	if opts.BoundaryRampMs == 0 {
		opts.BoundaryRampMs = 15
	}
	return &DiarMask{
		opts:           opts,
		rampSamples:    opts.BoundaryRampMs * diarSampleRate / 1000,
		minExclusive:   int(opts.MinExclusiveSeconds * float32(diarSampleRate)),
		lastSimilarity: 1.0,
	}, nil
}

func (d *DiarMask) Name() string    { return "diar_mask" }
func (d *DiarMask) OutputRate() int { return 0 }

// LastSimilarity returns the best target-track cosine observed in the last
// Process call (1.0 when every window passed through).
func (d *DiarMask) LastSimilarity() float32 {
	if d == nil {
		return 0
	}
	return d.lastSimilarity
}

// Close releases the segmenter.
func (d *DiarMask) Close() error {
	if d == nil || d.opts.Segmenter == nil {
		return nil
	}
	return d.opts.Segmenter.Close()
}

// Process masks the enrolled speaker's audio out of mixed. Returns same-length
// 16 kHz mono. Windows of diarWindowLen are processed independently; per-window
// masks are concatenated.
func (d *DiarMask) Process(ctx context.Context, mixed []float32) ([]float32, error) {
	gain := make([]float32, len(mixed))
	bestCos := float32(-2)
	sawSelection := false
	for start := 0; start < len(mixed); start += diarWindowLen {
		end := start + diarWindowLen
		if end > len(mixed) {
			end = len(mixed)
		}
		window := mixed[start:end]
		winGain, cos, selected, err := d.processWindow(ctx, window)
		if err != nil {
			return nil, err
		}
		copy(gain[start:end], winGain)
		if selected {
			sawSelection = true
			if cos > bestCos {
				bestCos = cos
			}
		}
	}
	if sawSelection {
		d.lastSimilarity = bestCos
	} else {
		d.lastSimilarity = 1.0
	}
	return applyMask(mixed, gain), nil
}

// processWindow returns the gain curve for one window plus the selection cosine
// (selected=false → all-ones passthrough gain).
func (d *DiarMask) processWindow(ctx context.Context, window []float32) ([]float32, float32, bool, error) {
	passthrough := func() []float32 {
		g := make([]float32, len(window))
		for i := range g {
			g[i] = 1
		}
		return g
	}
	act, err := d.opts.Segmenter.Segment(ctx, window)
	if err != nil {
		return nil, 0, false, fmt.Errorf("diarmask: segment: %w", err)
	}
	idx, cos, ok, err := selectTarget(act, window, d.opts.Embed, d.opts.Reference, d.minExclusive)
	if err != nil {
		return nil, 0, false, err
	}
	// Single-track (or nothing qualifies) → keep everything.
	if !ok || idx < 0 {
		return passthrough(), 0, false, nil
	}
	// Low-confidence → keep everything when fallback is on.
	if cos < d.opts.MinSelectCosine && d.opts.FallbackPassthrough {
		return passthrough(), cos, false, nil
	}
	frameMask := buildFrameMask(act, idx)
	g := frameMaskToSamples(frameMask, act.FrameHopSamples, len(window), d.rampSamples)
	return g, cos, true, nil
}

// Compile-time interface checks.
var _ Cleanup = (*DiarMask)(nil)
var _ audio.Stage = (*DiarMask)(nil)
```

Update the import block in `diarmask.go` to add `"context"` (first used here, by the `Segmenter` interface and the `Process`/`processWindow` signatures) and `"github.com/voice-keyboard/core/internal/audio"` (for the `audio.Stage` compile-time check). After this task the block is: `"context"`, `"fmt"`, `"math"`, `"github.com/voice-keyboard/core/internal/audio"`.

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./core/internal/speaker/ -run TestDiarMask -v`
Expected: PASS (all four subtests).

- [ ] **Step 5: Run the whole package to confirm no regressions**

Run: `go test ./core/internal/speaker/`
Expected: PASS (existing tests unaffected; new logic tests green).

- [ ] **Step 6: Commit**

```bash
git add core/internal/speaker/diarmask.go core/internal/speaker/diarmask_test.go
git commit -m "feat(speaker): DiarMask orchestration, windowing, fallbacks, interfaces"
```

---

## Task 5: pyannote ONNX segmenter

**Files:**
- Create: `core/internal/speaker/diarmask_pyannote.go`
- Modify: `core/internal/speaker/diarmask_test.go` (skip-clean smoke test)

**Interfaces:**
- Consumes: `Segmenter`, `SpeakerActivity`, `powersetToActivity` (Tasks 1, 4); ORT (`DynamicAdvancedSession.Run` with nil-output auto-alloc).
- Produces: `func NewPyannoteSegmenter(modelPath string) (*pyannoteSegmenter, error)`; `pyannoteSegmenter` implements `Segmenter`. Model I/O names: input `"waveform"` shape `[1,1,160000]`, output `"segmentation"` shape `[1, frames, 7]` (as produced by `BUILDING_PYANNOTE_SEG.md`).

- [ ] **Step 1: Write the failing test (skips cleanly without the model)**

```go
// append to core/internal/speaker/diarmask_test.go

func TestPyannoteSegmenter_RealModelSmoke(t *testing.T) {
	modelPath := resolveModelPath(t, "PYANNOTE_SEG_PATH", "pyannote_seg.onnx") // t.Skip if absent
	initONNXOnce(t)
	seg, err := NewPyannoteSegmenter(modelPath)
	if err != nil {
		t.Fatalf("NewPyannoteSegmenter: %v", err)
	}
	defer seg.Close()
	// 10 s of low-level noise; we only assert shape sanity, not labels.
	window := make([]float32, diarWindowLen)
	for i := range window {
		window[i] = float32((i%7))*0.001 - 0.003
	}
	act, err := seg.Segment(context.Background(), window)
	if err != nil {
		t.Fatalf("Segment: %v", err)
	}
	if len(act.Frames) == 0 {
		t.Errorf("no frames returned")
	}
	if act.FrameHopSamples <= 0 {
		t.Errorf("FrameHopSamples=%d, want > 0", act.FrameHopSamples)
	}
	for _, fr := range act.Frames {
		if len(fr) != diarMaxSpeakers {
			t.Fatalf("frame has %d speakers, want %d", len(fr), diarMaxSpeakers)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails (or skips, then fails to compile)**

Run: `go test ./core/internal/speaker/ -run TestPyannoteSegmenter_RealModelSmoke -v`
Expected: FAIL to compile — `undefined: NewPyannoteSegmenter`. (Once implemented, it SKIPs when `PYANNOTE_SEG_PATH` is unset.)

- [ ] **Step 3: Write minimal implementation**

```go
// core/internal/speaker/diarmask_pyannote.go
package speaker

import (
	"context"
	"fmt"

	ort "github.com/yalue/onnxruntime_go"
)

// pyannoteSegmenter runs pyannote/segmentation-3.0 (ONNX) over a single 10 s
// window and decodes its powerset output into SpeakerActivity.
type pyannoteSegmenter struct {
	session *ort.DynamicAdvancedSession
}

// NewPyannoteSegmenter loads the segmentation ONNX. Call InitONNXRuntime first.
// The model must expose input "waveform" [1,1,160000] and output
// "segmentation" [1, frames, 7] (see core/BUILDING_PYANNOTE_SEG.md).
func NewPyannoteSegmenter(modelPath string) (*pyannoteSegmenter, error) {
	sess, err := ort.NewDynamicAdvancedSession(
		modelPath,
		[]string{"waveform"},
		[]string{"segmentation"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("pyannote_seg: load %q: %w", modelPath, err)
	}
	return &pyannoteSegmenter{session: sess}, nil
}

// Segment zero-pads window to 10 s, runs the model, and decodes the powerset
// output. The output frame count is read from the (auto-allocated) tensor
// shape, so no frame count is hardcoded.
func (s *pyannoteSegmenter) Segment(_ context.Context, window []float32) (SpeakerActivity, error) {
	buf := window
	if len(buf) < diarWindowLen {
		buf = make([]float32, diarWindowLen)
		copy(buf, window)
	} else if len(buf) > diarWindowLen {
		buf = buf[:diarWindowLen]
	}
	inT, err := ort.NewTensor(ort.NewShape(1, 1, int64(diarWindowLen)), buf)
	if err != nil {
		return SpeakerActivity{}, fmt.Errorf("pyannote_seg: input tensor: %w", err)
	}
	defer inT.Destroy()

	outputs := []ort.Value{nil} // ORT allocates the dynamic [1, frames, 7] output
	if err := s.session.Run([]ort.Value{inT}, outputs); err != nil {
		return SpeakerActivity{}, fmt.Errorf("pyannote_seg: inference: %w", err)
	}
	outT, ok := outputs[0].(*ort.Tensor[float32])
	if !ok {
		return SpeakerActivity{}, fmt.Errorf("pyannote_seg: unexpected output type %T", outputs[0])
	}
	defer outT.Destroy()

	shape := outT.GetShape()
	numFrames := 1
	for _, dPart := range shape[:len(shape)-1] {
		numFrames *= int(dPart)
	}
	if numFrames <= 0 {
		return SpeakerActivity{}, fmt.Errorf("pyannote_seg: bad output shape %v", shape)
	}
	hop := diarWindowLen / numFrames
	return powersetToActivity(outT.GetData(), shape, hop)
}

func (s *pyannoteSegmenter) Close() error {
	if s.session == nil {
		return nil
	}
	err := s.session.Destroy()
	s.session = nil
	return err
}

// Compile-time interface check.
var _ Segmenter = (*pyannoteSegmenter)(nil)
```

- [ ] **Step 4: Run test to verify it builds + skips (no model) or passes (model present)**

Run: `go test ./core/internal/speaker/ -run TestPyannoteSegmenter_RealModelSmoke -v`
Expected: `--- SKIP` when `PYANNOTE_SEG_PATH` unset and no `build/models/pyannote_seg.onnx`; PASS when the model is present.

- [ ] **Step 5: Confirm `ort.Tensor`'s `GetShape`/`GetData` usage compiles against v1.29.0**

Run: `go build ./core/internal/speaker/`
Expected: builds cleanly.

- [ ] **Step 6: Commit**

```bash
git add core/internal/speaker/diarmask_pyannote.go core/internal/speaker/diarmask_test.go
git commit -m "feat(speaker): pyannote/segmentation-3.0 ONNX segmenter for diar_mask"
```

---

## Task 6: Harness wiring + target self-retention metric

**Files:**
- Modify: `core/internal/speaker/cleanup_eval_test.go`
- Test: same file (the matrix test is the test).

**Interfaces:**
- Consumes: `NewDiarMask`, `NewPyannoteSegmenter`, `ComputeEmbedding`, `cosineSimilarity` (earlier tasks + existing).
- Produces: a `diar_mask` row in `TestCleanup_Matrix` and a `retention` column. `func evaluateRetention(out, cleanTarget []float32) float32`.

- [ ] **Step 1: Write the failing test (retention evaluator unit test)**

```go
// append to core/internal/speaker/cleanup_eval_test.go (same build tags as the file)

func TestEvaluateRetention_FullKeepIsOne(t *testing.T) {
	target := []float32{0, 0.5, 0, 0.7, 0, 0.3}
	// out == cleanTarget over its voiced samples → retention ~1.0
	got := evaluateRetention(target, target)
	if got < 0.99 || got > 1.01 {
		t.Errorf("retention=%f want ~1.0", got)
	}
}

func TestEvaluateRetention_SilencedTargetIsZero(t *testing.T) {
	target := []float32{0, 0.5, 0, 0.7, 0, 0.3}
	out := make([]float32, len(target)) // everything cut
	got := evaluateRetention(out, target)
	if got > 0.01 {
		t.Errorf("retention=%f want ~0.0", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test -tags 'cleanupeval whispercpp' ./core/internal/speaker/ -run TestEvaluateRetention -v`
Expected: FAIL — `undefined: evaluateRetention`.

- [ ] **Step 3: Implement the retention evaluator**

```go
// add to cleanup_eval_test.go

// evaluateRetention measures how much of the clean target's own speech energy
// survives in out. 1.0 = nothing of the target was cut; 0.0 = target silenced.
// Only frames where the clean target is voiced count, so interferer-only
// regions don't dilute the score.
func evaluateRetention(out, cleanTarget []float32) float32 {
	n := len(out)
	if len(cleanTarget) < n {
		n = len(cleanTarget)
	}
	if n == 0 {
		return 0
	}
	// Voiced threshold: 10% of the clean target's global RMS.
	thr := rms(cleanTarget[:n]) * 0.1
	var num, den float64
	const frame = 320 // 20 ms @ 16 kHz
	for start := 0; start < n; start += frame {
		end := start + frame
		if end > n {
			end = n
		}
		seg := cleanTarget[start:end]
		if rms(seg) < thr {
			continue // unvoiced target frame — skip
		}
		for i := start; i < end; i++ {
			den += float64(cleanTarget[i]) * float64(cleanTarget[i])
			num += float64(out[i]) * float64(out[i])
		}
	}
	if den == 0 {
		return 0
	}
	r := num / den
	if r < 0 {
		r = 0
	}
	return float32(math.Sqrt(r))
}
```

Add `"math"` to the import block of `cleanup_eval_test.go` (it is not currently imported).

- [ ] **Step 4: Register the `diar_mask` adapter and thread the clean target + retention column**

In `cleanupAdapters` (cleanup_eval_test.go:42), add a fourth factory. Because `DiarMask` needs an encoder-path-bound embedder and the pyannote model path, extend the factory inputs:

```go
// change the signature of cleanupAdapters to accept the seg path:
func cleanupAdapters(encoderPath, tsePath, pyannotePath, pyannoteSegPath string) []adapterFactory {
	return []adapterFactory{
		// ... existing passthrough, speakergate, pyannote_sep_ecapa ...
		{
			name: "diar_mask",
			build: func(t *testing.T, ref []float32, encPath string) Cleanup {
				if pyannoteSegPath == "" {
					return nil
				}
				seg, err := NewPyannoteSegmenter(pyannoteSegPath)
				if err != nil {
					t.Logf("diar_mask segmenter unavailable: %v", err)
					return nil
				}
				d, err := NewDiarMask(DiarMaskOptions{
					Segmenter: seg,
					Embed: func(s []float32) ([]float32, error) {
						return ComputeEmbedding(encPath, s, 192)
					},
					Reference:           ref,
					MinSelectCosine:     0.40,
					MinExclusiveSeconds: 0.75,
					FallbackPassthrough: true,
					BoundaryRampMs:      15,
				})
				if err != nil {
					t.Logf("diar_mask unavailable: %v", err)
					_ = seg.Close()
					return nil
				}
				return d
			},
		},
	}
}
```

Update the two call sites: in `TestCleanup_Matrix`, resolve the seg path and pass it; in `runMatrixForFixture`, accept it and forward to `cleanupAdapters`; thread the clean target clip (`a.Samples`) and the retention value into `rowLogger`.

```go
// TestCleanup_Matrix: add
pyannoteSegPath := optionalModelPath("PYANNOTE_SEG_PATH", "pyannote_seg.onnx")
// ...
runMatrixForFixture(t, fix, noise.Samples, encoderPath, tsePath, pyannotePath, pyannoteSegPath, transcriber)

// runMatrixForFixture: add pyannoteSegPath param; pass to cleanupAdapters;
// pass a.Samples (clean target) into rowLogger.
adapters := cleanupAdapters(encoderPath, tsePath, pyannotePath, pyannoteSegPath)
// ...
rowLogger(t, fac.name, cnd.label, adapter, mixed, a.Samples, embA, embB, transcriptA, encoderPath, transcriber)

// rowLogger: add cleanTarget []float32 param after mixed; compute + log retention.
retention := evaluateRetention(out, cleanTarget)
// extend the header and the row format with a "reten" column, e.g.:
t.Logf("%-20s | %-30s | %7.4f | %7.4f | %+7.4f | %6.3f | %6.3f | %6.2f | hyp=%q",
	name, condLabel, simT, simI, margin, rmsRatio, retention, werRes.WER*100, werRes.Hypothesis)
```

Also add the `reten` column to the two header `t.Logf` lines in `runMatrixForFixture` (cleanup_eval_test.go:172-174).

- [ ] **Step 5: Run the matrix build + retention unit tests**

Run: `go test -tags 'cleanupeval whispercpp' ./core/internal/speaker/ -run 'TestEvaluateRetention' -v`
Expected: PASS.

Run (compile + skip-clean without models): `go vet -tags 'cleanupeval whispercpp' ./core/internal/speaker/`
Expected: no errors. With models absent, `TestCleanup_Matrix`'s `diar_mask` row logs "skipped (model unavailable)".

- [ ] **Step 6: Commit**

```bash
git add core/internal/speaker/cleanup_eval_test.go
git commit -m "test(speaker): wire diar_mask into cleanup matrix + self-retention metric"
```

---

## Task 7: pyannote-seg ONNX export doc

**Files:**
- Create: `core/BUILDING_PYANNOTE_SEG.md`

**Interfaces:** none (documentation). Mirrors `core/BUILDING_PYANNOTE_SEP.md` so a contributor can produce `pyannote_seg.onnx` with input `waveform` `[1,1,160000]` and output `segmentation` `[1,frames,7]`, matching Task 5's session I/O names.

- [ ] **Step 1: Write the doc**

```markdown
# Building pyannote-seg ONNX

The `pyannoteSegmenter` (diar_mask) expects an ONNX export of
`pyannote/segmentation-3.0` at the path passed via `PYANNOTE_SEG_PATH`.
Day-to-day contributors don't need this — `diar_mask` `t.Skip`s without it.

## Prerequisites
- Python 3.10+
- HuggingFace token with access to `pyannote/segmentation-3.0` (gated; accept the EULA)
- `pip install pyannote.audio onnx onnxruntime torch torchaudio`

## Export script

Save as `scripts/export-pyannote-seg.py`:

```python
"""Export pyannote/segmentation-3.0 to ONNX.

Output names + shapes MUST match core/internal/speaker/diarmask_pyannote.go:
  input  "waveform"     [1, 1, 160000]   (10 s @ 16 kHz mono)
  output "segmentation" [1, num_frames, 7]  (powerset, 7 classes)
"""
import os, torch
from pyannote.audio import Model

model = Model.from_pretrained("pyannote/segmentation-3.0",
                              use_auth_token=os.environ["HF_TOKEN"])
model.eval()

dummy = torch.zeros(1, 1, 160000)
torch.onnx.export(
    model, dummy, "pyannote_seg.onnx",
    input_names=["waveform"], output_names=["segmentation"],
    dynamic_axes={"segmentation": {1: "num_frames"}},
    opset_version=17,
)
print("wrote pyannote_seg.onnx")
```

## Verify

The 7 output classes are, in order: non-speech, spk1, spk2, spk3, spk1+2,
spk1+3, spk2+3 (max 2 simultaneous speakers). `powersetToActivity` in
`diarmask.go` depends on this exact ordering — re-check it on any model upgrade.

## Place the model

Drop `pyannote_seg.onnx` at `core/build/models/pyannote_seg.onnx` or point
`PYANNOTE_SEG_PATH` at it, then run:

    PYANNOTE_SEG_PATH=/path/to/pyannote_seg.onnx \
    SPEAKER_ENCODER_PATH=/path/to/speaker_encoder.onnx \
    WHISPER_MODEL_PATH=/path/to/ggml-small.bin \
    go test -tags 'cleanupeval whispercpp' ./core/internal/speaker/ -run TestCleanup_Matrix -v
```

- [ ] **Step 2: Commit**

```bash
git add core/BUILDING_PYANNOTE_SEG.md
git commit -m "docs(speaker): pyannote-seg ONNX export recipe for diar_mask"
```

---

## Final verification

- [ ] **Run the always-on unit tests:**

Run: `go test ./core/internal/speaker/`
Expected: PASS (decode, mask, select, orchestration, fallbacks all green; existing tests unaffected).

- [ ] **Build the harness target:**

Run: `go vet -tags 'cleanupeval whispercpp' ./core/internal/speaker/`
Expected: no errors.

- [ ] **(If models available) Run the comparison matrix and record numbers:**

Run with `PYANNOTE_SEG_PATH`, `SPEAKER_ENCODER_PATH`, `WHISPER_MODEL_PATH`, `TSE_MODEL_PATH` set:
`go test -tags 'cleanupeval whispercpp' ./core/internal/speaker/ -run TestCleanup_Matrix -v`
Expected: a `diar_mask` row with `simT/simI/margin/RMSr/reten/WER%`. Record actual numbers (dated) under "Calibration policy" in the design spec, then refine `MinSelectCosine` / thresholds per that section.

---

## Self-Review

**Spec coverage:** Component + interfaces (Tasks 1–5) ✓; mask-not-separate algorithm (Tasks 2,4) ✓; cosine-as-selector (Task 3) ✓; whole-utterance windowing, no global clustering (Task 4) ✓; guardrails — inclusion bias (Task 2), single-track + low-confidence passthrough toggle (Task 4) ✓; pyannote segmenter + dynamic output (Task 5) ✓; harness wiring + self-retention metric (Task 6) ✓; export doc (Task 7) ✓; harness-only scope, no live wiring ✓.

**Placeholder scan:** All code blocks are concrete; the one shim (`mathSqrt`) carries an explicit instruction to prefer `math.Sqrt`. No TBD/TODO.

**Type consistency:** `SpeakerActivity{Frames, FrameHopSamples}`, `Segmenter.Segment(ctx, window)`, `selectTarget(...) (int, float32, bool, error)`, `DiarMaskOptions` field names, `NewDiarMask`, `NewPyannoteSegmenter`, and the harness `evaluateRetention`/`cleanupAdapters` signature are used identically across tasks.
