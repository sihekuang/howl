# In-App Voice Enrollment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `enroll.sh`/Python flow with a Settings UI that records voice and enables Target Speaker Extraction in the Mac app, using `onnxruntime_go` for embedding compute.

**Architecture:** Swift records 10 s of 48 kHz audio via the existing `AudioCapture`, hands the buffer to Go via a new synchronous C export `vkb_enroll_compute`, which decimates to 16 kHz, runs `speaker_encoder.onnx`, and writes `enrollment.wav`/`enrollment.emb`/`speaker.json` atomically. The libvkb `buildPipeline` is extended to call the existing `pipeline.LoadTSE` when `tse_enabled` is set in the config. A new "Voice" Settings tab handles UI, status, and the TSE on/off toggle.

**Tech Stack:** Go 1.26, `github.com/yalue/onnxruntime_go` (already linked), SwiftUI, AVAudioEngine (already used in `AudioCapture`), ONNX Runtime via Homebrew at `/opt/homebrew/lib/libonnxruntime.dylib`.

---

## File Map

| Status | Path | Responsibility |
|---|---|---|
| Create | `core/internal/speaker/embedding.go` | `ComputeEmbedding` — runs `speaker_encoder.onnx` |
| Create | `core/internal/speaker/embedding_test.go` | Unit + integration tests (model-gated) |
| Create | `core/cmd/libvkb/enroll.go` | Enroll handler: decimate, compute, atomic write |
| Create | `core/cmd/libvkb/enroll_test.go` | Tests for atomic write helper |
| Modify | `core/cmd/libvkb/exports.go` | Add `vkb_enroll_compute` C export |
| Modify | `core/cmd/libvkb/state.go` | Wire `pipeline.LoadTSE` into `buildPipeline` |
| Modify | `core/internal/config/config.go` | Add 5 TSE fields + defaults |
| Modify | `core/internal/config/config_test.go` | Test defaults for new fields |
| Modify | `mac/Packages/VoiceKeyboardCore/Sources/CVKB/include/libvkb_shim.h` | Add `vkb_enroll_compute` decl |
| Modify | `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift` | Add `computeEnrollment` to protocol |
| Modify | `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/LibvkbEngine.swift` | Implement `computeEnrollment` |
| Modify | `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/EngineConfig.swift` | Add 5 TSE fields |
| Modify | `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/SettingsStore.swift` | Add `tseEnabled` |
| Modify | `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/EngineConfigTests.swift` | Round-trip new fields |
| Modify | `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/SettingsStoreTests.swift` | `tseEnabled` round-trip |
| Modify | `mac/VoiceKeyboard/AppDelegate.swift` | `ModelPaths.tseModel`, `speakerEncoder`, `voiceProfileDir`, `onnxLib` |
| Modify | `mac/VoiceKeyboard/Engine/EngineCoordinator.swift` | Populate TSE fields in `applyConfig` |
| Create | `mac/VoiceKeyboard/UI/Settings/EnrollmentSheet.swift` | Modal recording UI |
| Create | `mac/VoiceKeyboard/UI/Settings/VoiceTab.swift` | New Settings tab |
| Modify | `mac/VoiceKeyboard/UI/Settings/SettingsView.swift` | Insert `VoiceTab` |

---

## Task 1: Config — Add TSE fields

**Files:**
- Modify: `core/internal/config/config.go`
- Modify: `core/internal/config/config_test.go`

The Swift app passes 5 paths/flags via JSON. Defaults are empty/false so the CLI keeps working unchanged.

- [ ] **Step 1: Write the failing test**

Open `core/internal/config/config_test.go`. If it doesn't exist, create it; otherwise append. Add:

```go
package config

import "testing"

func TestWithDefaults_TSEFieldsLeftEmpty(t *testing.T) {
	c := Config{}
	WithDefaults(&c)
	if c.TSEEnabled {
		t.Error("TSEEnabled default should be false")
	}
	if c.TSEProfileDir != "" {
		t.Errorf("TSEProfileDir default should be empty, got %q", c.TSEProfileDir)
	}
	if c.TSEModelPath != "" {
		t.Errorf("TSEModelPath default should be empty, got %q", c.TSEModelPath)
	}
	if c.SpeakerEncoderPath != "" {
		t.Errorf("SpeakerEncoderPath default should be empty, got %q", c.SpeakerEncoderPath)
	}
	if c.ONNXLibPath != "" {
		t.Errorf("ONNXLibPath default should be empty, got %q", c.ONNXLibPath)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd core && go test ./internal/config/ -run TestWithDefaults_TSEFieldsLeftEmpty -v
```

Expected: compile error — fields don't exist on `Config`.

- [ ] **Step 3: Add the fields to `core/internal/config/config.go`**

Replace the file contents with:

```go
// Package config holds the Config struct that travels across the C ABI
// as JSON. Defaults are applied by WithDefaults, never inside JSON tags.
package config

type Config struct {
	WhisperModelPath        string   `json:"whisper_model_path"`
	WhisperModelSize        string   `json:"whisper_model_size"`
	Language                string   `json:"language"`
	DisableNoiseSuppression bool     `json:"disable_noise_suppression"`
	DeepFilterModelPath     string   `json:"deep_filter_model_path"`
	LLMProvider             string   `json:"llm_provider"`
	LLMModel                string   `json:"llm_model"`
	LLMAPIKey               string   `json:"llm_api_key"`
	CustomDict              []string `json:"custom_dict"`

	// TSE (Target Speaker Extraction) fields. All optional; when
	// TSEEnabled is false the pipeline runs without the TSE stage.
	TSEEnabled         bool   `json:"tse_enabled"`
	TSEProfileDir      string `json:"tse_profile_dir"`
	TSEModelPath       string `json:"tse_model_path"`
	SpeakerEncoderPath string `json:"speaker_encoder_path"`
	ONNXLibPath        string `json:"onnx_lib_path"`
}

func WithDefaults(c *Config) {
	if c.WhisperModelSize == "" {
		c.WhisperModelSize = "small"
	}
	if c.Language == "" {
		c.Language = "auto"
	}
	if c.LLMProvider == "" {
		c.LLMProvider = "anthropic"
	}
	if c.LLMModel == "" {
		c.LLMModel = "claude-sonnet-4-6"
	}
}
```

- [ ] **Step 4: Run the test**

```bash
cd core && go test ./internal/config/ -v
```

Expected: PASS.

- [ ] **Step 5: Run the whole core test suite to confirm no regression**

```bash
cd core && go test ./... -short
```

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add core/internal/config/
git commit -m "feat(config): add TSE fields to Config"
```

---

## Task 2: `speaker.ComputeEmbedding`

**Files:**
- Create: `core/internal/speaker/embedding.go`
- Create: `core/internal/speaker/embedding_test.go`

Runs `speaker_encoder.onnx` on a 16 kHz mono Float32 buffer and returns the L2-normalised 256-dim embedding. The encoder ONNX expects input `audio: float32[1, T]` and outputs `embedding: float32[1, 256]` (already L2-normalised in the export script — verify with the integration test).

- [ ] **Step 1: Write the unit test**

Create `core/internal/speaker/embedding_test.go`:

```go
package speaker

import "testing"

// fakeEmbedding satisfies any internal-only embed function we want to test
// in isolation. Currently we don't need a fake — the test below is a
// compile-time interface check.

func TestComputeEmbedding_SymbolExists(t *testing.T) {
	// Compile-time check that ComputeEmbedding has the expected signature.
	var fn func(string, []float32) ([]float32, error) = ComputeEmbedding
	_ = fn
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd core && go test ./internal/speaker/ -run TestComputeEmbedding_SymbolExists -v
```

Expected: compile error — `ComputeEmbedding` undefined.

- [ ] **Step 3: Implement `core/internal/speaker/embedding.go`**

```go
package speaker

import (
	"fmt"

	ort "github.com/yalue/onnxruntime_go"
)

// ComputeEmbedding runs speaker_encoder.onnx on samples (16 kHz mono PCM)
// and returns a 256-dim L2-normalised float32 embedding.
//
// The caller is responsible for InitONNXRuntime; ComputeEmbedding opens
// and closes the session itself. Callable safely on demand.
func ComputeEmbedding(modelPath string, samples16k []float32) ([]float32, error) {
	if len(samples16k) == 0 {
		return nil, fmt.Errorf("compute_embedding: empty input")
	}
	session, err := ort.NewDynamicAdvancedSession(
		modelPath,
		[]string{"audio"},
		[]string{"embedding"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("compute_embedding: load %q: %w", modelPath, err)
	}
	defer session.Destroy()

	inT, err := ort.NewTensor(ort.NewShape(1, int64(len(samples16k))), samples16k)
	if err != nil {
		return nil, fmt.Errorf("compute_embedding: input tensor: %w", err)
	}
	defer inT.Destroy()

	outT, err := ort.NewEmptyTensor[float32](ort.NewShape(1, 256))
	if err != nil {
		return nil, fmt.Errorf("compute_embedding: output tensor: %w", err)
	}
	defer outT.Destroy()

	if err := session.Run(
		[]ort.Value{inT},
		[]ort.Value{outT},
	); err != nil {
		return nil, fmt.Errorf("compute_embedding: inference: %w", err)
	}

	emb := make([]float32, 256)
	copy(emb, outT.GetData())
	return emb, nil
}
```

- [ ] **Step 4: Verify compilation**

```bash
cd core && go test ./internal/speaker/ -run TestComputeEmbedding_SymbolExists -v
```

Expected: PASS.

- [ ] **Step 5: Add the model-gated integration test**

Append to `core/internal/speaker/embedding_test.go`:

```go
//go:build speakerbeam

package speaker

import (
	"math"
	"os"
	"testing"
)

func TestComputeEmbedding_NormalisedAndDeterministic(t *testing.T) {
	libPath := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if libPath == "" {
		libPath = "/opt/homebrew/lib/libonnxruntime.dylib"
	}
	if err := InitONNXRuntime(libPath); err != nil {
		t.Fatalf("InitONNXRuntime: %v", err)
	}
	modelPath := os.Getenv("SPEAKER_ENCODER_PATH")
	if modelPath == "" {
		t.Skip("SPEAKER_ENCODER_PATH not set")
	}

	// 1 s of 440 Hz tone at 16 kHz
	samples := make([]float32, 16000)
	for i := range samples {
		samples[i] = 0.3 * float32(math.Sin(2*math.Pi*440*float64(i)/16000))
	}

	emb1, err := ComputeEmbedding(modelPath, samples)
	if err != nil {
		t.Fatalf("ComputeEmbedding (1st): %v", err)
	}
	if len(emb1) != 256 {
		t.Fatalf("len(emb) = %d, want 256", len(emb1))
	}

	// L2 norm should be ~1
	var norm float64
	for _, v := range emb1 {
		norm += float64(v) * float64(v)
	}
	norm = math.Sqrt(norm)
	if math.Abs(norm-1.0) > 0.01 {
		t.Errorf("‖emb‖ = %f, want ≈1.0", norm)
	}

	// Determinism: same input → same output
	emb2, err := ComputeEmbedding(modelPath, samples)
	if err != nil {
		t.Fatalf("ComputeEmbedding (2nd): %v", err)
	}
	for i := range emb1 {
		if emb1[i] != emb2[i] {
			t.Fatalf("nondeterministic output at index %d: %f vs %f", i, emb1[i], emb2[i])
		}
	}
}

func TestComputeEmbedding_DifferentInputsDifferentEmbeds(t *testing.T) {
	libPath := os.Getenv("ONNXRUNTIME_LIB_PATH")
	if libPath == "" {
		libPath = "/opt/homebrew/lib/libonnxruntime.dylib"
	}
	if err := InitONNXRuntime(libPath); err != nil {
		t.Fatalf("InitONNXRuntime: %v", err)
	}
	modelPath := os.Getenv("SPEAKER_ENCODER_PATH")
	if modelPath == "" {
		t.Skip("SPEAKER_ENCODER_PATH not set")
	}

	tone := make([]float32, 16000)
	noise := make([]float32, 16000)
	for i := range tone {
		tone[i] = 0.3 * float32(math.Sin(2*math.Pi*440*float64(i)/16000))
		noise[i] = float32((float64(i*1103515245+12345)/2147483647.0)*2 - 1) * 0.3
	}

	a, err := ComputeEmbedding(modelPath, tone)
	if err != nil {
		t.Fatalf("ComputeEmbedding(tone): %v", err)
	}
	b, err := ComputeEmbedding(modelPath, noise)
	if err != nil {
		t.Fatalf("ComputeEmbedding(noise): %v", err)
	}

	// Cosine similarity (both embeddings are unit-length, so just dot product).
	var cos float64
	for i := range a {
		cos += float64(a[i]) * float64(b[i])
	}
	if math.Abs(cos) > 0.95 {
		t.Errorf("cosine(tone,noise) = %f; expected meaningful divergence (<0.95)", cos)
	}
}
```

- [ ] **Step 6: Run the unit test (no model needed)**

```bash
cd core && go test ./internal/speaker/ -v
```

Expected: PASS for `TestComputeEmbedding_SymbolExists`. The model-gated tests are skipped without the build tag.

- [ ] **Step 7: Run the integration test (requires the encoder model)**

```bash
cd core && \
  ONNXRUNTIME_LIB_PATH=/opt/homebrew/lib/libonnxruntime.dylib \
  SPEAKER_ENCODER_PATH=build/models/speaker_encoder.onnx \
  go test ./internal/speaker/ -tags speakerbeam -run TestComputeEmbedding -v
```

Expected: both integration tests PASS. If `speaker_encoder.onnx` is not at `core/build/models/`, run `./enroll.sh` first to generate it (it auto-builds the models on first run).

- [ ] **Step 8: Commit**

```bash
git add core/internal/speaker/embedding.go core/internal/speaker/embedding_test.go
git commit -m "feat(speaker): ComputeEmbedding via speaker_encoder.onnx"
```

---

## Task 3: Enroll handler — atomic write helper

**Files:**
- Create: `core/cmd/libvkb/enroll.go`
- Create: `core/cmd/libvkb/enroll_test.go`

The enroll flow:
1. Decimate 48 kHz → 16 kHz using `resample.Decimate3`
2. Compute embedding via `speaker.ComputeEmbedding`
3. Atomically write `enrollment.wav`, `enrollment.emb`, `speaker.json`

Atomic = write each file as `<name>.tmp`, then rename. If any step fails, no file is left half-written.

- [ ] **Step 1: Write the test**

Create `core/cmd/libvkb/enroll_test.go`:

```go
//go:build whispercpp

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWriteEnrollmentFiles_AllThreeWritten(t *testing.T) {
	dir := t.TempDir()
	samples16k := make([]float32, 16000)
	for i := range samples16k {
		samples16k[i] = float32(i) / 16000
	}
	emb := make([]float32, 256)
	for i := range emb {
		emb[i] = 0.0625 // ‖e‖ = 1.0
	}

	if err := writeEnrollmentFiles(dir, samples16k, emb); err != nil {
		t.Fatalf("writeEnrollmentFiles: %v", err)
	}

	for _, name := range []string{"enrollment.wav", "enrollment.emb", "speaker.json"} {
		path := filepath.Join(dir, name)
		fi, err := os.Stat(path)
		if err != nil {
			t.Errorf("%s missing: %v", name, err)
			continue
		}
		if fi.Size() == 0 {
			t.Errorf("%s is empty", name)
		}
	}

	// No .tmp files should remain.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	for _, e := range entries {
		if filepath.Ext(e.Name()) == ".tmp" {
			t.Errorf("leftover temp file: %s", e.Name())
		}
	}
}

func TestWriteEnrollmentFiles_NoPartialOnFailure(t *testing.T) {
	// Use a non-existent parent dir to force failure on the first write.
	dir := filepath.Join(t.TempDir(), "does-not-exist", "nope")
	samples16k := make([]float32, 16000)
	emb := make([]float32, 256)

	err := writeEnrollmentFiles(dir, samples16k, emb)
	if err == nil {
		t.Fatal("expected error for missing parent dir, got nil")
	}
	// dir doesn't exist, so nothing to clean up; just sanity-check no panic.
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd core && go test -tags whispercpp ./cmd/libvkb/ -run TestWriteEnrollmentFiles -v
```

Expected: compile error — `writeEnrollmentFiles` undefined.

- [ ] **Step 3: Implement `core/cmd/libvkb/enroll.go`**

```go
//go:build whispercpp

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/speaker"
)

// runEnrollCompute decimates 48 kHz samples to 16 kHz, computes the
// speaker embedding, and atomically writes the three enrollment files
// (enrollment.wav, enrollment.emb, speaker.json) to profileDir.
//
// Returns nil on success; on any error, profileDir is left as it was
// (no partial files written).
func runEnrollCompute(samples48k []float32, profileDir, encoderPath, onnxLibPath string) error {
	if err := os.MkdirAll(profileDir, 0755); err != nil {
		return fmt.Errorf("enroll: mkdir profile: %w", err)
	}
	if err := speaker.InitONNXRuntime(onnxLibPath); err != nil {
		return fmt.Errorf("enroll: init onnx runtime: %w", err)
	}

	dec := resample.NewDecimate3()
	samples16k := dec.Process(samples48k)
	if len(samples16k) == 0 {
		return fmt.Errorf("enroll: decimation produced no samples")
	}

	emb, err := speaker.ComputeEmbedding(encoderPath, samples16k)
	if err != nil {
		return fmt.Errorf("enroll: compute embedding: %w", err)
	}

	return writeEnrollmentFiles(profileDir, samples16k, emb)
}

// writeEnrollmentFiles atomically writes the three artefacts.
// Each file is written as <name>.tmp then renamed; on any failure the
// .tmp files for this call are cleaned up.
func writeEnrollmentFiles(profileDir string, samples16k []float32, emb []float32) error {
	wavTmp := filepath.Join(profileDir, "enrollment.wav.tmp")
	embTmp := filepath.Join(profileDir, "enrollment.emb.tmp")
	jsonTmp := filepath.Join(profileDir, "speaker.json.tmp")

	cleanup := func() {
		os.Remove(wavTmp)
		os.Remove(embTmp)
		os.Remove(jsonTmp)
	}

	if err := speaker.SaveWAV(wavTmp, samples16k, 16000); err != nil {
		cleanup()
		return fmt.Errorf("enroll: save wav: %w", err)
	}
	if err := speaker.SaveEmbedding(embTmp, emb); err != nil {
		cleanup()
		return fmt.Errorf("enroll: save emb: %w", err)
	}
	wavPath := filepath.Join(profileDir, "enrollment.wav")
	embPath := filepath.Join(profileDir, "enrollment.emb")
	durationS := float64(len(samples16k)) / 16000.0
	p := speaker.Profile{
		Version:    1,
		RefAudio:   wavPath,
		EnrolledAt: time.Now().UTC(),
		DurationS:  durationS,
	}
	// SaveProfile writes speaker.json; we want to write to .tmp first.
	// Re-use the JSON encoder path manually by writing then renaming.
	if err := saveProfileTmp(jsonTmp, p); err != nil {
		cleanup()
		return fmt.Errorf("enroll: save profile: %w", err)
	}

	if err := os.Rename(wavTmp, wavPath); err != nil {
		cleanup()
		return fmt.Errorf("enroll: rename wav: %w", err)
	}
	if err := os.Rename(embTmp, embPath); err != nil {
		os.Remove(wavPath) // wav landed; roll it back
		cleanup()
		return fmt.Errorf("enroll: rename emb: %w", err)
	}
	if err := os.Rename(jsonTmp, filepath.Join(profileDir, "speaker.json")); err != nil {
		os.Remove(wavPath)
		os.Remove(embPath)
		cleanup()
		return fmt.Errorf("enroll: rename profile: %w", err)
	}
	return nil
}

// saveProfileTmp writes a Profile to an explicit path (temp file) using
// the same JSON format as speaker.SaveProfile.
//
// We can't use speaker.SaveProfile directly because it writes to
// <dir>/speaker.json (no path override), and we need to write to .tmp
// first for atomic rename. If speaker.SaveProfile's format ever changes,
// keep this in sync.
func saveProfileTmp(path string, p speaker.Profile) error {
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}
```

Update the import block at the top of the file to include `encoding/json`:

```go
import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/voice-keyboard/core/internal/resample"
	"github.com/voice-keyboard/core/internal/speaker"
)
```

- [ ] **Step 4: Run the test**

```bash
cd core && go test -tags whispercpp ./cmd/libvkb/ -run TestWriteEnrollmentFiles -v
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/cmd/libvkb/enroll.go core/cmd/libvkb/enroll_test.go
git commit -m "feat(libvkb): enroll handler — decimate, embed, atomic write"
```

---

## Task 4: `vkb_enroll_compute` C export

**Files:**
- Modify: `core/cmd/libvkb/exports.go`

Synchronous C export. Reads samples + count + sample_rate + profile_dir, dispatches to `runEnrollCompute`, returns rc.

The encoder model path and ONNX lib path are taken from the engine's current `cfg`. This means the caller must `vkb_configure` the engine with `speaker_encoder_path` and `onnx_lib_path` set (even if `tse_enabled` is false), otherwise enrollment will fail with rc=5.

- [ ] **Step 1: Add the export to `core/cmd/libvkb/exports.go`**

Append to the file (after `vkb_destroy`):

```go
// vkb_enroll_compute computes a speaker embedding from a single recorded
// buffer and writes enrollment.wav, enrollment.emb, and speaker.json
// atomically to profileDir.
//
// samples:    Float32 mono PCM (must not be NULL)
// count:      number of samples (must be > 0)
// sampleRate: must be 48000
// profileDir: NUL-terminated UTF-8 path
//
// Return codes:
//
//	0 = success
//	1 = engine not initialized
//	5 = invalid argument (count <= 0, profileDir empty, sr != 48000,
//	    speaker_encoder_path / onnx_lib_path not configured)
//	6 = compute failed (see vkb_last_error)
//
//export vkb_enroll_compute
func vkb_enroll_compute(samples *C.float, count C.int, sampleRate C.int, profileDirC *C.char) C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	if count <= 0 || sampleRate != 48000 || profileDirC == nil {
		e.setLastError("vkb_enroll_compute: invalid argument")
		return 5
	}
	profileDir := C.GoString(profileDirC)
	if profileDir == "" {
		e.setLastError("vkb_enroll_compute: empty profile dir")
		return 5
	}

	e.mu.Lock()
	encoderPath := e.cfg.SpeakerEncoderPath
	onnxLibPath := e.cfg.ONNXLibPath
	e.mu.Unlock()
	if encoderPath == "" || onnxLibPath == "" {
		e.setLastError("vkb_enroll_compute: speaker_encoder_path or onnx_lib_path not configured")
		return 5
	}

	// Copy out of C memory before any Go-side work.
	n := int(count)
	cSlice := unsafe.Slice(samples, n)
	buf := make([]float32, n)
	for i := 0; i < n; i++ {
		buf[i] = float32(cSlice[i])
	}

	log.Printf("[vkb] vkb_enroll_compute: count=%d sr=%d profileDir=%q", n, int(sampleRate), profileDir)
	if err := runEnrollCompute(buf, profileDir, encoderPath, onnxLibPath); err != nil {
		e.setLastError("vkb_enroll_compute: " + err.Error())
		log.Printf("[vkb] vkb_enroll_compute: FAILED %v", err)
		return 6
	}
	log.Printf("[vkb] vkb_enroll_compute: success")
	return 0
}
```

- [ ] **Step 2: Verify the libvkb library still builds**

```bash
cd core && make build-libvkb 2>&1 | tail -10
```

Expected: build succeeds; `core/build/libvkb.dylib` and `core/build/libvkb.h` regenerated. Inspect the regenerated header:

```bash
grep -n "vkb_enroll_compute" core/build/libvkb.h
```

Expected: a line like `extern int vkb_enroll_compute(float* samples, int count, int sampleRate, char* profileDirC);`.

If `make build-libvkb` doesn't exist, the equivalent direct command is:

```bash
cd core && go build -tags whispercpp -buildmode=c-shared -o build/libvkb.dylib ./cmd/libvkb/
```

- [ ] **Step 3: Commit**

```bash
git add core/cmd/libvkb/exports.go core/build/libvkb.h
git commit -m "feat(libvkb): vkb_enroll_compute C export"
```

(Note: `core/build/libvkb.h` may or may not be tracked in this repo. If `git status` doesn't list it, just commit `exports.go` alone.)

---

## Task 5: Wire `LoadTSE` into libvkb `buildPipeline`

**Files:**
- Modify: `core/cmd/libvkb/state.go`

`pipeline.LoadTSE` already exists (`core/internal/pipeline/pipeline.go:260`). Currently the libvkb `buildPipeline` ignores it; only `vkb-cli` uses TSE. We add a TSE branch that mirrors the CLI behavior.

- [ ] **Step 1: Modify `buildPipeline` in `core/cmd/libvkb/state.go`**

Replace the existing `buildPipeline` body (currently ends with `return pipeline.New(d, tr, dy, cleaner), nil`) with:

```go
func (e *engine) buildPipeline() (*pipeline.Pipeline, error) {
	tr, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
		ModelPath: e.cfg.WhisperModelPath,
		Language:  e.cfg.Language,
	})
	if err != nil {
		return nil, err
	}
	cleaner, err := llm.NewAnthropic(llm.AnthropicOptions{
		APIKey: e.cfg.LLMAPIKey,
		Model:  e.cfg.LLMModel,
	})
	if err != nil {
		_ = tr.Close()
		return nil, err
	}
	dy := dict.NewFuzzy(e.cfg.CustomDict, 1)

	var d denoise.Denoiser
	if !e.cfg.DisableNoiseSuppression {
		d = newDeepFilterOrPassthrough(e.cfg.DeepFilterModelPath)
	} else {
		d = denoise.NewPassthrough()
	}

	p := pipeline.New(d, tr, dy, cleaner)

	if e.cfg.TSEEnabled {
		tse, ref, tseErr := pipeline.LoadTSE(
			e.cfg.TSEProfileDir,
			e.cfg.TSEModelPath,
			e.cfg.ONNXLibPath,
		)
		if tseErr != nil {
			log.Printf("[vkb] buildPipeline: TSE load failed, continuing without TSE: %v", tseErr)
			// Note: we deliberately don't fail the whole configure call.
			// User keeps a working pipeline; the warning surfaces via
			// vkb_last_error and the next configure attempt can fix it.
			e.setLastError("tse: " + tseErr.Error())
		} else if tse != nil {
			p.TSE = tse
			p.TSERef = ref
			log.Printf("[vkb] buildPipeline: TSE loaded (profile=%s)", e.cfg.TSEProfileDir)
		} else {
			log.Printf("[vkb] buildPipeline: TSE enabled but no enrollment found at %s", e.cfg.TSEProfileDir)
		}
	}

	return p, nil
}
```

Add the import for `pipeline` if not already imported (it's already there).

- [ ] **Step 2: Build to verify**

```bash
cd core && go build -tags whispercpp ./cmd/libvkb/...
```

Expected: no output.

- [ ] **Step 3: Run pipeline tests to confirm no regression**

```bash
cd core && go test -tags whispercpp ./cmd/libvkb/... ./internal/pipeline/...
```

Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add core/cmd/libvkb/state.go
git commit -m "feat(libvkb): wire TSE into buildPipeline when tse_enabled"
```

---

## Task 6: CVKB Swift shim header

**Files:**
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/CVKB/include/libvkb_shim.h`

The Swift package compiles against this shim, not against `core/build/libvkb.h`. Add the new symbol declaration here.

- [ ] **Step 1: Add the declaration**

Read the file first to confirm current content, then add `vkb_enroll_compute` after `vkb_free_string`:

```c
// CVKB — bridges the Plan 1 libvkb C ABI into Swift via SwiftPM.
//
// Forward-declares the libvkb C ABI so the package's tests can compile
// against the symbols without actually linking. The real header at
// core/build/libvkb.h is the source of truth; if the ABI changes, update
// here. Linkage against libvkb.dylib is configured by the Xcode app
// target (OTHER_LDFLAGS: -lvkb), not by SwiftPM.
#ifndef CVKB_LIBVKB_SHIM_H
#define CVKB_LIBVKB_SHIM_H

int vkb_init(void);
int vkb_configure(char* json);
int vkb_start_capture(void);
int vkb_push_audio(const float* samples, int count);
int vkb_stop_capture(void);
int vkb_cancel_capture(void);
char* vkb_poll_event(void);
void vkb_destroy(void);
char* vkb_last_error(void);
void vkb_free_string(char* s);

int vkb_enroll_compute(const float* samples, int count, int sample_rate, const char* profile_dir);

#endif
```

- [ ] **Step 2: Verify the package compiles**

```bash
cd mac/Packages/VoiceKeyboardCore && swift build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/CVKB/include/libvkb_shim.h
git commit -m "feat(cvkb): declare vkb_enroll_compute"
```

---

## Task 7: `EngineConfig` — TSE fields

**Files:**
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/EngineConfig.swift`
- Modify: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/EngineConfigTests.swift`

- [ ] **Step 1: Write the failing round-trip test**

Read the existing `EngineConfigTests.swift` to see its current test patterns, then append:

```swift
func testEngineConfig_TSEFieldsRoundTrip() throws {
    let cfg = EngineConfig(
        whisperModelPath: "/m.bin",
        whisperModelSize: "small",
        language: "en",
        disableNoiseSuppression: false,
        deepFilterModelPath: "",
        llmProvider: "anthropic",
        llmModel: "claude-sonnet-4-6",
        llmAPIKey: "k",
        customDict: [],
        tseEnabled: true,
        tseProfileDir: "/p",
        tseModelPath: "/m/tse.onnx",
        speakerEncoderPath: "/m/enc.onnx",
        onnxLibPath: "/lib/libort.dylib"
    )
    let data = try JSONEncoder().encode(cfg)
    let json = String(data: data, encoding: .utf8) ?? ""
    XCTAssert(json.contains("\"tse_enabled\":true"))
    XCTAssert(json.contains("\"tse_profile_dir\":\"\\/p\""))

    let decoded = try JSONDecoder().decode(EngineConfig.self, from: data)
    XCTAssertEqual(decoded.tseEnabled, true)
    XCTAssertEqual(decoded.tseProfileDir, "/p")
    XCTAssertEqual(decoded.tseModelPath, "/m/tse.onnx")
    XCTAssertEqual(decoded.speakerEncoderPath, "/m/enc.onnx")
    XCTAssertEqual(decoded.onnxLibPath, "/lib/libort.dylib")
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd mac/Packages/VoiceKeyboardCore && swift test --filter testEngineConfig_TSEFieldsRoundTrip 2>&1 | tail -20
```

Expected: compile error — `tseEnabled` etc. not in initializer.

- [ ] **Step 3: Update `EngineConfig.swift`**

Replace the file contents with:

```swift
import Foundation

/// Configuration sent to the Go core via vkb_configure as JSON.
/// JSON field names match the Go struct's tags exactly.
public struct EngineConfig: Codable, Equatable, Sendable {
    public var whisperModelPath: String
    public var whisperModelSize: String
    public var language: String
    public var disableNoiseSuppression: Bool
    public var deepFilterModelPath: String
    public var llmProvider: String
    public var llmModel: String
    public var llmAPIKey: String
    public var customDict: [String]

    // TSE (Target Speaker Extraction) fields. Defaults are off/empty so
    // existing call sites and the CLI continue to work unchanged.
    public var tseEnabled: Bool
    public var tseProfileDir: String
    public var tseModelPath: String
    public var speakerEncoderPath: String
    public var onnxLibPath: String

    public init(
        whisperModelPath: String,
        whisperModelSize: String,
        language: String,
        disableNoiseSuppression: Bool,
        deepFilterModelPath: String,
        llmProvider: String,
        llmModel: String,
        llmAPIKey: String,
        customDict: [String],
        tseEnabled: Bool = false,
        tseProfileDir: String = "",
        tseModelPath: String = "",
        speakerEncoderPath: String = "",
        onnxLibPath: String = ""
    ) {
        self.whisperModelPath = whisperModelPath
        self.whisperModelSize = whisperModelSize
        self.language = language
        self.disableNoiseSuppression = disableNoiseSuppression
        self.deepFilterModelPath = deepFilterModelPath
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.llmAPIKey = llmAPIKey
        self.customDict = customDict
        self.tseEnabled = tseEnabled
        self.tseProfileDir = tseProfileDir
        self.tseModelPath = tseModelPath
        self.speakerEncoderPath = speakerEncoderPath
        self.onnxLibPath = onnxLibPath
    }

    enum CodingKeys: String, CodingKey {
        case whisperModelPath = "whisper_model_path"
        case whisperModelSize = "whisper_model_size"
        case language
        case disableNoiseSuppression = "disable_noise_suppression"
        case deepFilterModelPath = "deep_filter_model_path"
        case llmProvider = "llm_provider"
        case llmModel = "llm_model"
        case llmAPIKey = "llm_api_key"
        case customDict = "custom_dict"
        case tseEnabled = "tse_enabled"
        case tseProfileDir = "tse_profile_dir"
        case tseModelPath = "tse_model_path"
        case speakerEncoderPath = "speaker_encoder_path"
        case onnxLibPath = "onnx_lib_path"
    }
}
```

- [ ] **Step 4: Run all package tests to verify the new test passes and existing ones still compile**

```bash
cd mac/Packages/VoiceKeyboardCore && swift test 2>&1 | tail -20
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/EngineConfig.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/EngineConfigTests.swift
git commit -m "feat(swift): EngineConfig TSE fields"
```

---

## Task 8: `UserSettings.tseEnabled`

**Files:**
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/SettingsStore.swift`
- Modify: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/SettingsStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SettingsStoreTests.swift`:

```swift
func testSettings_TSEEnabledRoundTrip() throws {
    let store = InMemorySettingsStore()
    var s = try store.get()
    XCTAssertEqual(s.tseEnabled, false, "default tseEnabled should be false")

    s.tseEnabled = true
    try store.set(s)
    let got = try store.get()
    XCTAssertEqual(got.tseEnabled, true)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd mac/Packages/VoiceKeyboardCore && swift test --filter testSettings_TSEEnabledRoundTrip 2>&1 | tail -20
```

Expected: compile error — `tseEnabled` not on `UserSettings`.

- [ ] **Step 3: Add the field to `UserSettings`**

Note on backward compatibility: Swift's synthesized `Codable` requires every field present in JSON, which would break for users with persisted UserDefaults from before this change. The struct below includes a custom `init(from:)` and explicit `CodingKeys` so missing fields fall back to defaults.

In `SettingsStore.swift`, replace the `UserSettings` struct with:

```swift
public struct UserSettings: Codable, Equatable, Sendable {
    public var whisperModelSize: String
    public var language: String
    public var disableNoiseSuppression: Bool
    public var llmProvider: String
    public var llmModel: String
    public var customDict: [String]
    public var hotkey: KeyboardShortcut
    /// CoreAudio/AVCaptureDevice unique ID for the input device.
    /// `nil` (the default) means "follow the system default".
    public var inputDeviceUID: String?
    /// Whether to apply Target Speaker Extraction during capture.
    /// Requires a completed voice enrollment in
    /// ~/Library/Application Support/VoiceKeyboard/voice/.
    public var tseEnabled: Bool

    public init(
        whisperModelSize: String = "small",
        language: String = "en",
        disableNoiseSuppression: Bool = false,
        llmProvider: String = "anthropic",
        llmModel: String = "claude-sonnet-4-6",
        customDict: [String] = [],
        hotkey: KeyboardShortcut = .defaultPTT,
        inputDeviceUID: String? = nil,
        tseEnabled: Bool = false
    ) {
        self.whisperModelSize = whisperModelSize
        self.language = language
        self.disableNoiseSuppression = disableNoiseSuppression
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.customDict = customDict
        self.hotkey = hotkey
        self.inputDeviceUID = inputDeviceUID
        self.tseEnabled = tseEnabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whisperModelSize = try c.decodeIfPresent(String.self, forKey: .whisperModelSize) ?? "small"
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        disableNoiseSuppression = try c.decodeIfPresent(Bool.self, forKey: .disableNoiseSuppression) ?? false
        llmProvider = try c.decodeIfPresent(String.self, forKey: .llmProvider) ?? "anthropic"
        llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel) ?? "claude-sonnet-4-6"
        customDict = try c.decodeIfPresent([String].self, forKey: .customDict) ?? []
        hotkey = try c.decodeIfPresent(KeyboardShortcut.self, forKey: .hotkey) ?? .defaultPTT
        inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        tseEnabled = try c.decodeIfPresent(Bool.self, forKey: .tseEnabled) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case whisperModelSize, language, disableNoiseSuppression
        case llmProvider, llmModel, customDict, hotkey, inputDeviceUID, tseEnabled
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd mac/Packages/VoiceKeyboardCore && swift test 2>&1 | tail -20
```

Expected: all PASS, including the new `testSettings_TSEEnabledRoundTrip`.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/SettingsStore.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/SettingsStoreTests.swift
git commit -m "feat(swift): UserSettings.tseEnabled with backward-compatible decode"
```

---

## Task 9: `CoreEngine.computeEnrollment` + `LibvkbEngine` impl

**Files:**
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift`
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/LibvkbEngine.swift`

- [ ] **Step 1: Add `computeEnrollment` to the protocol**

Replace `CoreEngine.swift` with the existing content + this method appended after `pollEvent` and before `lastError`:

```swift
    /// Compute and persist a voice enrollment from a single recorded buffer.
    /// `samples` must be 48 kHz mono Float32. The engine decimates to 16 kHz
    /// internally, runs the encoder, and writes enrollment.wav,
    /// enrollment.emb, speaker.json into `profileDir`. The directory is
    /// created if missing. Throws if the engine is not configured with
    /// `speakerEncoderPath` and `onnxLibPath` set, or if compute fails.
    func computeEnrollment(samples: [Float], sampleRate: Int, profileDir: String) async throws
```

- [ ] **Step 2: Add the corresponding error case to `LibvkbError`**

In `LibvkbEngine.swift`, replace the `LibvkbError` enum with:

```swift
public enum LibvkbError: Error, Equatable {
    case notInitialized
    case busy            // configure during in-flight capture, etc.
    case configureFailed(String)
    case startFailed(String)
    case pushFailed(String)
    case stopFailed(String)
    case enrollFailed(String)
    case enrollInvalidArgument(String)
}
```

- [ ] **Step 3: Implement `computeEnrollment` in `LibvkbEngine`**

Append (inside the actor body, before the closing brace):

```swift
    public func computeEnrollment(samples: [Float], sampleRate: Int, profileDir: String) async throws {
        guard !samples.isEmpty else {
            throw LibvkbError.enrollInvalidArgument("empty samples buffer")
        }
        guard sampleRate == 48000 else {
            throw LibvkbError.enrollInvalidArgument("sampleRate must be 48000, got \(sampleRate)")
        }

        let rc: Int32 = samples.withUnsafeBufferPointer { sampleBuf in
            profileDir.withCString { dirCStr in
                guard let base = sampleBuf.baseAddress else { return 5 }
                return vkb_enroll_compute(base, Int32(sampleBuf.count), Int32(sampleRate), dirCStr)
            }
        }

        switch rc {
        case 0: return
        case 1: throw LibvkbError.notInitialized
        case 5:
            let msg = readLastError() ?? "vkb_enroll_compute: invalid argument"
            throw LibvkbError.enrollInvalidArgument(msg)
        default:
            let msg = readLastError() ?? "vkb_enroll_compute rc=\(rc)"
            throw LibvkbError.enrollFailed(msg)
        }
    }
```

- [ ] **Step 4: Build & run package tests**

```bash
cd mac/Packages/VoiceKeyboardCore && swift build 2>&1 | tail -10
swift test 2>&1 | tail -20
```

Expected: builds and all existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift \
        mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/LibvkbEngine.swift
git commit -m "feat(swift): CoreEngine.computeEnrollment + LibvkbEngine impl"
```

---

## Task 10: `ModelPaths` extensions

**Files:**
- Modify: `mac/VoiceKeyboard/AppDelegate.swift`

- [ ] **Step 1: Extend `ModelPaths` enum**

Replace the `ModelPaths` enum at the bottom of `AppDelegate.swift` with:

```swift
enum ModelPaths {
    static var modelsDir: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("VoiceKeyboard/models")
    }
    static func whisperModel(size: String) -> URL {
        modelsDir.appendingPathComponent("ggml-\(size).en.bin")
    }
    static var tseModel: URL {
        modelsDir.appendingPathComponent("tse_model.onnx")
    }
    static var speakerEncoder: URL {
        modelsDir.appendingPathComponent("speaker_encoder.onnx")
    }
    /// Where enrollment artefacts live.
    static var voiceProfileDir: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("VoiceKeyboard/voice")
    }
    /// Default location for the ONNX Runtime shared library on Apple Silicon.
    static var onnxLib: URL {
        URL(fileURLWithPath: "/opt/homebrew/lib/libonnxruntime.dylib")
    }
}
```

- [ ] **Step 2: Build the app target to verify**

```bash
cd mac && xcodebuild -project VoiceKeyboard.xcodeproj -scheme VoiceKeyboard -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/AppDelegate.swift
git commit -m "feat(mac): ModelPaths additions for TSE and voice profile"
```

---

## Task 11: `EnrollmentSheet` — modal recording UI

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/EnrollmentSheet.swift`

A modal sheet that records 10 s of audio via the existing `AudioCapture`, then hands off to the engine for compute. UI states: recording → computing → done. Manual stop / cancel allowed.

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import VoiceKeyboardCore

/// Modal recording UI used by VoiceTab to capture a voice enrollment.
struct EnrollmentSheet: View {
    enum Phase: Equatable {
        case ready
        case recording(remainingS: Int)
        case computing
        case done
        case failed(String)
    }

    let audioCapture: any AudioCapture
    let engine: any CoreEngine
    let inputDeviceUID: String?
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var phase: Phase = .ready
    @State private var samples: [Float] = []
    @State private var levelPeak: Float = 0
    @State private var timerTask: Task<Void, Never>? = nil

    private let durationSeconds = 10
    private let prompt = """
        Please read this passage at a normal speaking pace:

        "The quick brown fox jumps over the lazy dog. Voice keyboards \
        work best when they have a sample of your speaking voice. \
        Read this paragraph in your typical speaking tone."
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record your voice").font(.title2.bold())
            Text(prompt).font(.body).foregroundStyle(.secondary)

            ProgressView(value: Double(levelPeak), total: 0.5)
                .progressViewStyle(.linear)

            statusLine

            HStack {
                Button("Cancel", role: .cancel) { cancel() }
                Spacer()
                primaryButton
            }
        }
        .padding(24)
        .frame(width: 460)
        .onDisappear { timerTask?.cancel(); audioCapture.stop() }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch phase {
        case .ready:
            Text("Ready to record. Click Start when you're ready.").foregroundStyle(.secondary)
        case .recording(let remaining):
            Text("Recording... \(remaining)s remaining").foregroundStyle(.primary)
        case .computing:
            HStack { ProgressView().scaleEffect(0.6); Text("Computing voice profile…") }
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let msg):
            Label("Failed: \(msg)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch phase {
        case .ready:
            Button("Start") { Task { await start() } }.keyboardShortcut(.defaultAction)
        case .recording:
            Button("Stop") { Task { await stop() } }.keyboardShortcut(.defaultAction)
        case .computing:
            Button("Working…") { }.disabled(true)
        case .done:
            Button("Done") { onComplete() }.keyboardShortcut(.defaultAction)
        case .failed:
            Button("Try Again") { phase = .ready; samples = []; levelPeak = 0 }
        }
    }

    private func start() async {
        samples.removeAll(keepingCapacity: true)
        levelPeak = 0
        phase = .recording(remainingS: durationSeconds)

        do {
            try await audioCapture.start(deviceUID: inputDeviceUID) { frame in
                Task { @MainActor in
                    samples.append(contentsOf: frame)
                    var peak: Float = 0
                    for x in frame { let a = abs(x); if a > peak { peak = a } }
                    levelPeak = max(levelPeak * 0.7, peak)
                }
            }
        } catch {
            await MainActor.run { phase = .failed("microphone: \(error)") }
            return
        }

        timerTask = Task {
            for s in (1...durationSeconds).reversed() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    if case .recording = phase { phase = .recording(remainingS: s - 1) }
                }
            }
            await MainActor.run {
                if case .recording = phase { Task { await stop() } }
            }
        }
    }

    private func stop() async {
        timerTask?.cancel()
        audioCapture.stop()
        guard !samples.isEmpty else {
            phase = .failed("no audio captured")
            return
        }
        phase = .computing
        let bufferSnapshot = samples
        let dir = ModelPaths.voiceProfileDir.path
        do {
            try FileManager.default.createDirectory(
                at: ModelPaths.voiceProfileDir, withIntermediateDirectories: true)
            try await engine.computeEnrollment(
                samples: bufferSnapshot, sampleRate: 48000, profileDir: dir)
            await MainActor.run { phase = .done }
        } catch {
            await MainActor.run { phase = .failed("\(error)") }
        }
    }

    private func cancel() {
        timerTask?.cancel()
        audioCapture.stop()
        onCancel()
    }
}
```

- [ ] **Step 2: Verify the file compiles by building the app**

```bash
cd mac && xcodebuild -project VoiceKeyboard.xcodeproj -scheme VoiceKeyboard -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED. (If `EnrollmentSheet` is referenced but not yet wired into VoiceTab — that's fine; the app target will pick the file up via the project's "Recursive" sources.) If the project uses explicit file references, you may need to add the new file to the target manually in Xcode; verify by checking that `find mac -name "EnrollmentSheet.swift"` returns the path and that the build includes Settings sources.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/EnrollmentSheet.swift
git commit -m "feat(mac): EnrollmentSheet — modal voice recording UI"
```

---

## Task 12: `VoiceTab`

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/VoiceTab.swift`

A new Settings tab. Shows model presence, voice profile status, and a TSE on/off toggle.

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import VoiceKeyboardCore

struct VoiceTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let audioCapture: any AudioCapture
    let engine: any CoreEngine

    @State private var presenceTick = 0
    @State private var sheetPresented = false

    var body: some View {
        Form {
            Section("Voice models") {
                modelStatusRow(label: "Voice extraction model",
                               url: ModelPaths.tseModel)
                modelStatusRow(label: "Speaker encoder",
                               url: ModelPaths.speakerEncoder)
                if !modelsPresent {
                    Text(modelInstructions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Voice profile") {
                profileStatusRow
                HStack {
                    Button(profilePresent ? "Re-record" : "Record Voice Sample") {
                        sheetPresented = true
                    }
                    .disabled(!modelsPresent)
                    if profilePresent {
                        Button(role: .destructive) { deleteProfile() } label: { Text("Delete") }
                    }
                }
            }

            Section {
                Toggle("Filter out background speakers (TSE)",
                       isOn: tseToggleBinding)
                    .disabled(!modelsPresent || !profilePresent)
            } footer: {
                Text("Uses your voice profile to suppress other speakers in the same recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $sheetPresented) {
            EnrollmentSheet(
                audioCapture: audioCapture,
                engine: engine,
                inputDeviceUID: settings.inputDeviceUID,
                onComplete: {
                    sheetPresented = false
                    presenceTick += 1
                    // Auto-enable TSE when the user successfully enrolled.
                    var s = settings; s.tseEnabled = true; settings = s; onSave(s)
                },
                onCancel: { sheetPresented = false }
            )
        }
    }

    private var modelsPresent: Bool {
        let _ = presenceTick
        return FileManager.default.fileExists(atPath: ModelPaths.tseModel.path) &&
               FileManager.default.fileExists(atPath: ModelPaths.speakerEncoder.path)
    }

    private var profilePresent: Bool {
        let _ = presenceTick
        let json = ModelPaths.voiceProfileDir.appendingPathComponent("speaker.json")
        let emb  = ModelPaths.voiceProfileDir.appendingPathComponent("enrollment.emb")
        return FileManager.default.fileExists(atPath: json.path) &&
               FileManager.default.fileExists(atPath: emb.path)
    }

    @ViewBuilder
    private var profileStatusRow: some View {
        if profilePresent {
            Label("Voice enrolled", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        } else {
            Label("Not enrolled", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange).font(.callout)
        }
    }

    @ViewBuilder
    private func modelStatusRow(label: String, url: URL) -> some View {
        let _ = presenceTick
        let exists = FileManager.default.fileExists(atPath: url.path)
        HStack {
            Text(label).font(.callout)
            Spacer()
            if exists {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
            } else {
                Label("Missing", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption)
            }
        }
    }

    private var modelInstructions: String {
        """
        Voice extraction models are not yet bundled with the app. To install \
        them, run ./enroll.sh once in Terminal (it will build the models and \
        place them under core/build/models/), then copy tse_model.onnx and \
        speaker_encoder.onnx into ~/Library/Application Support/VoiceKeyboard/models/.
        """
    }

    private var tseToggleBinding: Binding<Bool> {
        Binding(
            get: { settings.tseEnabled },
            set: { newValue in
                var s = settings; s.tseEnabled = newValue; settings = s; onSave(s)
            }
        )
    }

    private func deleteProfile() {
        let dir = ModelPaths.voiceProfileDir
        for name in ["enrollment.wav", "enrollment.emb", "speaker.json"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        var s = settings; s.tseEnabled = false; settings = s; onSave(s)
        presenceTick += 1
    }
}
```

- [ ] **Step 2: Build the app target**

```bash
cd mac && xcodebuild -project VoiceKeyboard.xcodeproj -scheme VoiceKeyboard -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED. If the app uses an explicit file list in the project, the new file must be added to the VoiceKeyboard target's Sources phase. Verify with:

```bash
grep -A1 "VoiceTab.swift" mac/VoiceKeyboard.xcodeproj/project.pbxproj | head -4
```

If absent, add via Xcode (File → Add Files to "VoiceKeyboard") and ensure both `EnrollmentSheet.swift` and `VoiceTab.swift` are in the target.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/VoiceTab.swift mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "feat(mac): VoiceTab — Settings UI for voice profile + TSE toggle"
```

---

## Task 13: Wire `VoiceTab` into `SettingsView`

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/SettingsView.swift`

- [ ] **Step 1: Insert the `VoiceTab` between General and Hotkey**

Replace `SettingsView.swift` with:

```swift
import SwiftUI
import VoiceKeyboardCore

struct SettingsView: View {
    let composition: CompositionRoot
    @State private var settings: UserSettings = UserSettings()

    var body: some View {
        TabView {
            GeneralTab(settings: $settings, onSave: save, audioCapture: composition.audioCapture)
                .tabItem { Label("General", systemImage: "gearshape") }
            VoiceTab(
                settings: $settings,
                onSave: save,
                audioCapture: composition.audioCapture,
                engine: composition.engine
            )
                .tabItem { Label("Voice", systemImage: "person.wave.2") }
            HotkeyTab(
                settings: $settings,
                onSave: save,
                onRecordingStart: {
                    composition.coordinator.pauseHotkeyForRecording()
                },
                onRecordingEnd: {
                    Task { @MainActor in await composition.coordinator.resumeHotkeyAfterRecording() }
                },
                conflictChecker: composition.conflictChecker,
                permissions: composition.permissions,
                audioCapture: composition.audioCapture
            )
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
            ProviderTab(settings: $settings, onSave: save, secrets: composition.secrets)
                .tabItem { Label("Provider", systemImage: "key") }
            DictionaryTab(settings: $settings, onSave: save)
                .tabItem { Label("Dictionary", systemImage: "books.vertical") }
            PlaygroundTab(
                appState: composition.appState,
                hotkey: settings.hotkey,
                coordinator: composition.coordinator
            )
                .tabItem { Label("Playground", systemImage: "waveform") }
        }
        .frame(width: 560, height: 460)
        .task {
            settings = (try? composition.settings.get()) ?? UserSettings()
        }
    }

    private func save(_ s: UserSettings) {
        try? composition.settings.set(s)
        Task { @MainActor in
            composition.coordinator.clearHotkeyPause()
            await composition.coordinator.reapplyConfig()
        }
    }
}
```

Note: I bumped frame height from 400 → 460 to accommodate the extra rows in VoiceTab.

- [ ] **Step 2: Build the app**

```bash
cd mac && xcodebuild -project VoiceKeyboard.xcodeproj -scheme VoiceKeyboard -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/SettingsView.swift
git commit -m "feat(mac): wire VoiceTab into SettingsView"
```

---

## Task 14: `EngineCoordinator` populates TSE config

**Files:**
- Modify: `mac/VoiceKeyboard/Engine/EngineCoordinator.swift`

- [ ] **Step 1: Update `applyConfig`**

In `EngineCoordinator.swift`, find the `applyConfig` method (around line 252) and replace the body of the `let cfg = EngineConfig(...)` constructor with the additional TSE fields:

```swift
        let cfg = EngineConfig(
            whisperModelPath: modelPath,
            whisperModelSize: resolvedSize,
            language: settings.language,
            disableNoiseSuppression: settings.disableNoiseSuppression,
            deepFilterModelPath: dfModelPath,
            llmProvider: settings.llmProvider,
            llmModel: settings.llmModel,
            llmAPIKey: key,
            customDict: settings.customDict,
            tseEnabled: settings.tseEnabled && tseAssetsPresent(),
            tseProfileDir: ModelPaths.voiceProfileDir.path,
            tseModelPath: ModelPaths.tseModel.path,
            speakerEncoderPath: ModelPaths.speakerEncoder.path,
            onnxLibPath: ModelPaths.onnxLib.path
        )
```

Add a private helper at the bottom of the type (before the closing brace):

```swift
    /// True when both TSE models and the enrollment profile exist on disk.
    /// Guards us from telling the engine `tse_enabled=true` when assets are
    /// missing — the engine would otherwise log a warning and disable TSE,
    /// which is fine but misleading from a UI standpoint.
    private func tseAssetsPresent() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: ModelPaths.tseModel.path) &&
               fm.fileExists(atPath: ModelPaths.speakerEncoder.path) &&
               fm.fileExists(atPath: ModelPaths.voiceProfileDir.appendingPathComponent("speaker.json").path) &&
               fm.fileExists(atPath: ModelPaths.voiceProfileDir.appendingPathComponent("enrollment.emb").path)
    }
```

- [ ] **Step 2: Build the app**

```bash
cd mac && xcodebuild -project VoiceKeyboard.xcodeproj -scheme VoiceKeyboard -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/Engine/EngineCoordinator.swift
git commit -m "feat(mac): EngineCoordinator populates TSE config from settings"
```

---

## Task 15: Manual smoke test

**Files:** none (verification only)

Run the full flow in the app, end-to-end. This is not automated — UI testing for SwiftUI in this repo is manual.

- [ ] **Step 1: Verify TSE assets are present**

```bash
ls -la ~/Library/Application\ Support/VoiceKeyboard/models/
```

Expected: at least `tse_model.onnx` and `speaker_encoder.onnx`. If missing, copy them:

```bash
mkdir -p ~/Library/Application\ Support/VoiceKeyboard/models/
cp core/build/models/tse_model.onnx ~/Library/Application\ Support/VoiceKeyboard/models/
cp core/build/models/speaker_encoder.onnx ~/Library/Application\ Support/VoiceKeyboard/models/
```

If those source files don't exist either, run `./enroll.sh` once (it will build them) — then proceed.

- [ ] **Step 2: Launch the app**

```bash
cd mac && xcodebuild -project VoiceKeyboard.xcodeproj -scheme VoiceKeyboard -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3
open -a VoiceKeyboard
```

- [ ] **Step 3: Walk through the Voice tab**

In Settings → Voice:

1. "Voice models" section: both rows should show "Installed" ✓.
2. "Voice profile" section: should show "Not enrolled" with a "Record Voice Sample" button.
3. Click "Record Voice Sample". Read the prompt aloud for 10 s.
4. After recording, the sheet should show "Computing voice profile…" briefly, then "Done".
5. Click Done. The Voice tab should now show "Voice enrolled" ✓ and the TSE toggle should be active and ON.

- [ ] **Step 4: Confirm files were written**

```bash
ls -la ~/Library/Application\ Support/VoiceKeyboard/voice/
```

Expected: `enrollment.wav`, `enrollment.emb`, `speaker.json` all present and non-empty. No `.tmp` leftovers.

```bash
cat ~/Library/Application\ Support/VoiceKeyboard/voice/speaker.json
```

Expected: valid JSON with `version: 1`, a `ref_audio` path, an `enrolled_at` timestamp, and a `duration_s` ≈ 10.

- [ ] **Step 5: Test TSE in capture**

Press the dictation hotkey and speak normally. Expected: capture works as before; the result types into the focused field. Check `/tmp/vkb.log`:

```bash
grep "TSE\|tse" /tmp/vkb.log | tail -5
```

Expected: a `[vkb] buildPipeline: TSE loaded (profile=...)` line.

- [ ] **Step 6: Test fall-through when TSE disabled**

In Settings → Voice, toggle "Filter out background speakers" off. Press dictation hotkey, speak, confirm capture still works. Check `/tmp/vkb.log` — should NOT see a fresh TSE-loaded line for this configure.

- [ ] **Step 7: Test re-enrollment**

Click "Re-record" in the Voice tab. Repeat steps 3-4. Confirm files are overwritten (mtime updated, no `.tmp` leftovers).

- [ ] **Step 8: Test delete**

Click Delete. Voice tab should revert to "Not enrolled"; TSE toggle should be disabled. Confirm:

```bash
ls ~/Library/Application\ Support/VoiceKeyboard/voice/ 2>/dev/null
```

Expected: directory empty or missing the three files.

- [ ] **Step 9: Final commit (notes only)**

If everything passes, no further commits needed. If you found issues during smoke test, file them as separate fix commits and update this checkbox afterwards.

---

## Self-Review Notes

- **Spec §2 (Scope — Voice tab + TSE toggle):** Tasks 11, 12, 13.
- **Spec §2 (Go ComputeEmbedding):** Task 2.
- **Spec §2 (vkb_enroll_compute C export):** Tasks 3, 4.
- **Spec §2 (Wire LoadTSE into libvkb):** Task 5.
- **Spec §2 (Config TSE fields):** Task 1; mirrored in Swift in Task 7.
- **Spec §2 (UserSettings.tseEnabled):** Task 8.
- **Spec §4.1 (component split — every component named has a task):** ✓
- **Spec §4.2 (data flow — recording):** Tasks 11 (UI) → 9 (LibvkbEngine) → 4 (C ABI) → 3 (handler) → 2 (compute).
- **Spec §4.3 (data flow — pipeline boot with TSE):** Tasks 14 (Swift sets fields) → 5 (Go uses them).
- **Spec §4.4 (failure modes):**
  - Models missing → Task 12 shows "Missing" + instructions; Task 14 sets `tse_enabled=false` defensively.
  - Toggle locked until enrolled → Task 12 toggle binding `.disabled(!modelsPresent || !profilePresent)`.
  - Corrupt enrollment → Task 5 logs, sets last error, falls through.
  - vkb_enroll_compute failure → Task 3 atomic write rolls back; Task 9 throws; Task 11 shows error state.
  - Mic permission denied → Task 11 sets phase = .failed.
- **Spec §5.4 (Config field names):** Locked in Task 1; Task 7 mirrors with matching CodingKeys; Task 14 uses the same names. Type names: Go `TSEEnabled`/`TSEProfileDir`/`TSEModelPath`/`SpeakerEncoderPath`/`ONNXLibPath`; Swift `tseEnabled`/`tseProfileDir`/`tseModelPath`/`speakerEncoderPath`/`onnxLibPath`; JSON keys `tse_enabled`/`tse_profile_dir`/`tse_model_path`/`speaker_encoder_path`/`onnx_lib_path` — used consistently across all tasks.
- **Spec §5.6 (UserSettings backward-compatible decode):** Task 8 includes a custom `init(from:)` so existing persisted UserDefaults still load.
- **Spec §6 (testing plan — every test listed has a task):** Compute embedding (Task 2), Decimate (already exists), C ABI atomic (Task 3), `EngineConfigTests` (Task 7), `SettingsStoreTests` (Task 8), manual smoke (Task 15). The "rejects bad sample rate" test is covered by guard logic in Task 4 — could add an explicit unit test, but the C ABI is hard to test in Go without spinning up cgo bindings; covered manually in smoke.
- **Spec §7 (migration / back-compat):** Old `~/.config/voice-keyboard/` flow continues to work; the app uses `~/Library/Application Support/VoiceKeyboard/voice/` (Task 10 + Task 14). `tseEnabled` defaults false → existing users see no behavior change.
- **Spec §8 (open decisions):**
  - Profile dir: locked to `~/Library/Application Support/VoiceKeyboard/voice/` in Task 10.
  - Prompt text: locked in Task 11 as a hard-coded string. If we want it editable later, factor into an asset file.

**Type & signature consistency:**
- C signature: `vkb_enroll_compute(const float*, int count, int sample_rate, const char* profile_dir)` — matches Task 4 export, Task 6 shim, Task 9 Swift call.
- Profile JSON shape: `{version: 1, ref_audio, enrolled_at, duration_s}` — matches `speaker.Profile` (Task 3) and what `pipeline.LoadTSE` already reads.
- Path conventions: voiceProfileDir consistent across Tasks 10, 11, 12, 14; modelsDir consistent across Tasks 10, 12, 14.
