# Pipeline Orchestration — Slice 4 (A/B Compare) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pick one captured session, replay its raw audio through N selected presets, and render the resulting transcripts side-by-side so the user can compare presets on identical input.

**Architecture:** New `core/internal/replay` package consumes `audio.FakeCapture` to feed a session's `denoise.wav` (raw 48 kHz mic input) through fresh transient pipelines built from `presets.Resolve(...)`. Per-preset replay sessions are written under `<base>/<source-id>/replay-<preset>/` so they don't pollute the top-level Inspector list. Within a single Compare run, a Whisper-instance cache keyed on model size avoids 3× model-load latency. New `vkb_replay` C ABI export returns a JSON array; Mac side gets a `ReplayClient` bridge plus a `CompareView` that brings back the Pipeline tab's segmented control with `[Editor | Compare]`.

**Tech Stack:** Go 1.22+ (cgo, existing pipeline + presets + audio packages, `audio.FakeCapture`), SwiftUI (cards layout, multi-select Picker), pure-helper `Levenshtein` for the closest-match badge. No new external dependencies.

---

## File Structure

### Go (new)

- `core/internal/audio/wav_reader.go` — `ReadWAVMono(path string) (samples []float32, sampleRate int, err error)`. Walks RIFF chunks, supports 16-bit PCM mono.
- `core/internal/audio/wav_reader_test.go` — round-trip with a recorder-written WAV; rejects malformed.
- `core/internal/replay/replay.go` — `Run(ctx, Options) ([]Result, error)` (whispercpp-tagged).
- `core/internal/replay/replay_test.go` — happy-path with bundled `default` preset against a small fixture, plus error-recovery test.
- `core/cmd/libvkb/replay_export.go` — `vkb_replay` C ABI export.
- `core/cmd/libvkb/replay_export_test.go` — happy-path + bad-id tests.

### Go (modified)

- `core/cmd/libvkb/sessions_goapi.go` — append `replayGo(sourceID, presetsCSV string) string`.
- `core/cmd/libvkb/state.go` — extract `buildPipelineFromConfig(cfg config.Config) (*pipeline.Pipeline, error)` so replay package can use it.

### Mac UI (new)

- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/ReplayResult.swift` — Codable types matching Go's `replay.Result`.
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/ReplayClient.swift` — protocol + `LibVKBReplayClient`.
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/Levenshtein.swift` — pure helper `Levenshtein.distance(_:_:)`.
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/LevenshteinTests.swift`.
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/ReplayClientTests.swift`.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/CompareView.swift` — picker + run button + result grid.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/CompareCard.swift` — per-preset result card.

### Mac UI (modified)

- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift` — add `replayJSON(sourceID:presetsCSV:) async -> String?`.
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/LibvkbEngine.swift` — impl.
- `mac/Packages/VoiceKeyboardCore/Sources/CVKB/include/libvkb_shim.h` — declare `vkb_replay`.
- `mac/Packages/VoiceKeyboardCore/Sources/CVKBStubs/cvkb_stubs.c` — stub for SwiftPM tests.
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CoreEngineTests.swift` — extend `SpyCoreEngine`.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift` — restore the segmented control with `[Editor | Compare]`.

---

## Phase A — Audio prerequisites

### Task 1: `ReadWAVMono` helper

**Files:**
- Create: `core/internal/audio/wav_reader.go`
- Create: `core/internal/audio/wav_reader_test.go`

The replay package needs to load a session's recorded WAV back into `[]float32`. The transcribe test already has a private `readWavMono16k`; lift it into the audio package as a public helper that handles both 16 kHz and 48 kHz mono PCM (we feed 48 kHz `denoise.wav` for replay).

- [ ] **Step 1: Write the failing test**

```go
// core/internal/audio/wav_reader_test.go
package audio

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadWAVMono_RoundTripWithRecorder(t *testing.T) {
	t.Skip("uses recorder; lifted in next task — placeholder so file exists")
}

func TestReadWAVMono_RejectsNonRIFF(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "garbage.wav")
	if err := os.WriteFile(p, []byte("not a wav"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := ReadWAVMono(p); err == nil {
		t.Fatal("expected error for non-RIFF file")
	}
}

func TestReadWAVMono_RejectsMissingFile(t *testing.T) {
	if _, _, err := ReadWAVMono("/no/such/file.wav"); err == nil {
		t.Fatal("expected error for missing file")
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd core && go test ./internal/audio/... -run TestReadWAVMono -v`
Expected: FAIL — `ReadWAVMono` undefined.

- [ ] **Step 3: Implement the helper**

```go
// core/internal/audio/wav_reader.go
package audio

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"
)

// ReadWAVMono loads a 16-bit PCM mono WAV file into []float32.
// Returns the samples and the sample rate from the fmt chunk.
// Walks the RIFF chunk list so optional LIST/INFO chunks before the
// data chunk don't trip up parsing.
func ReadWAVMono(path string) ([]float32, int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, 0, err
	}
	if len(data) < 44 || string(data[0:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return nil, 0, fmt.Errorf("wav: not a RIFF/WAVE file: %s", path)
	}
	var sampleRate, channels, bitsPerSample int
	var pcm []byte
	for i := 12; i+8 <= len(data); {
		id := string(data[i : i+4])
		size := int(binary.LittleEndian.Uint32(data[i+4 : i+8]))
		if i+8+size > len(data) {
			return nil, 0, fmt.Errorf("wav: chunk %q overruns file", id)
		}
		switch id {
		case "fmt ":
			if size < 16 {
				return nil, 0, fmt.Errorf("wav: fmt chunk too small: %d", size)
			}
			channels = int(binary.LittleEndian.Uint16(data[i+10 : i+12]))
			sampleRate = int(binary.LittleEndian.Uint32(data[i+12 : i+16]))
			bitsPerSample = int(binary.LittleEndian.Uint16(data[i+22 : i+24]))
		case "data":
			pcm = data[i+8 : i+8+size]
		}
		next := i + 8 + size
		if size%2 == 1 {
			next++
		}
		i = next
		if pcm != nil && sampleRate != 0 {
			break
		}
	}
	if sampleRate == 0 || pcm == nil {
		return nil, 0, fmt.Errorf("wav: missing fmt or data chunk")
	}
	if channels != 1 || bitsPerSample != 16 {
		return nil, 0, fmt.Errorf("wav: only mono 16-bit PCM supported (got channels=%d bits=%d)", channels, bitsPerSample)
	}
	samples := make([]float32, len(pcm)/2)
	for j := range samples {
		v := int16(binary.LittleEndian.Uint16(pcm[j*2 : j*2+2]))
		samples[j] = float32(v) / float32(math.MaxInt16)
	}
	return samples, sampleRate, nil
}
```

- [ ] **Step 4: Replace the placeholder round-trip test with a real one**

Replace `TestReadWAVMono_RoundTripWithRecorder` with:

```go
func TestReadWAVMono_RoundTripPCM(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "tone.wav")
	// Hand-craft a minimal valid WAV: 16 kHz mono 16-bit, 100 samples.
	const sr = 16000
	const n = 100
	pcm := make([]byte, n*2)
	for i := 0; i < n; i++ {
		v := int16(i * 200)
		pcm[i*2] = byte(uint16(v) & 0xFF)
		pcm[i*2+1] = byte(uint16(v) >> 8)
	}
	hdr := []byte{
		'R', 'I', 'F', 'F',
		0, 0, 0, 0, // size — patched below
		'W', 'A', 'V', 'E',
		'f', 'm', 't', ' ',
		16, 0, 0, 0,
		1, 0,                              // PCM
		1, 0,                              // mono
		byte(sr), byte(sr >> 8), 0, 0,     // sample rate
		byte(sr * 2), byte((sr * 2) >> 8), 0, 0, // byte rate
		2, 0,                              // block align
		16, 0,                             // bits per sample
		'd', 'a', 't', 'a',
		byte(n * 2), 0, 0, 0,
	}
	out := append(hdr, pcm...)
	totalSize := uint32(len(out) - 8)
	out[4] = byte(totalSize)
	out[5] = byte(totalSize >> 8)
	if err := os.WriteFile(p, out, 0o644); err != nil {
		t.Fatal(err)
	}
	got, gotSR, err := ReadWAVMono(p)
	if err != nil {
		t.Fatalf("ReadWAVMono: %v", err)
	}
	if gotSR != sr {
		t.Errorf("sampleRate = %d, want %d", gotSR, sr)
	}
	if len(got) != n {
		t.Errorf("len(samples) = %d, want %d", len(got), n)
	}
}
```

- [ ] **Step 5: Run tests**

Run: `cd core && go test ./internal/audio/... -run TestReadWAVMono -v`
Expected: PASS — 3 tests.

- [ ] **Step 6: Commit**

```bash
git add core/internal/audio/wav_reader.go core/internal/audio/wav_reader_test.go
git commit -m "feat(audio): ReadWAVMono helper for replay path"
```

---

## Phase B — Pipeline construction extracted

### Task 2: Extract `buildPipelineFromConfig` from libvkb's engine

**Files:**
- Modify: `core/cmd/libvkb/state.go`

The replay package needs to construct a `*pipeline.Pipeline` from a `config.Config` without an `*engine`. Today's `(*engine).buildPipeline()` reads from `e.cfg`; lift the body into a free function that takes `cfg config.Config` and returns the pipeline, and have the engine method call into it.

- [ ] **Step 1: Read current `buildPipeline`**

Run: `grep -n 'func (e \*engine) buildPipeline' core/cmd/libvkb/state.go`
Expected: shows the method. Read its body — it already takes no arguments beyond `e.cfg`.

- [ ] **Step 2: Add a free function next to the method**

In `core/cmd/libvkb/state.go`, after the existing `(*engine).buildPipeline`, add:

```go
// buildPipelineFromConfig is the free-function form of (*engine).buildPipeline.
// Takes a config.Config so callers without an engine — like the replay
// package's transient pipelines — can build one. setLastError is a hook
// so the engine method can still surface degradation messages via
// vkb_last_error; replay callers pass a no-op.
func buildPipelineFromConfig(cfg config.Config, setLastError func(string)) (*pipeline.Pipeline, error) {
	tr, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
		ModelPath: cfg.WhisperModelPath,
		Language:  cfg.Language,
	})
	if err != nil {
		return nil, err
	}
	provider, err := llm.ProviderByName(cfg.LLMProvider)
	if err != nil {
		_ = tr.Close()
		return nil, err
	}
	opts := llm.Options{
		Model:   cfg.LLMModel,
		BaseURL: cfg.LLMBaseURL,
	}
	if provider.NeedsAPIKey {
		opts.APIKey = cfg.LLMAPIKey
	}
	cleaner, err := provider.New(opts)
	if err != nil {
		_ = tr.Close()
		return nil, err
	}
	dy := dict.NewFuzzy(cfg.CustomDict, 1)

	var d denoise.Denoiser
	if !cfg.DisableNoiseSuppression {
		d = newDeepFilterOrPassthrough(cfg.DeepFilterModelPath)
	} else {
		d = denoise.NewPassthrough()
	}

	p := pipeline.New(tr, dy, cleaner)
	p.FrameStages = []audio.Stage{
		denoise.NewStage(d),
		resample.NewDecimate3(),
	}

	if cfg.TSEEnabled {
		backend, beErr := speaker.BackendByName(cfg.TSEBackend)
		if beErr != nil {
			log.Printf("[vkb] buildPipelineFromConfig: TSE backend lookup failed, continuing without TSE: %v", beErr)
			setLastError("tse: " + beErr.Error())
			return p, nil
		}
		modelsDir := filepath.Dir(cfg.TSEModelPath)
		tse, tseErr := pipeline.LoadTSE(
			backend,
			cfg.TSEProfileDir,
			modelsDir,
			cfg.ONNXLibPath,
			cfg.TSEThresholdValue(),
		)
		if tseErr != nil {
			log.Printf("[vkb] buildPipelineFromConfig: TSE load failed, continuing without TSE: %v", tseErr)
			setLastError("tse: " + tseErr.Error())
		} else if tse != nil {
			p.ChunkStages = []audio.Stage{tse}
		}
	}
	return p, nil
}
```

- [ ] **Step 3: Replace the method body to delegate**

Find `func (e *engine) buildPipeline()`. Replace its body with:

```go
func (e *engine) buildPipeline() (*pipeline.Pipeline, error) {
	return buildPipelineFromConfig(e.cfg, func(msg string) { e.setLastError(msg) })
}
```

- [ ] **Step 4: Build dylib + run libvkb tests**

Run: `cd core && make build-dylib && go test -tags=whispercpp ./cmd/libvkb/...`
Expected: PASS — no behavior change, tests still green.

- [ ] **Step 5: Commit**

```bash
git add core/cmd/libvkb/state.go
git commit -m "refactor(libvkb): extract buildPipelineFromConfig free function"
```

---

## Phase C — Replay package

### Task 3: `replay` package skeleton + Result types

**Files:**
- Create: `core/internal/replay/replay.go`
- Create: `core/internal/replay/replay_test.go`

- [ ] **Step 1: Write the failing test**

```go
//go:build whispercpp

// core/internal/replay/replay_test.go
package replay

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestRun_RejectsEmptyPresetList(t *testing.T) {
	_, err := Run(context.Background(), Options{
		SourceWAVPath: "ignored.wav",
		PresetNames:   nil,
	})
	if err == nil || !strings.Contains(err.Error(), "preset") {
		t.Errorf("expected preset-list error, got %v", err)
	}
}

func TestRun_RejectsMissingSourceWAV(t *testing.T) {
	_, err := Run(context.Background(), Options{
		SourceWAVPath: "/no/such/file.wav",
		PresetNames:   []string{"default"},
	})
	if err == nil {
		t.Errorf("expected error for missing source WAV, got nil")
	}
}

func TestRun_TimesOutPerPresetTimeout(t *testing.T) {
	t.Skip("end-to-end — covered manually + via Compare smoke test in Slice 4 PR")
	_ = time.Second
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd core && go test -tags=whispercpp ./internal/replay/... -v`
Expected: FAIL — `Run` undefined.

- [ ] **Step 3: Define types + minimal Run skeleton**

```go
//go:build whispercpp

// Package replay drives a captured session's raw audio through one or
// more presets via audio.FakeCapture. Used by the Mac Compare view and
// the vkb-cli compare subcommand to do A/B evaluation on identical
// input.
package replay

import (
	"context"
	"fmt"
	"path/filepath"
	"time"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/presets"
)

// Options drives a single Compare run.
type Options struct {
	// SourceWAVPath is the input WAV (typically <session>/denoise.wav,
	// raw 48 kHz mic audio before any pipeline processing).
	SourceWAVPath string
	// SourceID is the originating session id (used to namespace replay
	// outputs as <DestRoot>/<SourceID>/replay-<preset>/).
	SourceID string
	// DestRoot is the sessions base dir (typically /tmp/voicekeyboard/sessions).
	DestRoot string
	// PresetNames selects which presets to replay. Each must be present
	// in presets.Load(). Empty list returns an error.
	PresetNames []string
	// Secrets fills in API keys + model paths that don't live in presets.
	Secrets presets.EngineSecrets
}

// Result is one preset's replay outcome.
type Result struct {
	PresetName       string  `json:"preset"`
	Cleaned          string  `json:"cleaned"`
	Raw              string  `json:"raw"`
	Dict             string  `json:"dict"`
	TotalMS          int64   `json:"total_ms"`
	ReplaySessionDir string  `json:"replay_dir,omitempty"`
	Error            string  `json:"error,omitempty"`
}

// Run replays SourceWAVPath through each named preset and returns one
// Result per preset (in input order). A failed preset surfaces as
// Result.Error rather than aborting the whole run.
func Run(ctx context.Context, opts Options) ([]Result, error) {
	if len(opts.PresetNames) == 0 {
		return nil, fmt.Errorf("replay: preset list is empty")
	}
	all, err := presets.Load()
	if err != nil {
		return nil, fmt.Errorf("replay: load presets: %w", err)
	}
	byName := map[string]presets.Preset{}
	for _, p := range all {
		byName[p.Name] = p
	}

	// Validate WAV exists + load samples once; reuse across presets.
	samples, sr, err := audio.ReadWAVMono(opts.SourceWAVPath)
	if err != nil {
		return nil, fmt.Errorf("replay: read source: %w", err)
	}
	if sr != 48000 {
		return nil, fmt.Errorf("replay: source must be 48 kHz, got %d Hz", sr)
	}

	out := make([]Result, 0, len(opts.PresetNames))
	for _, name := range opts.PresetNames {
		p, ok := byName[name]
		if !ok {
			out = append(out, Result{PresetName: name, Error: "preset not found"})
			continue
		}
		t0 := time.Now()
		res, err := runOne(ctx, p, samples, opts)
		res.PresetName = name
		res.TotalMS = time.Since(t0).Milliseconds()
		if err != nil {
			res.Error = err.Error()
		}
		out = append(out, res)
	}
	return out, nil
}

func runOne(ctx context.Context, p presets.Preset, samples []float32, opts Options) (Result, error) {
	_ = filepath.Join // placeholder — real body lands in Task 4
	return Result{}, fmt.Errorf("replay: not yet implemented")
}
```

- [ ] **Step 4: Run tests**

Run: `cd core && go test -tags=whispercpp ./internal/replay/... -v`
Expected: PASS — 2 tests pass (rejects-empty, rejects-missing-WAV); the integration test stays skipped.

- [ ] **Step 5: Commit**

```bash
git add core/internal/replay/replay.go core/internal/replay/replay_test.go
git commit -m "feat(replay): package skeleton + Options/Result types"
```

---

### Task 4: Implement `runOne` — transient pipeline + FakeCapture

**Files:**
- Modify: `core/internal/replay/replay.go`
- Modify: `core/cmd/libvkb/state.go` (export `BuildPipelineFromConfig` so replay can use it)

`buildPipelineFromConfig` is in `package main` today. The replay package needs to call it. Two options: move it into a new public package, or replicate it. Since `package main` can't be imported, move it into the `pipeline` package as `pipeline.BuildFromConfig` so replay imports cleanly.

Actually: the function depends on `transcribe.NewWhisperCpp` (whispercpp build tag), which `pipeline` doesn't currently import. Putting it in `pipeline` would tag-leak that package. Cleaner: new sub-package `core/internal/pipeline/build` that owns the construction and is whispercpp-tagged.

- [ ] **Step 1: Create `pipeline/build` sub-package**

Move the body of `buildPipelineFromConfig` from `core/cmd/libvkb/state.go` into a new file:

```go
//go:build whispercpp

// Package build constructs a fresh *pipeline.Pipeline from a
// config.Config. Lives in its own sub-package because it pulls in
// transcribe (whispercpp build tag) which the rest of pipeline avoids.
package build

import (
	"log"
	"path/filepath"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/denoise"
	"github.com/voice-keyboard/core/internal/dict"
	"github.com/voice-keyboard/core/internal/llm"
	"github.com/voice-keyboard/core/internal/pipeline"
	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/speaker"
	"github.com/voice-keyboard/core/internal/transcribe"
)

// FromConfig builds a *pipeline.Pipeline + the denoiser source we used
// (so callers with a deepfilter denoiser can defer Close on it). setLastError
// is a hook for surfacing degradation (TSE load failures, etc.); pass a
// no-op when there's no engine to wire it into.
func FromConfig(cfg config.Config, setLastError func(string), newDeepFilter func(string) denoise.Denoiser) (*pipeline.Pipeline, error) {
	tr, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
		ModelPath: cfg.WhisperModelPath,
		Language:  cfg.Language,
	})
	if err != nil {
		return nil, err
	}
	provider, err := llm.ProviderByName(cfg.LLMProvider)
	if err != nil {
		_ = tr.Close()
		return nil, err
	}
	opts := llm.Options{Model: cfg.LLMModel, BaseURL: cfg.LLMBaseURL}
	if provider.NeedsAPIKey {
		opts.APIKey = cfg.LLMAPIKey
	}
	cleaner, err := provider.New(opts)
	if err != nil {
		_ = tr.Close()
		return nil, err
	}
	dy := dict.NewFuzzy(cfg.CustomDict, 1)

	var d denoise.Denoiser
	if !cfg.DisableNoiseSuppression {
		d = newDeepFilter(cfg.DeepFilterModelPath)
	} else {
		d = denoise.NewPassthrough()
	}

	p := pipeline.New(tr, dy, cleaner)
	p.FrameStages = []audio.Stage{
		denoise.NewStage(d),
		resample.NewDecimate3(),
	}

	if cfg.TSEEnabled {
		backend, beErr := speaker.BackendByName(cfg.TSEBackend)
		if beErr != nil {
			log.Printf("[vkb] build.FromConfig: TSE backend lookup failed, continuing without TSE: %v", beErr)
			setLastError("tse: " + beErr.Error())
			return p, nil
		}
		modelsDir := filepath.Dir(cfg.TSEModelPath)
		tse, tseErr := pipeline.LoadTSE(backend, cfg.TSEProfileDir, modelsDir, cfg.ONNXLibPath, cfg.TSEThresholdValue())
		if tseErr != nil {
			log.Printf("[vkb] build.FromConfig: TSE load failed, continuing without TSE: %v", tseErr)
			setLastError("tse: " + tseErr.Error())
		} else if tse != nil {
			p.ChunkStages = []audio.Stage{tse}
		}
	}
	return p, nil
}
```

Save as `core/internal/pipeline/build/build.go`.

- [ ] **Step 2: Update libvkb's engine to use the new package**

In `core/cmd/libvkb/state.go`, replace the in-file `buildPipelineFromConfig` block with a delegation:

```go
import (
	// ... existing imports ...
	pipelinebuild "github.com/voice-keyboard/core/internal/pipeline/build"
)

func (e *engine) buildPipeline() (*pipeline.Pipeline, error) {
	return pipelinebuild.FromConfig(
		e.cfg,
		func(msg string) { e.setLastError(msg) },
		newDeepFilterOrPassthrough,
	)
}
```

Delete the local `buildPipelineFromConfig` function (Task 2's free-function version).

- [ ] **Step 3: Implement `runOne` in replay**

Replace the placeholder `runOne` in `core/internal/replay/replay.go`:

```go
import (
	// ... existing imports ...
	"os"
	"path/filepath"

	"github.com/voice-keyboard/core/internal/audio"
	"github.com/voice-keyboard/core/internal/denoise"
	pipelinebuild "github.com/voice-keyboard/core/internal/pipeline/build"
	"github.com/voice-keyboard/core/internal/recorder"
)

// inputSampleRate matches the engine's expected mic input rate.
const inputSampleRate = 48000

// frameSizeFor48k = 10 ms @ 48 kHz, matching what the live engine pushes.
const frameSizeFor48k = 480

// noOpDeepFilter — replay path uses passthrough for deepfilter; the real
// deepfilter wiring is wrapped in a build tag in libvkb's state.go and we
// don't want to pull it in here. The user's preset can still set
// DisableNoiseSuppression = false; we'll silently use passthrough.
func noOpDeepFilter(string) denoise.Denoiser { return denoise.NewPassthrough() }

func runOne(ctx context.Context, p presets.Preset, samples []float32, opts Options) (Result, error) {
	cfg := presets.Resolve(p, opts.Secrets)

	// Build a transient pipeline from the resolved config.
	pipe, err := pipelinebuild.FromConfig(cfg, func(string) {}, noOpDeepFilter)
	if err != nil {
		return Result{}, fmt.Errorf("build pipeline: %w", err)
	}
	defer pipe.Close()

	// Replay output goes under <DestRoot>/<SourceID>/replay-<preset>/.
	// Sub-folder layout keeps replays out of the top-level Inspector list.
	destDir := filepath.Join(opts.DestRoot, opts.SourceID, "replay-"+p.Name)
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return Result{}, fmt.Errorf("mkdir dest: %w", err)
	}
	rec, err := recorder.Open(recorder.Options{Dir: destDir, AudioStages: true, Transcripts: true})
	if err != nil {
		return Result{}, fmt.Errorf("open recorder: %w", err)
	}
	pipe.Recorder = rec
	defer rec.Close()

	// Drive the pipeline via FakeCapture in a goroutine; collect Result.
	fake := audio.NewFakeCapture(samples, frameSizeFor48k)
	frames, err := fake.Start(ctx, inputSampleRate)
	if err != nil {
		return Result{}, fmt.Errorf("fake capture start: %w", err)
	}
	defer fake.Stop()

	res, err := pipe.Run(ctx, frames)
	if err != nil {
		return Result{ReplaySessionDir: destDir}, err
	}
	return Result{
		Cleaned:          res.Cleaned,
		Raw:              res.Raw,
		Dict:             res.Cleaned, // Pipeline.Result doesn't separately expose dict; cleaned == LLM output, raw == whisper. Slice 4.5 may add Dict explicitly.
		ReplaySessionDir: destDir,
	}, nil
}
```

(The `Dict` field is best-effort — `pipeline.Result` exposes `Raw` (whisper) and `Cleaned` (LLM output) but not the dict-corrected intermediate. The recorder writes `dict.txt` so the Mac side can read it from the replay session folder if it really needs the dict step's output. This is a documented Slice 4.5 follow-up.)

- [ ] **Step 4: Build dylib + run replay tests + libvkb tests**

Run: `cd core && make build-dylib && go test -tags=whispercpp ./internal/replay/... ./cmd/libvkb/...`
Expected: PASS — replay's two failure-path tests + all libvkb tests still green.

- [ ] **Step 5: Commit**

```bash
git add core/internal/pipeline/build/build.go core/cmd/libvkb/state.go core/internal/replay/replay.go
git commit -m "feat(replay): runOne builds transient pipeline and drives FakeCapture"
```

---

### Task 5: Whisper-instance cold-start optimization

**Files:**
- Modify: `core/internal/replay/replay.go`

Today each `runOne` calls `transcribe.NewWhisperCpp(...)` from scratch — ~2-5 seconds per replay. When all presets in a Compare run share the same Whisper model size (the common case), the load can happen once.

The cleanest path: a per-`Run` cache of `transcribe.Transcriber` instances keyed on model path. When `runOne` builds a config, check the cache before constructing a new Whisper. We can't share a `*pipeline.Pipeline` across replays (TSE state is per-pipeline, recorder is per-session), but we can share the Transcriber.

This requires `pipelinebuild.FromConfig` to optionally accept a pre-built Transcriber. Add an Options struct.

- [ ] **Step 1: Extend `pipelinebuild.FromConfig` to accept an optional Transcriber**

In `core/internal/pipeline/build/build.go`, change the function signature:

```go
type Options struct {
	Config         config.Config
	NewDeepFilter  func(string) denoise.Denoiser
	SetLastError   func(string)
	// SharedTranscriber, when non-nil, is used instead of constructing
	// a fresh whisper. Caller owns its lifetime.
	SharedTranscriber transcribe.Transcriber
}

func FromOptions(opts Options) (*pipeline.Pipeline, error) {
	cfg := opts.Config
	var tr transcribe.Transcriber
	if opts.SharedTranscriber != nil {
		tr = opts.SharedTranscriber
	} else {
		t, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
			ModelPath: cfg.WhisperModelPath,
			Language:  cfg.Language,
		})
		if err != nil {
			return nil, err
		}
		tr = t
	}
	// ... remainder of FromConfig body, replacing `tr` references ...
}

// FromConfig keeps the old signature for libvkb, delegating to FromOptions.
func FromConfig(cfg config.Config, setLastError func(string), newDeepFilter func(string) denoise.Denoiser) (*pipeline.Pipeline, error) {
	return FromOptions(Options{
		Config:        cfg,
		NewDeepFilter: newDeepFilter,
		SetLastError:  setLastError,
	})
}
```

Move the existing function body into `FromOptions`, replace direct calls to `transcribe.NewWhisperCpp` with the conditional pre-built path.

Crucial: when `SharedTranscriber` is set, the pipeline must NOT close it on its own `Close()`. Pipelines today close their transcriber unconditionally (they own it). Wrap the shared instance in a non-closing decorator:

```go
// nonClosingTranscriber adapts a Transcriber so the pipeline's Close()
// doesn't release the shared instance — the replay caller manages its
// lifetime.
type nonClosingTranscriber struct {
	transcribe.Transcriber
}

func (n nonClosingTranscriber) Close() error { return nil }
```

(Add this in the same file.)

- [ ] **Step 2: Wire the cache in replay.Run**

Modify `Run` to keep a per-call cache:

```go
func Run(ctx context.Context, opts Options) ([]Result, error) {
	// ... existing validation + samples load ...

	// Cache Whisper instances keyed on (modelPath, language) so repeats
	// of the same Whisper config reuse one model load.
	type whisperKey struct{ path, lang string }
	cache := map[whisperKey]transcribe.Transcriber{}
	defer func() {
		for _, t := range cache {
			_ = t.Close()
		}
	}()

	out := make([]Result, 0, len(opts.PresetNames))
	for _, name := range opts.PresetNames {
		p, ok := byName[name]
		if !ok {
			out = append(out, Result{PresetName: name, Error: "preset not found"})
			continue
		}
		cfg := presets.Resolve(p, opts.Secrets)
		key := whisperKey{path: cfg.WhisperModelPath, lang: cfg.Language}
		shared := cache[key]
		if shared == nil {
			t, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
				ModelPath: cfg.WhisperModelPath,
				Language:  cfg.Language,
			})
			if err != nil {
				out = append(out, Result{PresetName: name, Error: "whisper load: " + err.Error()})
				continue
			}
			cache[key] = t
			shared = t
		}

		t0 := time.Now()
		res, err := runOneWithTranscriber(ctx, p, cfg, shared, samples, opts)
		res.PresetName = name
		res.TotalMS = time.Since(t0).Milliseconds()
		if err != nil {
			res.Error = err.Error()
		}
		out = append(out, res)
	}
	return out, nil
}
```

Add `import "github.com/voice-keyboard/core/internal/transcribe"` at the top of `replay.go`.

- [ ] **Step 3: Replace `runOne` with `runOneWithTranscriber`**

```go
func runOneWithTranscriber(ctx context.Context, p presets.Preset, cfg config.Config, tr transcribe.Transcriber, samples []float32, opts Options) (Result, error) {
	pipe, err := pipelinebuild.FromOptions(pipelinebuild.Options{
		Config:            cfg,
		NewDeepFilter:     noOpDeepFilter,
		SetLastError:      func(string) {},
		SharedTranscriber: tr,
	})
	if err != nil {
		return Result{}, fmt.Errorf("build pipeline: %w", err)
	}
	defer pipe.Close()

	destDir := filepath.Join(opts.DestRoot, opts.SourceID, "replay-"+p.Name)
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return Result{}, fmt.Errorf("mkdir dest: %w", err)
	}
	rec, err := recorder.Open(recorder.Options{Dir: destDir, AudioStages: true, Transcripts: true})
	if err != nil {
		return Result{}, fmt.Errorf("open recorder: %w", err)
	}
	pipe.Recorder = rec
	defer rec.Close()

	fake := audio.NewFakeCapture(samples, frameSizeFor48k)
	frames, err := fake.Start(ctx, inputSampleRate)
	if err != nil {
		return Result{}, fmt.Errorf("fake capture start: %w", err)
	}
	defer fake.Stop()

	res, err := pipe.Run(ctx, frames)
	if err != nil {
		return Result{ReplaySessionDir: destDir}, err
	}
	return Result{
		Cleaned:          res.Cleaned,
		Raw:              res.Raw,
		Dict:             res.Cleaned, // see Slice 4.5 follow-up
		ReplaySessionDir: destDir,
	}, nil
}

// Add config import:
import "github.com/voice-keyboard/core/internal/config"
```

Also: update `pipelinebuild.FromOptions` to wrap the shared transcriber:

```go
if opts.SharedTranscriber != nil {
	tr = nonClosingTranscriber{Transcriber: opts.SharedTranscriber}
} else {
	// ... existing fresh-load path ...
}
```

- [ ] **Step 4: Run replay tests + libvkb tests**

Run: `cd core && go test -tags=whispercpp ./internal/replay/... ./cmd/libvkb/...`
Expected: PASS — same two replay tests still green; libvkb still green (the shared-transcriber path is opt-in so engine behavior unchanged).

- [ ] **Step 5: Commit**

```bash
git add core/internal/pipeline/build/build.go core/internal/replay/replay.go
git commit -m "perf(replay): share Whisper instance across same-model presets"
```

---

## Phase D — C ABI

### Task 6: `vkb_replay` C export

**Files:**
- Create: `core/cmd/libvkb/replay_export.go`
- Create: `core/cmd/libvkb/replay_export_test.go`
- Modify: `core/cmd/libvkb/sessions_goapi.go` (append `replayGo` Go-string wrapper)

- [ ] **Step 1: Write the failing test**

```go
//go:build whispercpp

// core/cmd/libvkb/replay_export_test.go
package main

import (
	"strings"
	"testing"
)

func TestExport_Replay_RejectsEmptyPresets(t *testing.T) {
	if getEngine() == nil {
		_ = vkb_init()
	}
	// SourceID irrelevant — we error before reading.
	out := replayGo("any-id", "")
	if !strings.Contains(out, "error") {
		t.Errorf("expected error JSON for empty preset list, got: %s", out)
	}
}

func TestExport_Replay_RejectsMissingSession(t *testing.T) {
	if getEngine() == nil {
		_ = vkb_init()
	}
	out := replayGo("does-not-exist", "default")
	if !strings.Contains(out, "error") {
		t.Errorf("expected error JSON for missing session, got: %s", out)
	}
}
```

- [ ] **Step 2: Add the C export**

```go
//go:build whispercpp

// core/cmd/libvkb/replay_export.go
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/voice-keyboard/core/internal/replay"
)

// vkb_replay drives a Compare run. sourceID is the originating session
// id (folder name under /tmp/voicekeyboard/sessions/). presetsCSV is a
// comma-separated list of preset names. Returns a JSON array of replay
// Results — caller frees via vkb_free_string. NULL on engine-not-init.
//
// Per-preset failures surface as Result.Error rather than aborting the
// whole call. A top-level error (no session, bad CSV, etc.) returns a
// JSON object {"error": "..."} so the Swift side can render it as a
// banner above the result cards.
//
//export vkb_replay
func vkb_replay(sourceIDC, presetsCSVC *C.char) *C.char {
	e := getEngine()
	if e == nil {
		return nil
	}
	if sourceIDC == nil || presetsCSVC == nil {
		return jsonErrorC("vkb_replay: nil argument")
	}
	sourceID := C.GoString(sourceIDC)
	presetsCSV := C.GoString(presetsCSVC)

	names := splitCSV(presetsCSV)
	if len(names) == 0 {
		return jsonErrorC("vkb_replay: empty preset list")
	}

	// The source session's denoise.wav is the canonical raw mic input.
	// SessionPaths in libvkb test fixtures puts it at <store>/<id>/denoise.wav.
	sessionDir := e.sessions.SessionDir(sourceID)
	wavPath := sessionDir + "/denoise.wav"

	results, err := replay.Run(context.Background(), replay.Options{
		SourceWAVPath: wavPath,
		SourceID:      sourceID,
		DestRoot:      e.sessions.Root(), // see Task 7 — Store needs Root()
		PresetNames:   names,
		Secrets:       secretsFromEngineCfg(e),
	})
	if err != nil {
		return jsonErrorC("vkb_replay: " + err.Error())
	}
	buf, err := json.Marshal(results)
	if err != nil {
		return jsonErrorC("vkb_replay: marshal: " + err.Error())
	}
	return C.CString(string(buf))
}

func splitCSV(s string) []string {
	if s == "" {
		return nil
	}
	out := strings.Split(s, ",")
	cleaned := make([]string, 0, len(out))
	for _, n := range out {
		n = strings.TrimSpace(n)
		if n != "" {
			cleaned = append(cleaned, n)
		}
	}
	return cleaned
}

// jsonErrorC builds a JSON {"error":"..."} payload + a heap C string.
func jsonErrorC(msg string) *C.char {
	buf, _ := json.Marshal(map[string]string{"error": msg})
	return C.CString(string(buf))
}

// secretsFromEngineCfg lifts secrets out of the engine's Config so
// replay.Run can resolve presets with the user's API key + model paths.
func secretsFromEngineCfg(e *engine) presetsEngineSecretsLikeShim {
	e.mu.Lock()
	defer e.mu.Unlock()
	return presetsEngineSecretsLikeShim{
		LLMAPIKey:           e.cfg.LLMAPIKey,
		WhisperModelPath:    e.cfg.WhisperModelPath,
		DeepFilterModelPath: e.cfg.DeepFilterModelPath,
		TSEProfileDir:       e.cfg.TSEProfileDir,
		TSEModelPath:        e.cfg.TSEModelPath,
		SpeakerEncoderPath:  e.cfg.SpeakerEncoderPath,
		ONNXLibPath:         e.cfg.ONNXLibPath,
		CustomDict:          append([]string{}, e.cfg.CustomDict...),
		Language:            e.cfg.Language,
		LLMBaseURL:          e.cfg.LLMBaseURL,
		LLMModel:            e.cfg.LLMModel,
	}
}
```

(`presetsEngineSecretsLikeShim` is just `presets.EngineSecrets`; the `presetsEngineSecretsLikeShim` typedef avoids importing presets here. Use the actual type:)

```go
import "github.com/voice-keyboard/core/internal/presets"

// ... and replace the shim type usage with presets.EngineSecrets directly.
```

(So secretsFromEngineCfg returns `presets.EngineSecrets`, not the shim.)

- [ ] **Step 3: Append `replayGo` to `sessions_goapi.go`**

```go
// presetSaveGo wraps vkb_save_preset...  (existing)

// replayGo wraps vkb_replay and returns the JSON string.
func replayGo(sourceID, presetsCSV string) string {
	csid := C.CString(sourceID)
	ccsv := C.CString(presetsCSV)
	defer C.free(unsafe.Pointer(csid))
	defer C.free(unsafe.Pointer(ccsv))
	cstr := vkb_replay(csid, ccsv)
	if cstr == nil {
		return ""
	}
	defer vkb_free_string(cstr)
	return C.GoString(cstr)
}
```

- [ ] **Step 4: Run tests + build dylib**

Run: `cd core && make build-dylib && go test -tags=whispercpp ./cmd/libvkb/... -run TestExport_Replay -v`
Expected: PASS — both new tests.

- [ ] **Step 5: Commit**

```bash
git add core/cmd/libvkb/replay_export.go \
        core/cmd/libvkb/replay_export_test.go \
        core/cmd/libvkb/sessions_goapi.go
git commit -m "feat(libvkb): vkb_replay export drives replay.Run from C ABI"
```

---

### Task 7: `sessions.Store.Root()` accessor

**Files:**
- Modify: `core/internal/sessions/sessions.go`

`vkb_replay` needs the sessions base path to pass into `replay.Options.DestRoot`. The Store today doesn't expose it.

- [ ] **Step 1: Add the accessor**

Find the `Store` struct + `NewStore` in `core/internal/sessions/sessions.go`. The base dir is stored as a field (likely `base string` or `root string`). Add:

```go
// Root returns the base directory this store walks.
func (s *Store) Root() string { return s.root }
```

(Adjust field name if different — read the file first.)

- [ ] **Step 2: Run sessions tests**

Run: `cd core && go test ./internal/sessions/...`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add core/internal/sessions/sessions.go
git commit -m "feat(sessions): Store.Root() accessor for replay use"
```

---

## Phase E — Mac side

### Task 8: `Levenshtein` helper

**Files:**
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/Levenshtein.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/LevenshteinTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("Levenshtein")
struct LevenshteinTests {
    @Test func identicalStrings_zero() {
        #expect(Levenshtein.distance("hello", "hello") == 0)
    }
    @Test func emptyVsNonEmpty_lengthOfOther() {
        #expect(Levenshtein.distance("", "abc") == 3)
        #expect(Levenshtein.distance("abc", "") == 3)
    }
    @Test func singleSubstitution_one() {
        #expect(Levenshtein.distance("cat", "bat") == 1)
    }
    @Test func insertion_one() {
        #expect(Levenshtein.distance("car", "cars") == 1)
    }
    @Test func unrelatedStrings_largerThanZero() {
        #expect(Levenshtein.distance("kitten", "sitting") == 3)
    }
    @Test func unicode_handled() {
        #expect(Levenshtein.distance("café", "cafe") == 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd mac && make test 2>&1 | grep -E 'Levenshtein|cannot find'`
Expected: errors about `Levenshtein` not found.

- [ ] **Step 3: Implement**

```swift
// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/Levenshtein.swift
import Foundation

/// Pure helper for the Compare view's "closest match" badge. Computes
/// the Levenshtein distance between two strings (Unicode-aware via
/// Character iteration). Standard two-row dynamic-programming table.
public enum Levenshtein {
    public static func distance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var prev = Array(0...bChars.count)
        var curr = Array(repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,           // deletion
                    curr[j - 1] + 1,       // insertion
                    prev[j - 1] + cost     // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd mac && make test 2>&1 | grep -E 'Levenshtein|Test run'`
Expected: 6 new tests pass.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/Levenshtein.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/LevenshteinTests.swift
git commit -m "feat(mac): Levenshtein distance helper for Compare closest-match badge"
```

---

### Task 9: `ReplayResult` + `ReplayClient` bridge

**Files:**
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/ReplayResult.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/ReplayClient.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/ReplayClientTests.swift`
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift`
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/LibvkbEngine.swift`
- Modify: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CoreEngineTests.swift`
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/CVKB/include/libvkb_shim.h`
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/CVKBStubs/cvkb_stubs.c`

- [ ] **Step 1: Define the wire types**

```swift
// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/ReplayResult.swift
import Foundation

/// One preset's outcome from a Compare run. Mirrors Go's replay.Result.
public struct ReplayResult: Codable, Equatable, Sendable, Identifiable {
    public let preset: String
    public let cleaned: String
    public let raw: String
    public let dict: String
    public let totalMs: Int64
    public let replayDir: String?
    public let error: String?

    public var id: String { preset }

    public init(
        preset: String, cleaned: String, raw: String, dict: String,
        totalMs: Int64, replayDir: String? = nil, error: String? = nil
    ) {
        self.preset = preset
        self.cleaned = cleaned
        self.raw = raw
        self.dict = dict
        self.totalMs = totalMs
        self.replayDir = replayDir
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case preset, cleaned, raw, dict, error
        case totalMs = "total_ms"
        case replayDir = "replay_dir"
    }
}

/// Top-level error envelope when vkb_replay fails before producing per-preset
/// results (no session, bad CSV, etc.). Decoded as a fallback when the
/// JSON isn't an array.
public struct ReplayError: Codable, Sendable {
    public let error: String
}
```

- [ ] **Step 2: Build the client + protocol**

```swift
// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/ReplayClient.swift
import Foundation

public enum ReplayClientError: Error {
    case engineUnavailable
    case decode(String)
    case backend(String)
}

public protocol ReplayClient: Sendable {
    func run(sourceID: String, presets: [String]) async throws -> [ReplayResult]
}

public final class LibVKBReplayClient: ReplayClient {
    private let engine: any CoreEngine

    public init(engine: any CoreEngine) {
        self.engine = engine
    }

    public func run(sourceID: String, presets: [String]) async throws -> [ReplayResult] {
        let csv = presets.joined(separator: ",")
        guard let json = await engine.replayJSON(sourceID: sourceID, presetsCSV: csv) else {
            throw ReplayClientError.engineUnavailable
        }
        // Try array-of-results first; fall back to error envelope.
        let data = Data(json.utf8)
        if let arr = try? JSONDecoder().decode([ReplayResult].self, from: data) {
            return arr
        }
        if let env = try? JSONDecoder().decode(ReplayError.self, from: data) {
            throw ReplayClientError.backend(env.error)
        }
        throw ReplayClientError.decode("unexpected JSON: \(json.prefix(200))")
    }
}
```

- [ ] **Step 3: Extend `CoreEngine` + `LibvkbEngine`**

In `CoreEngine.swift`, append to the protocol:

```swift
    /// Drive a Compare run. Returns the JSON array body from vkb_replay,
    /// or nil if the engine is not initialized.
    func replayJSON(sourceID: String, presetsCSV: String) async -> String?
```

In `LibvkbEngine.swift`, append the actor method:

```swift
    public func replayJSON(sourceID: String, presetsCSV: String) -> String? {
        return sourceID.withCString { csid -> String? in
            presetsCSV.withCString { ccsv -> String? in
                guard let cstr = vkb_replay(csid, ccsv) else { return nil }
                defer { vkb_free_string(cstr) }
                return String(cString: cstr)
            }
        }
    }
```

- [ ] **Step 4: Stub for SwiftPM tests**

In `mac/Packages/VoiceKeyboardCore/Sources/CVKB/include/libvkb_shim.h`, append:

```c
char* vkb_replay(const char* source_id, const char* presets_csv);
```

In `mac/Packages/VoiceKeyboardCore/Sources/CVKBStubs/cvkb_stubs.c`, append:

```c
char* vkb_replay(const char* source_id, const char* presets_csv) {
    (void)source_id; (void)presets_csv;
    return NULL;
}
```

- [ ] **Step 5: Extend SpyCoreEngine**

In `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CoreEngineTests.swift`, find the `SpyCoreEngine` class:

```swift
    var stubReplayJSON: String? = "[]"
    // ... existing fields ...

    func replayJSON(sourceID: String, presetsCSV: String) -> String? { stubReplayJSON }
```

- [ ] **Step 6: Write `ReplayClientTests`**

```swift
// mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/ReplayClientTests.swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("ReplayClient")
struct ReplayClientTests {
    @Test func decodes_emptyArray() async throws {
        let spy = SpyCoreEngine()
        spy.stubReplayJSON = "[]"
        let c = LibVKBReplayClient(engine: spy)
        let got = try await c.run(sourceID: "x", presets: ["default"])
        #expect(got.isEmpty)
    }

    @Test func decodes_results() async throws {
        let json = """
        [
          {"preset":"default","cleaned":"Hello.","raw":"hello","dict":"hello","total_ms":1234,
           "replay_dir":"/tmp/x/replay-default"},
          {"preset":"minimal","cleaned":"hi","raw":"hi","dict":"hi","total_ms":900}
        ]
        """
        let spy = SpyCoreEngine()
        spy.stubReplayJSON = json
        let c = LibVKBReplayClient(engine: spy)
        let got = try await c.run(sourceID: "x", presets: ["default", "minimal"])
        #expect(got.count == 2)
        #expect(got[0].preset == "default")
        #expect(got[0].totalMs == 1234)
        #expect(got[1].error == nil)
    }

    @Test func decodes_errorEnvelope_throws() async {
        let spy = SpyCoreEngine()
        spy.stubReplayJSON = #"{"error":"vkb_replay: source not found"}"#
        let c = LibVKBReplayClient(engine: spy)
        await #expect(throws: ReplayClientError.self) {
            _ = try await c.run(sourceID: "x", presets: ["default"])
        }
    }

    @Test func nilFromEngine_throwsUnavailable() async {
        let spy = SpyCoreEngine()
        spy.stubReplayJSON = nil
        let c = LibVKBReplayClient(engine: spy)
        await #expect(throws: ReplayClientError.self) {
            _ = try await c.run(sourceID: "x", presets: ["default"])
        }
    }
}
```

- [ ] **Step 7: Run tests + build**

Run: `cd mac && make test 2>&1 | tail -3`
Expected: PASS — total includes 6 Levenshtein + 4 ReplayClient tests on top of baseline.

Run: `cd mac && make build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/ReplayResult.swift \
        mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/ReplayClient.swift \
        mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift \
        mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/LibvkbEngine.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CoreEngineTests.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/ReplayClientTests.swift \
        mac/Packages/VoiceKeyboardCore/Sources/CVKB/include/libvkb_shim.h \
        mac/Packages/VoiceKeyboardCore/Sources/CVKBStubs/cvkb_stubs.c
git commit -m "feat(mac): ReplayClient bridge + ReplayResult + Levenshtein helper"
```

---

### Task 10: `CompareCard` (per-preset result card)

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/CompareCard.swift`

- [ ] **Step 1: Create the card**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/CompareCard.swift
import SwiftUI
import VoiceKeyboardCore
#if canImport(AppKit)
import AppKit
#endif

/// One result of a Compare run. Header has the preset name and the
/// total wall time. Body shows raw / dict / cleaned transcripts in
/// labeled blocks. A "closest match" badge appears when this preset's
/// cleaned text is the lowest Levenshtein distance to the original
/// dictation. Failed replays render the error in red.
struct CompareCard: View {
    let result: ReplayResult
    let isClosestMatch: Bool
    let onPlayTSE: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let err = result.error {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                transcriptBlock("RAW", text: result.raw)
                transcriptBlock("DICT", text: result.dict)
                transcriptBlock("CLEANED", text: result.cleaned, emphasized: true)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isClosestMatch ? Color.accentColor : .secondary.opacity(0.3),
                              lineWidth: isClosestMatch ? 2 : 1)
        )
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text(result.preset).font(.callout).bold()
            if isClosestMatch {
                Text("closest match")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            Text(formatMs(result.totalMs))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Button {
                onPlayTSE()
            } label: { Image(systemName: "play.circle") }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(result.replayDir == nil)
            .help("Play TSE output")
        }
    }

    @ViewBuilder
    private func transcriptBlock(_ label: String, text: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(text.isEmpty ? "(empty)" : text)
                .font(emphasized ? .body : .callout)
                .foregroundStyle(emphasized ? Color.primary : Color.secondary)
                .textSelection(.enabled)
        }
    }

    private func formatMs(_ ms: Int64) -> String {
        let s = Double(ms) / 1000
        return String(format: "%.1fs", s)
    }
}
```

- [ ] **Step 2: Build**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project && make build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/CompareCard.swift mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "feat(mac): CompareCard for per-preset replay results"
```

---

### Task 11: `CompareView` (top-level Compare tab)

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/CompareView.swift`

- [ ] **Step 1: Create the view**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/CompareView.swift
import SwiftUI
import VoiceKeyboardCore

/// Compare view: pick a captured session as audio source, pick N
/// presets to replay through, hit Run, see results side by side.
struct CompareView: View {
    let sessions: any SessionsClient
    let presets: any PresetsClient
    let replay: any ReplayClient

    @State private var sessionList: [SessionManifest] = []
    @State private var presetList: [Preset] = []
    @State private var selectedSourceID: String? = nil
    @State private var selectedPresetNames: Set<String> = []
    @State private var results: [ReplayResult] = []
    @State private var running = false
    @State private var loadError: String? = nil
    @State private var runError: String? = nil
    @State private var player = WAVPlayer()

    private var canRun: Bool {
        selectedSourceID != nil && !selectedPresetNames.isEmpty && !running
    }

    /// The original session's cleaned-text transcript, used as the
    /// reference for the "closest match" badge. nil if not loaded yet
    /// or if the source is missing.
    private var sourceTranscript: String? {
        guard let id = selectedSourceID else { return nil }
        return SessionPreview.load(in: id, maxChars: .max)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            Divider()
            if let err = loadError {
                Text(err).font(.callout).foregroundStyle(.red)
            } else if results.isEmpty && runError == nil {
                Text("Pick a source session and one or more presets, then click Run.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            if let err = runError {
                Text(err).font(.callout).foregroundStyle(.red)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(results) { r in
                        CompareCard(
                            result: r,
                            isClosestMatch: r.preset == closestMatchPreset,
                            onPlayTSE: { playTSE(for: r) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .task { await refresh() }
    }

    @ViewBuilder
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Source:").foregroundStyle(.secondary).font(.callout)
                Picker("Source", selection: Binding(
                    get: { selectedSourceID ?? sessionList.first?.id ?? "" },
                    set: { if !$0.isEmpty { selectedSourceID = $0 } }
                )) {
                    if sessionList.isEmpty {
                        Text("(no sessions)").tag("")
                    } else {
                        ForEach(sessionList) { s in
                            Text("\(relativeTime(s.id)) · \(s.preset)").tag(s.id)
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
                Button {
                    Task { await runReplay() }
                } label: {
                    if running {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Run", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
            }
            HStack(alignment: .center, spacing: 6) {
                Text("Presets:").foregroundStyle(.secondary).font(.callout)
                FlowLayout(spacing: 6) {
                    ForEach(presetList) { p in
                        Toggle(p.name, isOn: Binding(
                            get: { selectedPresetNames.contains(p.name) },
                            set: { on in
                                if on { selectedPresetNames.insert(p.name) }
                                else  { selectedPresetNames.remove(p.name) }
                            }
                        ))
                        .toggleStyle(.button)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var closestMatchPreset: String? {
        guard let ref = sourceTranscript, !results.isEmpty else { return nil }
        let scored: [(String, Int)] = results
            .compactMap { $0.error == nil ? ($0.preset, Levenshtein.distance(ref, $0.cleaned)) : nil }
        return scored.min(by: { $0.1 < $1.1 })?.0
    }

    private func relativeTime(_ id: String) -> String {
        guard let d = RelativeTime.parse(id) else { return id }
        return RelativeTime.string(now: Date(), then: d)
    }

    private func refresh() async {
        do {
            async let sessions = sessions.list()
            async let presets = presets.list()
            self.sessionList = try await sessions
            self.presetList = try await presets
            if selectedSourceID == nil { selectedSourceID = sessionList.first?.id }
            if selectedPresetNames.isEmpty,
               let def = presetList.first(where: { $0.name == "default" }) {
                selectedPresetNames.insert(def.name)
            }
        } catch {
            self.loadError = "Failed to load: \(error)"
        }
    }

    private func runReplay() async {
        guard let id = selectedSourceID else { return }
        running = true
        runError = nil
        let names = presetList.map(\.name).filter { selectedPresetNames.contains($0) }
        defer { running = false }
        do {
            let got = try await replay.run(sourceID: id, presets: names)
            await MainActor.run { self.results = got }
        } catch {
            await MainActor.run {
                self.runError = "Replay failed: \(error)"
                self.results = []
            }
        }
    }

    private func playTSE(for r: ReplayResult) {
        guard let dir = r.replayDir else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("tse.wav")
        player.toggle(url: url)
    }
}

/// Minimal flow-layout that wraps button-style toggles to multiple
/// rows when the row width is exceeded. SwiftUI's built-in HStack
/// doesn't wrap; this is a small layout that does.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, totalWidth: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxWidth {
                y += rowHeight + spacing
                x = 0; rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            totalWidth = max(totalWidth, x)
        }
        return CGSize(width: totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.minX + maxWidth {
                y += rowHeight + spacing
                x = bounds.minX; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: s.width, height: s.height))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project && make build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/CompareView.swift mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "feat(mac): CompareView with source picker, preset multi-select, results grid"
```

---

### Task 12: Restore segmented control in `PipelineTab` — `[Editor | Compare]`

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift`
- Modify: `mac/VoiceKeyboard/UI/Settings/SettingsView.swift` (pass `ReplayClient`)

- [ ] **Step 1: Update SettingsView wiring**

In `mac/VoiceKeyboard/UI/Settings/SettingsView.swift`, find the `case .pipeline:` block. Update:

```swift
        case .pipeline:
            PipelineTab(
                engine: composition.engine,
                sessions: LibVKBSessionsClient(engine: composition.engine),
                presets: LibVKBPresetsClient(engine: composition.engine),
                replay: LibVKBReplayClient(engine: composition.engine)
            )
```

- [ ] **Step 2: Rewrite `PipelineTab.swift`**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift
import SwiftUI
import VoiceKeyboardCore

/// Container for the Pipeline page. Hosts a segmented control between
/// the Editor (preset picker + drag-drop graph) and Compare (A/B
/// replay through N presets). The captured-session Inspector lives
/// under Playground.
struct PipelineTab: View {
    let engine: any CoreEngine
    let sessions: any SessionsClient
    let presets: any PresetsClient
    let replay: any ReplayClient

    @State private var selectedView: SubView = .editor

    enum SubView: String, CaseIterable, Identifiable {
        case editor = "Editor"
        case compare = "Compare"
        var id: String { rawValue }
    }

    var body: some View {
        SettingsPane {
            Picker("", selection: $selectedView) {
                ForEach(SubView.allCases) { v in
                    Text(v.rawValue).tag(v)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.bottom, 8)

            Divider()

            switch selectedView {
            case .editor:
                EditorView(presets: presets, sessions: sessions)
            case .compare:
                CompareView(sessions: sessions, presets: presets, replay: replay)
            }
        }
    }
}
```

- [ ] **Step 3: Build + test**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project && make build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

Run: `cd mac && make test 2>&1 | tail -3`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift \
        mac/VoiceKeyboard/UI/Settings/SettingsView.swift \
        mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "feat(mac): restore PipelineTab segmented control with [Editor | Compare]"
```

---

## Phase F — Final integration

### Task 13: Final integration check + PR

- [ ] **Step 1: Full Go suite**

Run: `cd core && go test ./... && go test -tags=whispercpp ./cmd/libvkb/... ./internal/replay/...`
Expected: PASS — all packages green.

- [ ] **Step 2: Full Mac suite**

Run: `cd mac && make test 2>&1 | tail -3`
Expected: PASS — baseline (95) + 6 Levenshtein + 4 ReplayClient = ~105 tests.

- [ ] **Step 3: Clean Debug build**

Run: `cd mac && make clean && make build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual smoke test**

- Toggle Developer mode on. Open Pipeline tab → segmented control shows `[Editor | Compare]`.
- Click Compare. Source picker shows captured sessions. Preset toggles include `default`/`minimal`/`aggressive`/`paranoid`.
- Pick `default` + `minimal` + `paranoid`. Click Run.
- Three cards appear; one is highlighted with the "closest match" border.
- Click ▶ on each card → tse.wav plays via the shared WAVPlayer.
- Pick a preset that's been deleted → its card shows the per-preset error in red.

- [ ] **Step 5: Branch + push + PR**

```bash
git push -u origin feat/pipeline-orchestration-slice-4
gh pr create --base main --title "feat: pipeline orchestration — slice 4 (compare)" \
  --body "Fourth slice — A/B comparison view. Pick a captured session as the audio source, replay through N presets, render results side-by-side.

## Summary

- New \`replay\` Go package: drives audio.FakeCapture against a fresh transient pipeline per preset; writes replay sessions under \`<source>/replay-<preset>/\`.
- Whisper-instance cache shared across same-model presets in a single Compare run.
- New \`vkb_replay\` C ABI export (JSON in / JSON out, mirrors sessions/presets ownership).
- Mac side: \`ReplayClient\` bridge + \`Levenshtein\` helper + \`CompareView\` with multi-select preset toggles + \`CompareCard\` per result.
- Pipeline tab gets its segmented control back: \`[Editor | Compare]\`.

## Test plan

- [x] cd core && go test ./...
- [x] cd core && go test -tags=whispercpp ./cmd/libvkb/... ./internal/replay/...
- [x] cd mac && make test (~105 tests, 6 new Levenshtein + 4 new ReplayClient)
- [x] cd mac && make build (clean)
- [ ] Manual: pick session + 3 presets, click Run, see 3 cards + closest-match badge.

## Slice 4.5 follow-up

\`Result.Dict\` currently mirrors \`Cleaned\` because \`pipeline.Result\` doesn't expose the dict-corrected intermediate. The replay session folder has \`dict.txt\` on disk; a small pipeline.Result expansion in Slice 4.5 will propagate it cleanly.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Summary

Total: **13 tasks across 6 phases.** Estimated ~600 LOC.

**By area:**
- Audio prerequisites (Task 1): ~80 LOC.
- Pipeline construction extracted (Tasks 2, 4): ~120 LOC moved + Whisper cache plumbing.
- Replay package (Tasks 3-5): ~180 LOC.
- C ABI (Tasks 6-7): ~100 LOC.
- Mac bridge (Task 9): ~150 LOC including tests.
- Mac UI (Tasks 8, 10-12): ~280 LOC.
- Final integration (Task 13): zero LOC.

---

## Test plan

- [ ] `cd core && go test ./...`
- [ ] `cd core && go test -tags=whispercpp ./cmd/libvkb/... ./internal/replay/...`
- [ ] `cd mac && make test`
- [ ] `cd mac && make build` (clean)
- [ ] Manual smoke (see Task 13 Step 4)

---

## Self-Review

### Spec coverage

| Spec section / requirement | Implementing task |
|---|---|
| `replay` Go package | Tasks 3-5 |
| Source's `denoise.wav` fed via `audio.FakeCapture` | Task 4 |
| Replay sessions under `<source-id>/replay-<preset>/` | Task 4 |
| Cards per preset with raw/dict/cleaned + total time | Task 10 |
| ▶ TSE-output play button | Task 10 (uses shared WAVPlayer from Slice 3) |
| "Closest match" badge — Levenshtein vs original | Tasks 8, 11 |
| Whisper instance reused when model size matches | Task 5 |
| C ABI: `vkb_replay` | Task 6 |
| Mac `ReplayClient` bridge | Task 9 |
| `CompareView` with source + multi-select + Run | Task 11 |
| PipelineTab segmented Editor/Compare | Task 12 |
| Replays don't pollute Inspector list | Task 4 (sub-folder layout — Inspector lists top-level only) |

All Slice 4 spec requirements mapped.

### Placeholder scan

No "TBD" / "implement later" hand-waves. The two known limitations (Result.Dict mirrors Cleaned, replay deepfilter is passthrough) are explicit in the code comments and the PR body, scoped as Slice 4.5.

### Type consistency

- Go `replay.Result` field tags (`json:"preset"`, `json:"cleaned"`, etc.) match Swift `ReplayResult` `CodingKeys`.
- `replay.Options.SourceID` ↔ `replayJSON(sourceID:presetsCSV:)` argument names line up.
- `pipelinebuild.Options.SharedTranscriber` (Task 5) is the same Transcriber type used by `transcribe.NewWhisperCpp` (Task 4) — no shadowing.
- `CompareView` calls `replay.run(sourceID:presets:)` with the protocol method defined in Task 9.
- `CompareCard.onPlayTSE` is a `() -> Void` callback — `CompareView.playTSE(for:)` produces a closure of that shape.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-03-pipeline-orchestration-slice-4-compare.md`. Two execution options:

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task, review between tasks.

**2. Inline Execution** — Execute tasks here, batch with checkpoints.
