# Speaker TSE Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Target Speaker Extraction to the Go pipeline so voice dictation works reliably when other people are talking nearby, using SpeakerBeam-SS via ONNX Runtime and Silero VAD to replace the RMS threshold in the chunker.

**Architecture:** A new `core/internal/speaker/` package provides `VAD` and `TSEExtractor` interfaces. `SileroVAD` replaces the RMS threshold in the chunker; `SpeakerBeamSS` sits between the chunker and Whisper in `pipeline.Run`, extracting only the enrolled user's voice. Enrollment records a WAV clip once via `enroll.sh`; the WAV is passed as reference audio to the TSE model on every chunk.

**Tech Stack:** Go 1.26, `github.com/yalue/onnxruntime_go` (ONNX Runtime CGo bindings), `github.com/gen2brain/malgo` (already in go.mod), ONNX Runtime C library (Homebrew), Python 3.10+ with PyTorch + asteroid-filterbanks (build-time model export only).

---

## File Map

| Status | Path | Responsibility |
|---|---|---|
| Create | `core/internal/speaker/vad.go` | `VAD` interface + `SileroVAD` ONNX implementation |
| Create | `core/internal/speaker/vad_test.go` | Unit + integration tests (build tag `silero` for model-dependent tests) |
| Create | `core/internal/speaker/tse.go` | `TSEExtractor` interface |
| Create | `core/internal/speaker/speakerbeam.go` | `SpeakerBeamSS`: ONNX inference wrapper |
| Create | `core/internal/speaker/speakerbeam_test.go` | Build tag `speakerbeam` |
| Create | `core/internal/speaker/store.go` | `speaker.json` + `enrollment.wav` read/write |
| Create | `core/internal/speaker/store_test.go` | Round-trip tests, no model needed |
| Create | `core/internal/speaker/enroller.go` | Records mic audio, saves WAV + profile |
| Create | `core/internal/speaker/enroller_test.go` | Synthesized input, no mic |
| Create | `core/cmd/enroll/main.go` | `vkb-enroll` CLI binary |
| Create | `scripts/export_tse_model.py` | PyTorch → ONNX export (dev tool, not shipped) |
| Create | `enroll.sh` | Downloads models, builds + runs `vkb-enroll` |
| Create | `run-speaker.sh` | Like `run-streaming.sh` with TSE enabled |
| Modify | `core/go.mod` | Add `github.com/yalue/onnxruntime_go` |
| Modify | `core/internal/pipeline/chunker.go` | Add `VAD` field to `ChunkerOpts`, nil → RMS fallback |
| Modify | `core/internal/pipeline/chunker_test.go` | Add `fakeVAD` test |
| Modify | `core/internal/pipeline/pipeline.go` | Add `TSE` field, load `enrollment.wav`, apply TSE gate |
| Modify | `core/internal/pipeline/pipeline_test.go` | Add TSE nil/active/empty-output tests |

---

## Task 0: Worktree + Prerequisites

**Files:** none (shell only)

- [ ] **Step 1: Create the worktree**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard
git worktree add ../voice-keyboard-speaker-tse -b feat/speaker-tse main
cd ../voice-keyboard-speaker-tse
```

- [ ] **Step 2: Install ONNX Runtime (macOS)**

```bash
brew install onnxruntime
# Verify the shared library exists:
ls /opt/homebrew/lib/libonnxruntime.dylib
```

Expected: file listed without error. If Homebrew installs to a different prefix (Intel Mac), the path is `/usr/local/lib/libonnxruntime.dylib`. Note the actual path — it goes into `enroll.sh` and `run-speaker.sh` later.

- [ ] **Step 3: Verify Go toolchain**

```bash
cd core && go version
```

Expected: `go version go1.26.x ...`

---

## Task 1: Package Skeleton + `onnxruntime_go` Dependency

**Files:**
- Create: `core/internal/speaker/tse.go`
- Create: `core/internal/speaker/vad.go` (interfaces only for now)
- Modify: `core/go.mod`

- [ ] **Step 1: Add the dependency**

```bash
cd core
go get github.com/yalue/onnxruntime_go@latest
```

- [ ] **Step 2: Create `core/internal/speaker/tse.go`**

```go
package speaker

import "context"

// TSEExtractor extracts the target speaker's audio from a mixed signal.
// mixed: 16kHz mono PCM samples from the chunker.
// ref:   enrollment audio (16kHz mono PCM), loaded once from enrollment.wav.
// Returns clean audio of the same length as mixed.
type TSEExtractor interface {
	Extract(ctx context.Context, mixed []float32, ref []float32) ([]float32, error)
}
```

- [ ] **Step 3: Create `core/internal/speaker/vad.go` with interface only**

```go
package speaker

// VAD reports whether a 100ms window of 16kHz mono samples contains voiced speech.
type VAD interface {
	IsVoiced(samples []float32) bool
}
```

- [ ] **Step 4: Verify the package compiles**

```bash
cd core && go build ./internal/speaker/...
```

Expected: no output (success).

- [ ] **Step 5: Commit**

```bash
git add core/go.mod core/go.sum core/internal/speaker/
git commit -m "feat(speaker): package skeleton + onnxruntime_go dep"
```

---

## Task 2: SileroVAD

**Files:**
- Modify: `core/internal/speaker/vad.go`
- Create: `core/internal/speaker/vad_test.go`

The Silero VAD v5 ONNX model inputs: `"input"` float32[1,N], `"sr"` int64[1], `"h"` float32[2,1,64], `"c"` float32[2,1,64]. Outputs: `"output"` float32[1] (speech probability), `"hn"` float32[2,1,64], `"cn"` float32[2,1,64]. State tensors carry RNN memory across calls — reset on each new `Pipeline.Run` by constructing a new `SileroVAD`.

- [ ] **Step 1: Write the failing interface-compliance test**

Create `core/internal/speaker/vad_test.go`:

```go
package speaker

import (
	"testing"
)

// fakeVAD satisfies the VAD interface for tests.
type fakeVAD struct{ voiced bool }

func (f *fakeVAD) IsVoiced(_ []float32) bool { return f.voiced }

func TestFakeVAD_ImplementsInterface(t *testing.T) {
	var _ VAD = &fakeVAD{}
}

func TestFakeVAD_ReturnsConfiguredValue(t *testing.T) {
	v := &fakeVAD{voiced: true}
	if !v.IsVoiced(nil) {
		t.Fatalf("expected IsVoiced true")
	}
	v.voiced = false
	if v.IsVoiced(nil) {
		t.Fatalf("expected IsVoiced false")
	}
}
```

- [ ] **Step 2: Run test to verify it passes (no model needed)**

```bash
cd core && go test ./internal/speaker/ -run TestFakeVAD -v
```

Expected: PASS.

- [ ] **Step 3: Implement `SileroVAD` in `core/internal/speaker/vad.go`**

Replace the file contents with:

```go
package speaker

import (
	"fmt"

	ort "github.com/yalue/onnxruntime_go"
)

// VAD reports whether a 100ms window of 16kHz mono samples contains voiced speech.
type VAD interface {
	IsVoiced(samples []float32) bool
}

const (
	sileroSampleRate  = 16000
	sileroStateDepth  = 2
	sileroStateBatch  = 1
	sileroStateSize   = 64
	sileroThreshold   = float32(0.5)
)

// SileroVAD implements VAD using silero_vad.onnx.
// Construct a new instance per Pipeline.Run — the RNN state resets on construction.
type SileroVAD struct {
	session *ort.DynamicAdvancedSession
	h       []float32 // shape [2,1,64] flattened — RNN hidden state
	c       []float32 // shape [2,1,64] flattened — RNN cell state
}

// InitONNXRuntime must be called once at program startup before any ONNX model is loaded.
// libPath is the path to libonnxruntime.dylib (e.g. /opt/homebrew/lib/libonnxruntime.dylib).
func InitONNXRuntime(libPath string) error {
	ort.SetSharedLibraryPath(libPath)
	return ort.InitializeEnvironment()
}

// NewSileroVAD loads the Silero VAD ONNX model from modelPath.
func NewSileroVAD(modelPath string) (*SileroVAD, error) {
	session, err := ort.NewDynamicAdvancedSession(
		modelPath,
		[]string{"input", "sr", "h", "c"},
		[]string{"output", "hn", "cn"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("silero vad: load %q: %w", modelPath, err)
	}
	stateLen := sileroStateDepth * sileroStateBatch * sileroStateSize
	return &SileroVAD{
		session: session,
		h:       make([]float32, stateLen),
		c:       make([]float32, stateLen),
	}, nil
}

// IsVoiced returns true when samples contain voiced speech (probability > 0.5).
// Updates internal RNN state — not safe for concurrent calls.
func (v *SileroVAD) IsVoiced(samples []float32) bool {
	inputT, err := ort.NewTensor(ort.NewShape(1, int64(len(samples))), samples)
	if err != nil {
		return false
	}
	defer inputT.Destroy()

	srT, err := ort.NewTensor(ort.NewShape(1), []int64{int64(sileroSampleRate)})
	if err != nil {
		return false
	}
	defer srT.Destroy()

	hT, err := ort.NewTensor(ort.NewShape(sileroStateDepth, sileroStateBatch, sileroStateSize), v.h)
	if err != nil {
		return false
	}
	defer hT.Destroy()

	cT, err := ort.NewTensor(ort.NewShape(sileroStateDepth, sileroStateBatch, sileroStateSize), v.c)
	if err != nil {
		return false
	}
	defer cT.Destroy()

	outT, err := ort.NewEmptyTensor[float32](ort.NewShape(1))
	if err != nil {
		return false
	}
	defer outT.Destroy()

	hnT, err := ort.NewEmptyTensor[float32](ort.NewShape(sileroStateDepth, sileroStateBatch, sileroStateSize))
	if err != nil {
		return false
	}
	defer hnT.Destroy()

	cnT, err := ort.NewEmptyTensor[float32](ort.NewShape(sileroStateDepth, sileroStateBatch, sileroStateSize))
	if err != nil {
		return false
	}
	defer cnT.Destroy()

	if err := v.session.Run(
		[]ort.Value{inputT, srT, hT, cT},
		[]ort.Value{outT, hnT, cnT},
	); err != nil {
		return false
	}

	prob := outT.GetData()[0]
	copy(v.h, hnT.GetData())
	copy(v.c, cnT.GetData())
	return prob > sileroThreshold
}

// Close releases the ONNX session.
func (v *SileroVAD) Close() error {
	return v.session.Destroy()
}
```

- [ ] **Step 4: Verify compilation**

```bash
cd core && go build ./internal/speaker/...
```

Expected: no output.

- [ ] **Step 5: Add model-gated integration test to `vad_test.go`**

Append to `core/internal/speaker/vad_test.go`:

```go
//go:build silero

package speaker

import (
	"os"
	"testing"
)

func TestSileroVAD_VoicedOnTone(t *testing.T) {
	libPath := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if libPath == "" {
		libPath = "/opt/homebrew/lib/libonnxruntime.dylib"
	}
	if err := InitONNXRuntime(libPath); err != nil {
		t.Fatalf("InitONNXRuntime: %v", err)
	}
	modelPath := os.Getenv("SILERO_MODEL_PATH")
	if modelPath == "" {
		t.Skip("SILERO_MODEL_PATH not set")
	}
	vad, err := NewSileroVAD(modelPath)
	if err != nil {
		t.Fatalf("NewSileroVAD: %v", err)
	}
	defer vad.Close()

	// 1600 samples of 440Hz sine at 16kHz (100ms window, above threshold)
	tone := make([]float32, 1600)
	for i := range tone {
		tone[i] = 0.3 * float32(math.Sin(2*math.Pi*440*float64(i)/16000))
	}
	if !vad.IsVoiced(tone) {
		t.Error("expected IsVoiced true for tone, got false")
	}

	// 1600 samples of silence
	silence := make([]float32, 1600)
	if vad.IsVoiced(silence) {
		t.Error("expected IsVoiced false for silence, got true")
	}
}
```

- [ ] **Step 6: Commit**

```bash
git add core/internal/speaker/vad.go core/internal/speaker/vad_test.go
git commit -m "feat(speaker): SileroVAD ONNX implementation"
```

---

## Task 3: Chunker VAD Integration

**Files:**
- Modify: `core/internal/pipeline/chunker.go`
- Modify: `core/internal/pipeline/chunker_test.go`

- [ ] **Step 1: Write the failing test**

Add to `core/internal/pipeline/chunker_test.go`:

```go
func TestChunker_UsesVADWhenSet(t *testing.T) {
	// fakeVAD returns voiced=true only for the first 8 calls (800ms),
	// then false — simulating one utterance followed by silence.
	type fakeVAD struct{ calls int }
	callsVoiced := 8
	vad := &fakeVAD{}
	isVoiced := func(_ []float32) bool {
		vad.calls++
		return vad.calls <= callsVoiced
	}

	var emitted []ChunkEmission
	opts := ChunkerOpts{
		VAD:            vadFunc(isVoiced),
		SilenceHangMs:  100,
		MaxChunkMs:     12_000,
		ForceCutScanMs: 100,
	}
	c := NewChunker(opts, func(e ChunkEmission) { emitted = append(emitted, e) })

	// Push 16 windows of 1600 samples each (all at amplitude 0.1 to ensure
	// RMS would pass the default threshold — we're testing that VAD overrides it).
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
	// The chunk should contain 8 voiced windows + 1 silence window (hang absorbs it)
	wantSamples := 9 * 1600
	if len(emitted[0].Samples) != wantSamples {
		t.Errorf("chunk samples = %d, want %d", len(emitted[0].Samples), wantSamples)
	}
}

// vadFunc wraps a function as a VAD — lets tests avoid importing the speaker package.
type vadFunc func([]float32) bool

func (f vadFunc) IsVoiced(s []float32) bool { return f(s) }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd core && go test ./internal/pipeline/ -run TestChunker_UsesVADWhenSet -v
```

Expected: compile error — `ChunkerOpts` has no `VAD` field, `vadFunc` type not found.

- [ ] **Step 3: Add `VAD` field to `ChunkerOpts` in `chunker.go`**

At the top of `chunker.go`, add the import:

```go
import (
	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/speaker"
)
```

Change `ChunkerOpts` to:

```go
type ChunkerOpts struct {
	// VAD, when non-nil, replaces the RMS threshold for voiced/silence decisions.
	VAD            speaker.VAD
	VoiceThreshold float32 // used only when VAD is nil
	SilenceHangMs  int
	MaxChunkMs     int
	ForceCutScanMs int
}
```

In `processWindow`, replace:

```go
rms := audio.RMS(w)
voiced := rms > c.opts.VoiceThreshold
```

with:

```go
var voiced bool
if c.opts.VAD != nil {
	voiced = c.opts.VAD.IsVoiced(w)
} else {
	voiced = audio.RMS(w) > c.opts.VoiceThreshold
}
```

- [ ] **Step 4: Add `vadFunc` type to `chunker_test.go`**

The `vadFunc` type defined in Step 1 goes in `chunker_test.go`. It lives in `package pipeline` (same package as the chunker tests), so it doesn't import the speaker package — it just satisfies the `speaker.VAD` interface by duck typing.

Add at the top of `chunker_test.go` (inside the `package pipeline` block, not in the new test function):

```go
// vadFunc wraps a plain function as a speaker.VAD — avoids importing speaker in tests.
type vadFunc func([]float32) bool

func (f vadFunc) IsVoiced(s []float32) bool { return f(s) }
```

- [ ] **Step 5: Run all chunker tests**

```bash
cd core && go test ./internal/pipeline/ -run TestChunker -v
```

Expected: all PASS including the new test.

- [ ] **Step 6: Run all pipeline tests to confirm no regression**

```bash
cd core && go test ./internal/pipeline/ -v
```

Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add core/internal/pipeline/chunker.go core/internal/pipeline/chunker_test.go
git commit -m "feat(pipeline): VAD interface in ChunkerOpts, nil falls back to RMS"
```

---

## Task 4: Store (speaker.json + WAV helpers)

**Files:**
- Create: `core/internal/speaker/store.go`
- Create: `core/internal/speaker/store_test.go`

- [ ] **Step 1: Write failing tests**

Create `core/internal/speaker/store_test.go`:

```go
package speaker

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestStore_ProfileRoundTrip(t *testing.T) {
	dir := t.TempDir()
	wavPath := filepath.Join(dir, "enrollment.wav")
	p := Profile{
		Version:    1,
		RefAudio:   wavPath,
		EnrolledAt: time.Date(2026, 4, 30, 12, 0, 0, 0, time.UTC),
		DurationS:  10.2,
	}
	if err := SaveProfile(dir, p); err != nil {
		t.Fatalf("SaveProfile: %v", err)
	}
	got, err := LoadProfile(dir)
	if err != nil {
		t.Fatalf("LoadProfile: %v", err)
	}
	if got.Version != 1 {
		t.Errorf("Version = %d, want 1", got.Version)
	}
	if got.RefAudio != wavPath {
		t.Errorf("RefAudio = %q, want %q", got.RefAudio, wavPath)
	}
	if got.DurationS != 10.2 {
		t.Errorf("DurationS = %f, want 10.2", got.DurationS)
	}
}

func TestStore_WAVRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.wav")

	samples := make([]float32, 16000) // 1 second of silence
	for i := range samples {
		samples[i] = float32(i) / float32(len(samples)) // ramp
	}
	if err := SaveWAV(path, samples, 16000); err != nil {
		t.Fatalf("SaveWAV: %v", err)
	}

	fi, _ := os.Stat(path)
	// 44 header bytes + 16000*4 data bytes
	wantSize := int64(44 + len(samples)*4)
	if fi.Size() != wantSize {
		t.Errorf("file size = %d, want %d", fi.Size(), wantSize)
	}

	got, err := LoadWAV(path)
	if err != nil {
		t.Fatalf("LoadWAV: %v", err)
	}
	if len(got) != len(samples) {
		t.Fatalf("len(got) = %d, want %d", len(got), len(samples))
	}
	for i, v := range got {
		if v != samples[i] {
			t.Errorf("sample[%d] = %f, want %f", i, v, samples[i])
		}
	}
}

func TestStore_LoadProfile_MissingFile(t *testing.T) {
	_, err := LoadProfile(t.TempDir())
	if err == nil {
		t.Fatal("expected error for missing speaker.json, got nil")
	}
}

func TestStore_LoadWAV_MissingFile(t *testing.T) {
	_, err := LoadWAV("/nonexistent/path/enrollment.wav")
	if err == nil {
		t.Fatal("expected error for missing WAV, got nil")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd core && go test ./internal/speaker/ -run TestStore -v
```

Expected: compile error — `Profile`, `SaveProfile`, `LoadProfile`, `SaveWAV`, `LoadWAV` not defined.

- [ ] **Step 3: Implement `core/internal/speaker/store.go`**

```go
package speaker

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

// Profile holds enrollment metadata and the path to the reference audio file.
type Profile struct {
	Version    int       `json:"version"`
	RefAudio   string    `json:"ref_audio"`
	EnrolledAt time.Time `json:"enrolled_at"`
	DurationS  float64   `json:"duration_s"`
}

// SaveProfile writes speaker.json to dir.
func SaveProfile(dir string, p Profile) error {
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return fmt.Errorf("store: marshal profile: %w", err)
	}
	return os.WriteFile(filepath.Join(dir, "speaker.json"), data, 0644)
}

// LoadProfile reads speaker.json from dir. Returns an error if the file is absent.
func LoadProfile(dir string) (Profile, error) {
	data, err := os.ReadFile(filepath.Join(dir, "speaker.json"))
	if err != nil {
		return Profile{}, fmt.Errorf("store: read profile: %w", err)
	}
	var p Profile
	if err := json.Unmarshal(data, &p); err != nil {
		return Profile{}, fmt.Errorf("store: unmarshal profile: %w", err)
	}
	return p, nil
}

// SaveWAV writes samples as a 16kHz mono IEEE float32 WAV to path.
func SaveWAV(path string, samples []float32, sampleRate int) error {
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("store: create wav: %w", err)
	}
	defer f.Close()

	dataSize := uint32(len(samples) * 4)
	hdr := wavHeader{
		ChunkID:       [4]byte{'R', 'I', 'F', 'F'},
		ChunkSize:     36 + dataSize,
		Format:        [4]byte{'W', 'A', 'V', 'E'},
		Subchunk1ID:   [4]byte{'f', 'm', 't', ' '},
		Subchunk1Size: 16,
		AudioFormat:   3, // IEEE_FLOAT
		NumChannels:   1,
		SampleRate:    uint32(sampleRate),
		ByteRate:      uint32(sampleRate) * 4,
		BlockAlign:    4,
		BitsPerSample: 32,
		Subchunk2ID:   [4]byte{'d', 'a', 't', 'a'},
		Subchunk2Size: dataSize,
	}
	if err := binary.Write(f, binary.LittleEndian, hdr); err != nil {
		return fmt.Errorf("store: write wav header: %w", err)
	}
	if err := binary.Write(f, binary.LittleEndian, samples); err != nil {
		return fmt.Errorf("store: write wav data: %w", err)
	}
	return nil
}

// LoadWAV reads float32 samples from a WAV written by SaveWAV.
func LoadWAV(path string) ([]float32, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("store: open wav: %w", err)
	}
	defer f.Close()

	var hdr wavHeader
	if err := binary.Read(f, binary.LittleEndian, &hdr); err != nil {
		return nil, fmt.Errorf("store: read wav header: %w", err)
	}
	n := int(hdr.Subchunk2Size) / 4
	samples := make([]float32, n)
	if err := binary.Read(f, binary.LittleEndian, samples); err != nil {
		return nil, fmt.Errorf("store: read wav data: %w", err)
	}
	return samples, nil
}

type wavHeader struct {
	ChunkID       [4]byte
	ChunkSize     uint32
	Format        [4]byte
	Subchunk1ID   [4]byte
	Subchunk1Size uint32
	AudioFormat   uint16
	NumChannels   uint16
	SampleRate    uint32
	ByteRate      uint32
	BlockAlign    uint16
	BitsPerSample uint16
	Subchunk2ID   [4]byte
	Subchunk2Size uint32
}
```

- [ ] **Step 4: Run tests**

```bash
cd core && go test ./internal/speaker/ -run TestStore -v
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/speaker/store.go core/internal/speaker/store_test.go
git commit -m "feat(speaker): store — speaker.json + float32 WAV read/write"
```

---

## Task 5: Enroller + `vkb-enroll` CLI

**Files:**
- Create: `core/internal/speaker/enroller.go`
- Create: `core/internal/speaker/enroller_test.go`
- Create: `core/cmd/enroll/main.go`

- [ ] **Step 1: Write the failing test**

Create `core/internal/speaker/enroller_test.go`:

```go
package speaker

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

// fakeSource simulates mic input — returns a pre-built sample slice, then closes.
type fakeSource struct {
	samples []float32
	sent    bool
}

func (s *fakeSource) start(_ context.Context, _ int) (<-chan []float32, error) {
	ch := make(chan []float32, 1)
	if !s.sent {
		ch <- s.samples
		s.sent = true
	}
	close(ch)
	return ch, nil
}

func TestEnroller_SavesWAVAndProfile(t *testing.T) {
	dir := t.TempDir()

	// 1 second of audio at 16kHz
	samples := make([]float32, 16000)
	for i := range samples {
		samples[i] = float32(i) / 16000
	}
	src := &fakeSource{samples: samples}

	e := &Enroller{sampleRate: 16000, source: src.start}
	if err := e.Record(context.Background(), dir, 5*time.Second); err != nil {
		t.Fatalf("Record: %v", err)
	}

	// speaker.json must exist
	p, err := LoadProfile(dir)
	if err != nil {
		t.Fatalf("LoadProfile: %v", err)
	}
	if p.Version != 1 {
		t.Errorf("Version = %d, want 1", p.Version)
	}

	// enrollment.wav must exist and be non-empty
	got, err := LoadWAV(filepath.Join(dir, "enrollment.wav"))
	if err != nil {
		t.Fatalf("LoadWAV: %v", err)
	}
	if len(got) == 0 {
		t.Error("enrollment.wav is empty")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd core && go test ./internal/speaker/ -run TestEnroller -v
```

Expected: compile error — `Enroller` not defined.

- [ ] **Step 3: Implement `core/internal/speaker/enroller.go`**

```go
package speaker

import (
	"context"
	"fmt"
	"path/filepath"
	"time"
	"unsafe"

	"github.com/gen2brain/malgo"
)

// sourceFunc is the function signature for opening a mic source.
// Matches MalgoCapture.Start for production; replaced by fakeSource in tests.
type sourceFunc func(ctx context.Context, sampleRate int) (<-chan []float32, error)

// Enroller records mic audio and saves enrollment artifacts to a directory.
type Enroller struct {
	sampleRate int
	source     sourceFunc
}

// NewEnroller returns an Enroller backed by the default system microphone.
func NewEnroller(sampleRate int) *Enroller {
	return &Enroller{
		sampleRate: sampleRate,
		source:     malgoSource,
	}
}

// Record captures audio for up to duration (or until ctx is cancelled),
// then writes enrollment.wav and speaker.json to dir.
func (e *Enroller) Record(ctx context.Context, dir string, duration time.Duration) error {
	recCtx, cancel := context.WithTimeout(ctx, duration)
	defer cancel()

	ch, err := e.source(recCtx, e.sampleRate)
	if err != nil {
		return fmt.Errorf("enroller: start mic: %w", err)
	}

	var samples []float32
	for s := range ch {
		samples = append(samples, s...)
	}
	if len(samples) == 0 {
		return fmt.Errorf("enroller: no audio captured")
	}

	wavPath := filepath.Join(dir, "enrollment.wav")
	if err := SaveWAV(wavPath, samples, e.sampleRate); err != nil {
		return fmt.Errorf("enroller: save wav: %w", err)
	}

	durationS := float64(len(samples)) / float64(e.sampleRate)
	p := Profile{
		Version:    1,
		RefAudio:   wavPath,
		EnrolledAt: time.Now().UTC(),
		DurationS:  durationS,
	}
	if err := SaveProfile(dir, p); err != nil {
		return fmt.Errorf("enroller: save profile: %w", err)
	}
	return nil
}

// malgoSource opens the default system mic via miniaudio.
func malgoSource(ctx context.Context, sampleRate int) (<-chan []float32, error) {
	mctx, err := malgo.InitContext(nil, malgo.ContextConfig{}, func(string) {})
	if err != nil {
		return nil, fmt.Errorf("malgo init context: %w", err)
	}

	cfg := malgo.DefaultDeviceConfig(malgo.Capture)
	cfg.Capture.Format = malgo.FormatF32
	cfg.Capture.Channels = 1
	cfg.SampleRate = uint32(sampleRate)
	cfg.Alsa.NoMMap = 1

	out := make(chan []float32, 64)

	onRecv := func(_, in []byte, frameCount uint32) {
		if frameCount == 0 || len(in) < int(frameCount)*4 {
			return
		}
		header := (*float32)(unsafe.Pointer(&in[0]))
		view := unsafe.Slice(header, int(frameCount))
		samples := make([]float32, frameCount)
		copy(samples, view)
		select {
		case out <- samples:
		case <-ctx.Done():
		}
	}

	device, err := malgo.InitDevice(mctx.Context, cfg, malgo.DeviceCallbacks{Data: onRecv})
	if err != nil {
		_ = mctx.Uninit()
		mctx.Free()
		return nil, fmt.Errorf("malgo init device: %w", err)
	}
	if err := device.Start(); err != nil {
		device.Uninit()
		_ = mctx.Uninit()
		mctx.Free()
		return nil, fmt.Errorf("malgo start: %w", err)
	}

	go func() {
		defer close(out)
		<-ctx.Done()
		device.Stop()
		device.Uninit()
		_ = mctx.Uninit()
		mctx.Free()
	}()

	return out, nil
}
```

- [ ] **Step 4: Run the test**

```bash
cd core && go test ./internal/speaker/ -run TestEnroller -v
```

Expected: PASS.

- [ ] **Step 5: Create `core/cmd/enroll/main.go`**

```go
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/voice-keyboard/core/internal/speaker"
)

func main() {
	duration := flag.Duration("duration", 10*time.Second, "recording duration")
	outDir := flag.String("out", filepath.Join(os.Getenv("HOME"), ".config", "voice-keyboard"), "output directory for speaker.json and enrollment.wav")
	flag.Parse()

	if err := os.MkdirAll(*outDir, 0755); err != nil {
		log.Fatalf("create output dir: %v", err)
	}

	fmt.Fprintf(os.Stderr, "🎙  Recording for %v — speak naturally, then wait...\n", *duration)

	e := speaker.NewEnroller(16000)
	if err := e.Record(context.Background(), *outDir, *duration); err != nil {
		log.Fatalf("enrollment failed: %v", err)
	}

	fmt.Fprintf(os.Stderr, "✓ Enrolled. Profile saved to %s\n", *outDir)
}
```

- [ ] **Step 6: Build the CLI to verify it compiles**

```bash
cd core && go build ./cmd/enroll/
```

Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add core/internal/speaker/enroller.go core/internal/speaker/enroller_test.go core/cmd/enroll/
git commit -m "feat(speaker): Enroller records mic + vkb-enroll CLI"
```

---

## Task 6: SpeakerBeam-SS ONNX Export Script

**Files:**
- Create: `scripts/export_tse_model.py`

This is a developer tool run once to produce `tse_model.onnx`. It requires Python + PyTorch + asteroid. Not needed to run the Go tests.

- [ ] **Step 1: Install Python deps (dev machine only)**

```bash
pip install torch asteroid-filterbanks soundfile numpy
```

- [ ] **Step 2: Create `scripts/export_tse_model.py`**

```python
#!/usr/bin/env python3
"""
Export SpeakerBeam-SS from Asteroid to a single ONNX model.
Inputs:  mixed    float32[1, T]  — mixed audio at 16kHz
         ref_audio float32[1, R]  — enrollment audio at 16kHz
Output:  output   float32[1, T]  — extracted target-speaker audio

Usage:
    python scripts/export_tse_model.py --out core/build/models/tse_model.onnx
"""

import argparse
import os
import numpy as np
import torch
import torch.nn as nn

def get_args():
    p = argparse.ArgumentParser()
    p.add_argument("--out", default="core/build/models/tse_model.onnx")
    p.add_argument("--validate", action="store_true")
    return p.parse_args()


class SpeakerBeamWrapper(nn.Module):
    """Wraps SpeakerBeam-SS so it takes (mixed, ref_audio) and returns extracted audio."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, mixed: torch.Tensor, ref_audio: torch.Tensor) -> torch.Tensor:
        # Extract speaker embedding from ref_audio using the model's encoder
        ref_emb = self.model.encoder(ref_audio)  # [1, D]
        # Separate using mixed + embedding
        est = self.model(mixed, ref_emb)
        return est


def main():
    args = get_args()
    os.makedirs(os.path.dirname(args.out), exist_ok=True)

    print("Loading SpeakerBeam-SS from Asteroid hub...")
    try:
        from asteroid.models import SpeakerBeam
        model = SpeakerBeam.from_pretrained("mpariente/SpeakerBeam-WHAM-oracle")
    except Exception as e:
        print(f"Could not load from hub: {e}")
        print("Install asteroid: pip install asteroid-filterbanks")
        raise

    model.eval()
    wrapper = SpeakerBeamWrapper(model)

    # Dummy inputs for tracing
    T = 16000  # 1s mixed
    R = 16000  # 1s reference
    mixed = torch.randn(1, T)
    ref_audio = torch.randn(1, R)

    print(f"Exporting to {args.out}...")
    torch.onnx.export(
        wrapper,
        (mixed, ref_audio),
        args.out,
        input_names=["mixed", "ref_audio"],
        output_names=["output"],
        dynamic_axes={
            "mixed":     {1: "T"},
            "ref_audio": {1: "R"},
            "output":    {1: "T"},
        },
        opset_version=17,
    )
    print("Export complete.")

    if args.validate:
        import onnxruntime as ort
        sess = ort.InferenceSession(args.out)
        out = sess.run(
            ["output"],
            {"mixed": mixed.numpy(), "ref_audio": ref_audio.numpy()},
        )
        assert out[0].shape == (1, T), f"unexpected output shape: {out[0].shape}"
        print("Validation passed.")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Run the export (requires Python deps + internet for model download)**

```bash
mkdir -p core/build/models
python scripts/export_tse_model.py --out core/build/models/tse_model.onnx --validate
```

Expected:
```
Loading SpeakerBeam-SS from Asteroid hub...
Exporting to core/build/models/tse_model.onnx...
Export complete.
Validation passed.
```

Note: if the exact Asteroid model ID has changed, check https://huggingface.co/mpariente for the current SpeakerBeam checkpoint name and update the `from_pretrained` argument.

- [ ] **Step 4: Add models directory to `.gitignore`**

Append to the repo root `.gitignore` (or create if missing):

```
core/build/models/
```

- [ ] **Step 5: Commit**

```bash
git add scripts/export_tse_model.py .gitignore
git commit -m "feat(scripts): SpeakerBeam-SS PyTorch → ONNX export script"
```

---

## Task 7: SpeakerBeamSS Go Wrapper

**Files:**
- Create: `core/internal/speaker/speakerbeam.go`
- Create: `core/internal/speaker/speakerbeam_test.go`

- [ ] **Step 1: Write the unit test (no model needed)**

Create `core/internal/speaker/speakerbeam_test.go`:

```go
package speaker

import (
	"context"
	"testing"
)

// fakeTSE satisfies TSEExtractor for pipeline tests.
type fakeTSE struct {
	extractCalls int
	returnSamples []float32
}

func (f *fakeTSE) Extract(_ context.Context, mixed []float32, _ []float32) ([]float32, error) {
	f.extractCalls++
	if f.returnSamples != nil {
		return f.returnSamples, nil
	}
	// default: return zeros of same length as mixed
	return make([]float32, len(mixed)), nil
}

func TestFakeTSE_ImplementsInterface(t *testing.T) {
	var _ TSEExtractor = &fakeTSE{}
}

func TestFakeTSE_ReturnsZerosForMixed(t *testing.T) {
	f := &fakeTSE{}
	mixed := []float32{0.1, 0.2, 0.3}
	out, err := f.Extract(context.Background(), mixed, nil)
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if len(out) != len(mixed) {
		t.Errorf("len(out) = %d, want %d", len(out), len(mixed))
	}
	for i, v := range out {
		if v != 0 {
			t.Errorf("out[%d] = %f, want 0", i, v)
		}
	}
	if f.extractCalls != 1 {
		t.Errorf("extractCalls = %d, want 1", f.extractCalls)
	}
}
```

- [ ] **Step 2: Run the interface test**

```bash
cd core && go test ./internal/speaker/ -run TestFakeTSE -v
```

Expected: PASS.

- [ ] **Step 3: Implement `core/internal/speaker/speakerbeam.go`**

```go
package speaker

import (
	"context"
	"fmt"

	ort "github.com/yalue/onnxruntime_go"
)

// SpeakerBeamSS implements TSEExtractor using tse_model.onnx.
// The model takes (mixed [1,T], ref_audio [1,R]) and returns extracted audio [1,T].
type SpeakerBeamSS struct {
	session *ort.DynamicAdvancedSession
}

// NewSpeakerBeamSS loads tse_model.onnx from modelPath.
// Call InitONNXRuntime before this.
func NewSpeakerBeamSS(modelPath string) (*SpeakerBeamSS, error) {
	session, err := ort.NewDynamicAdvancedSession(
		modelPath,
		[]string{"mixed", "ref_audio"},
		[]string{"output"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("speakerbeam: load %q: %w", modelPath, err)
	}
	return &SpeakerBeamSS{session: session}, nil
}

// Extract runs TSE inference. mixed and ref are 16kHz mono PCM.
// Returns extracted audio of the same length as mixed.
func (s *SpeakerBeamSS) Extract(_ context.Context, mixed []float32, ref []float32) ([]float32, error) {
	mixedT, err := ort.NewTensor(ort.NewShape(1, int64(len(mixed))), mixed)
	if err != nil {
		return nil, fmt.Errorf("speakerbeam: mixed tensor: %w", err)
	}
	defer mixedT.Destroy()

	refT, err := ort.NewTensor(ort.NewShape(1, int64(len(ref))), ref)
	if err != nil {
		return nil, fmt.Errorf("speakerbeam: ref tensor: %w", err)
	}
	defer refT.Destroy()

	outT, err := ort.NewEmptyTensor[float32](ort.NewShape(1, int64(len(mixed))))
	if err != nil {
		return nil, fmt.Errorf("speakerbeam: output tensor: %w", err)
	}
	defer outT.Destroy()

	if err := s.session.Run(
		[]ort.Value{mixedT, refT},
		[]ort.Value{outT},
	); err != nil {
		return nil, fmt.Errorf("speakerbeam: inference: %w", err)
	}

	out := make([]float32, len(mixed))
	copy(out, outT.GetData())
	return out, nil
}

// Close releases the ONNX session.
func (s *SpeakerBeamSS) Close() error {
	return s.session.Destroy()
}
```

- [ ] **Step 4: Add model-gated integration test**

Append to `core/internal/speaker/speakerbeam_test.go`:

```go
//go:build speakerbeam

package speaker

import (
	"context"
	"math"
	"os"
	"testing"
)

func TestSpeakerBeamSS_ReducesInterferer(t *testing.T) {
	libPath := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if libPath == "" {
		libPath = "/opt/homebrew/lib/libonnxruntime.dylib"
	}
	if err := InitONNXRuntime(libPath); err != nil {
		t.Fatalf("InitONNXRuntime: %v", err)
	}
	modelPath := os.Getenv("TSE_MODEL_PATH")
	if modelPath == "" {
		t.Skip("TSE_MODEL_PATH not set")
	}

	tse, err := NewSpeakerBeamSS(modelPath)
	if err != nil {
		t.Fatalf("NewSpeakerBeamSS: %v", err)
	}
	defer tse.Close()

	const n = 16000
	// Target speaker: 440Hz sine
	target := make([]float32, n)
	// Interferer: 880Hz sine
	interferer := make([]float32, n)
	for i := range target {
		target[i] = 0.3 * float32(math.Sin(2*math.Pi*440*float64(i)/16000))
		interferer[i] = 0.3 * float32(math.Sin(2*math.Pi*880*float64(i)/16000))
	}
	// Mixed signal: both speakers
	mixed := make([]float32, n)
	for i := range mixed {
		mixed[i] = target[i] + interferer[i]
	}

	out, err := tse.Extract(context.Background(), mixed, target /* ref = target speaker */)
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}

	// The extracted output should have lower energy at 880Hz than the mixed signal.
	// Rough check: RMS of (out - target) should be less than RMS of (mixed - target).
	rmsResidual := func(a, b []float32) float64 {
		var sum float64
		for i := range a {
			d := float64(a[i] - b[i])
			sum += d * d
		}
		return math.Sqrt(sum / float64(len(a)))
	}
	rmsMixed := rmsResidual(mixed, target)
	rmsOut := rmsResidual(out, target)
	if rmsOut >= rmsMixed {
		t.Errorf("TSE did not improve separation: rmsOut=%f >= rmsMixed=%f", rmsOut, rmsMixed)
	}
}
```

- [ ] **Step 5: Run all speaker tests (without build tag)**

```bash
cd core && go test ./internal/speaker/ -v
```

Expected: all PASS (model-gated test skipped).

- [ ] **Step 6: Commit**

```bash
git add core/internal/speaker/speakerbeam.go core/internal/speaker/speakerbeam_test.go
git commit -m "feat(speaker): SpeakerBeamSS ONNX wrapper + fakeTSE for pipeline tests"
```

---

## Task 8: Pipeline TSE Gate

**Files:**
- Modify: `core/internal/pipeline/pipeline.go`
- Modify: `core/internal/pipeline/pipeline_test.go`

- [ ] **Step 1: Write the failing tests**

Add to `core/internal/pipeline/pipeline_test.go`:

```go
// fakeTSEExtractor records calls and returns zeros (simulates TSE suppressing all audio).
type fakeTSEExtractor struct {
	calls int
	out   []float32 // if nil, returns zeros of mixed length
}

func (f *fakeTSEExtractor) Extract(_ context.Context, mixed []float32, _ []float32) ([]float32, error) {
	f.calls++
	if f.out != nil {
		return f.out, nil
	}
	return make([]float32, len(mixed)), nil
}

func TestPipeline_TSENilSkipsExtract(t *testing.T) {
	src := make([]float32, 24000)
	for i := range src {
		src[i] = 0.1
	}
	tse := &fakeTSEExtractor{}
	p := New(denoise.NewPassthrough(), &fakeTranscriber{out: "hello"}, dict.NewFuzzy(nil, 1), &fakeCleaner{out: "hello"})
	// TSE is nil — not set on pipeline

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := p.Run(ctx, pushChan(src, denoise.FrameSize))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if tse.calls != 0 {
		t.Errorf("Extract called %d times, want 0 when TSE is nil", tse.calls)
	}
}

func TestPipeline_TSEActiveCallsExtractPerChunk(t *testing.T) {
	// Two chunks: 500ms tone, 200ms silence, 500ms tone
	tr := &fakeMultiTranscriber{outputs: []string{"hello", "world"}}
	cl := &fakeCleaner{out: "Hello world."}
	tse := &fakeTSEExtractor{}

	p := New(denoise.NewPassthrough(), tr, dict.NewFuzzy(nil, 0), cl)
	p.TSE = tse
	p.TSERef = make([]float32, 16000) // 1s of silence as ref (content doesn't matter for fakeTSE)
	p.ChunkerOpts = ChunkerOpts{
		VoiceThreshold: 0.005,
		SilenceHangMs:  100,
		MaxChunkMs:     12_000,
		ForceCutScanMs: 100,
	}

	frames := make(chan []float32, 4)
	frames <- toneFrames48k(500, 0.3)
	frames <- silence48k(200)
	frames <- toneFrames48k(500, 0.3)
	close(frames)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := p.Run(ctx, frames)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if tse.calls != 2 {
		t.Errorf("Extract calls = %d, want 2 (one per chunk)", tse.calls)
	}
}

func TestPipeline_TSEOutputZeroYieldsEmptyResult(t *testing.T) {
	// TSE returns zeros → Whisper gets silence → empty transcription → empty Result
	src := make([]float32, 24000)
	for i := range src {
		src[i] = 0.1
	}
	tse := &fakeTSEExtractor{} // returns zeros by default
	tr := &fakeTranscriber{out: ""} // Whisper says nothing on silence
	cl := &fakeCleaner{out: "should not be called"}

	p := New(denoise.NewPassthrough(), tr, dict.NewFuzzy(nil, 1), cl)
	p.TSE = tse
	p.TSERef = make([]float32, 16000)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	res, err := p.Run(ctx, pushChan(src, denoise.FrameSize))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Cleaned != "" {
		t.Errorf("expected empty Cleaned when TSE zeroes audio, got %q", res.Cleaned)
	}
}
```

- [ ] **Step 2: Run new tests to verify they fail**

```bash
cd core && go test ./internal/pipeline/ -run "TestPipeline_TSE" -v
```

Expected: compile error — `TSE` and `TSERef` fields not on `Pipeline`.

- [ ] **Step 3: Update `core/internal/pipeline/pipeline.go`**

Add imports:

```go
import (
    // existing imports...
    "github.com/voice-keyboard/core/internal/speaker"
)
```

Add fields to `Pipeline` struct after the existing callback fields:

```go
// TSE, when non-nil, extracts the enrolled user's voice from each chunk
// before it reaches Whisper. Nil means TSE is off — pipeline behaves as today.
TSE speaker.TSEExtractor

// TSERef is the enrolled reference audio (loaded from enrollment.wav).
// Required when TSE is non-nil; read-only during Run.
TSERef []float32
```

In `pipeline.Run`, inside the transcribe worker goroutine, right after receiving `e` from `chunkCh` and before calling `p.transcriber.Transcribe`, add:

```go
if p.TSE != nil {
    cleaned, tseErr := p.TSE.Extract(ctx, e.Samples, p.TSERef)
    if tseErr != nil {
        mu.Lock()
        workerErr = fmt.Errorf("tse: %w", tseErr)
        mu.Unlock()
        for range chunkCh {}
        return
    }
    e.Samples = cleaned
}
```

The full transcribe worker goroutine now looks like:

```go
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
            if p.TSE != nil {
                cleaned, tseErr := p.TSE.Extract(ctx, e.Samples, p.TSERef)
                if tseErr != nil {
                    mu.Lock()
                    workerErr = fmt.Errorf("tse: %w", tseErr)
                    mu.Unlock()
                    for range chunkCh {
                    }
                    return
                }
                e.Samples = cleaned
            }
            t0 := time.Now()
            text, err := p.transcriber.Transcribe(ctx, e.Samples)
            // ... rest unchanged
```

- [ ] **Step 4: Run all pipeline tests**

```bash
cd core && go test ./internal/pipeline/ -v
```

Expected: all PASS including the three new TSE tests.

- [ ] **Step 5: Load enrollment at startup in `New()`**

Add a helper to `pipeline.go` that the composition root can call to wire up TSE from a profile directory:

```go
// LoadTSE initialises SpeakerBeamSS and loads the enrollment WAV from profileDir.
// Returns nil extractor + nil error when speaker.json is absent (TSE off).
// Returns error only on partial state (json present but WAV missing/corrupt).
func LoadTSE(profileDir, modelPath, onnxLibPath string) (speaker.TSEExtractor, []float32, error) {
    p, err := speaker.LoadProfile(profileDir)
    if os.IsNotExist(err) {
        return nil, nil, nil // no enrollment — TSE off
    }
    if err != nil {
        return nil, nil, fmt.Errorf("load tse: profile: %w", err)
    }
    ref, err := speaker.LoadWAV(p.RefAudio)
    if err != nil {
        return nil, nil, fmt.Errorf("load tse: ref wav: %w", err)
    }
    if err := speaker.InitONNXRuntime(onnxLibPath); err != nil {
        return nil, nil, fmt.Errorf("load tse: onnx runtime: %w", err)
    }
    tse, err := speaker.NewSpeakerBeamSS(modelPath)
    if err != nil {
        return nil, nil, fmt.Errorf("load tse: model: %w", err)
    }
    return tse, ref, nil
}
```

Also add the `os` import to `pipeline.go`.

- [ ] **Step 6: Run full test suite**

```bash
cd core && go test ./... -v
```

Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add core/internal/pipeline/pipeline.go core/internal/pipeline/pipeline_test.go
git commit -m "feat(pipeline): TSE gate between chunker and Whisper"
```

---

## Task 9: Shell Scripts

**Files:**
- Create: `enroll.sh`
- Create: `run-speaker.sh`

- [ ] **Step 1: Create `enroll.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

MODELS_DIR="$(dirname "$0")/core/build/models"
PROFILE_DIR="${HOME}/.config/voice-keyboard"
ONNX_LIB="${ONNXRUNTIME_LIB_PATH:-/opt/homebrew/lib/libonnxruntime.dylib}"
SILERO_URL="https://github.com/snakers4/silero-vad/raw/master/files/silero_vad.onnx"

mkdir -p "$MODELS_DIR" "$PROFILE_DIR"

# Download Silero VAD model if missing
if [[ ! -f "$MODELS_DIR/silero_vad.onnx" ]]; then
  echo "Downloading silero_vad.onnx..."
  curl -L -o "$MODELS_DIR/silero_vad.onnx" "$SILERO_URL"
fi

# Check that tse_model.onnx exists (produced by scripts/export_tse_model.py)
if [[ ! -f "$MODELS_DIR/tse_model.onnx" ]]; then
  echo "ERROR: $MODELS_DIR/tse_model.onnx not found."
  echo "Run: python scripts/export_tse_model.py --out $MODELS_DIR/tse_model.onnx"
  exit 1
fi

# Build vkb-enroll
echo "Building vkb-enroll..."
(cd "$(dirname "$0")/core" && go build -o build/vkb-enroll ./cmd/enroll/)

echo ""
echo "🎙  Speak naturally for 10 seconds — press Ctrl+C to stop early."
echo ""

ONNXRUNTIME_LIB_PATH="$ONNX_LIB" \
  "$(dirname "$0")/core/build/vkb-enroll" \
  --duration=10s \
  --out="$PROFILE_DIR"

echo ""
echo "✓ Voice enrolled. Run ./run-speaker.sh to test."
```

- [ ] **Step 2: Create `run-speaker.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

MODELS_DIR="$(dirname "$0")/core/build/models"
PROFILE_DIR="${HOME}/.config/voice-keyboard"
DICT="${DICT_PATH:-}"
ONNX_LIB="${ONNXRUNTIME_LIB_PATH:-/opt/homebrew/lib/libonnxruntime.dylib}"

# Check enrollment
if [[ ! -f "$PROFILE_DIR/speaker.json" ]]; then
  echo "No voice enrollment found. Run ./enroll.sh first."
  exit 1
fi

# Build vkb-cli
echo "Building vkb-cli..."
(cd "$(dirname "$0")/core" && go build -o build/vkb-cli ./cmd/vkb-cli/)

FIFO=$(mktemp -t vkb-speaker-XXXXX)
rm -f "$FIFO"
mkfifo "$FIFO"
trap 'rm -f "$FIFO"' EXIT

ONNXRUNTIME_LIB_PATH="$ONNX_LIB" \
VKB_PROFILE_DIR="$PROFILE_DIR" \
VKB_MODELS_DIR="$MODELS_DIR" \
  "$(dirname "$0")/core/build/vkb-cli" pipe \
  ${DICT:+--dict "$DICT"} \
  --live \
  --latency-report \
  --speaker \
  < "$FIFO" &
PID=$!
exec 3>"$FIFO"

echo ""
echo "🎙  Recording (TSE active) — press any key to stop, 'q' to cancel."
echo ""

while IFS= read -rsn1 key; do
  if [[ "$key" == "q" ]]; then
    echo "cancel" >&3
  else
    echo "" >&3
  fi
  break
done
exec 3>&-
wait "$PID"
```

- [ ] **Step 3: Make executable**

```bash
chmod +x enroll.sh run-speaker.sh
```

- [ ] **Step 4: Smoke-test `enroll.sh` (requires mic)**

```bash
./enroll.sh
```

Expected: downloads models (first run), records 10 seconds, prints "✓ Voice enrolled."

- [ ] **Step 5: Commit**

```bash
git add enroll.sh run-speaker.sh
git commit -m "feat: enroll.sh + run-speaker.sh for TSE enrollment and testing"
```

---

## Task 10: Integration Similarity Test

**Files:**
- Create: `core/internal/speaker/tse_integration_test.go`

This test requires a real 2-speaker WAV fixture and the ONNX models. Guard with build tag `speakerbeam`.

- [ ] **Step 1: Create `core/internal/speaker/tse_integration_test.go`**

```go
//go:build speakerbeam

package speaker

import (
	"context"
	"math"
	"os"
	"testing"
)

// wordErrorRate computes a simple character-level similarity as a proxy for WER.
// Returns the fraction of differing characters (0 = identical, 1 = completely different).
func rmsOf(s []float32) float64 {
	var sum float64
	for _, v := range s {
		sum += float64(v) * float64(v)
	}
	return math.Sqrt(sum / float64(len(s)))
}

// TestTSE_ReducesInterfererRMS feeds a 2-speaker mixture through TSE and
// asserts the extracted output is closer (in RMS) to the target than the
// raw mixed signal is.
func TestTSE_ReducesInterfererRMS(t *testing.T) {
	libPath := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if libPath == "" {
		libPath = "/opt/homebrew/lib/libonnxruntime.dylib"
	}
	modelPath := os.Getenv("TSE_MODEL_PATH")
	if modelPath == "" {
		t.Skip("TSE_MODEL_PATH not set — set to core/build/models/tse_model.onnx")
	}

	if err := InitONNXRuntime(libPath); err != nil {
		t.Fatalf("InitONNXRuntime: %v", err)
	}

	tse, err := NewSpeakerBeamSS(modelPath)
	if err != nil {
		t.Fatalf("NewSpeakerBeamSS: %v", err)
	}
	defer tse.Close()

	const n = 32000 // 2 seconds at 16kHz
	target := make([]float32, n)
	interferer := make([]float32, n)
	mixed := make([]float32, n)
	for i := range target {
		target[i] = 0.25 * float32(math.Sin(2*math.Pi*300*float64(i)/16000))
		interferer[i] = 0.25 * float32(math.Sin(2*math.Pi*1200*float64(i)/16000))
		mixed[i] = target[i] + interferer[i]
	}

	out, err := tse.Extract(context.Background(), mixed, target)
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}

	// Compute residual RMS vs target
	residualMixed := make([]float32, n)
	residualOut := make([]float32, n)
	for i := range mixed {
		residualMixed[i] = mixed[i] - target[i]
		residualOut[i] = out[i] - target[i]
	}

	rmsMixed := rmsOf(residualMixed)
	rmsOut := rmsOf(residualOut)

	t.Logf("Interferer RMS in mixed: %.4f", rmsMixed)
	t.Logf("Interferer RMS in TSE output: %.4f", rmsOut)

	if rmsOut >= rmsMixed {
		t.Errorf("TSE did not reduce interferer: rmsOut=%.4f >= rmsMixed=%.4f", rmsOut, rmsMixed)
	}
}
```

- [ ] **Step 2: Run with build tag (requires models)**

```bash
cd core && \
  ONNXRUNTIME_LIB_PATH=/opt/homebrew/lib/libonnxruntime.dylib \
  TSE_MODEL_PATH=build/models/tse_model.onnx \
  go test ./internal/speaker/ -tags speakerbeam -run TestTSE_ReducesInterfererRMS -v
```

Expected: PASS with log lines showing `rmsOut < rmsMixed`.

- [ ] **Step 3: Run all tests without build tags to confirm no regression**

```bash
cd core && go test ./... -v
```

Expected: all PASS.

- [ ] **Step 4: Final commit**

```bash
git add core/internal/speaker/tse_integration_test.go
git commit -m "test(speaker): TSE integration test — interferer RMS reduction"
```

---

## Self-Review Notes

- **Spec §2 (Chunker VAD):** Covered in Task 3. `nil` fallback to RMS is explicit in the `processWindow` implementation and tested.
- **Spec §3 (Pipeline TSE gate):** Covered in Task 8. `LoadTSE` helper handles missing `speaker.json` → nil TSE silently.
- **Spec §4 (onnxruntime_go):** Task 1 adds the dep; `InitONNXRuntime` in `vad.go` is the single call-site.
- **Spec §5 (ONNX export):** Task 6. Note: Asteroid model hub ID may need updating — verify at export time.
- **Spec §6 (Enrollment CLI + scripts):** Tasks 5 + 9.
- **Spec §7 (Testing):** fakeVAD in chunker_test ✓, fakeTSE in pipeline_test ✓, Store round-trip ✓, Enroller ✓, model-gated integration ✓.
- **Type consistency check:** `speaker.VAD`, `speaker.TSEExtractor`, `speaker.SileroVAD`, `speaker.SpeakerBeamSS`, `speaker.Profile`, `speaker.InitONNXRuntime`, `speaker.LoadProfile`, `speaker.SaveProfile`, `speaker.LoadWAV`, `speaker.SaveWAV`, `speaker.NewEnroller` — all used consistently across tasks.
- **`Pipeline.TSE` and `Pipeline.TSERef`:** set directly on the struct (exported fields), consistent with existing `Pipeline.LevelCallback`, `Pipeline.ChunkerOpts` pattern.
