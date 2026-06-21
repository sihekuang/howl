# Audio Filter Backend (diar_mask) Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the already-built `diar_mask` algorithm a user-selectable `pyannote` backend in the audio-filter pipeline slot (renamed from `tse`), choosable in the macOS app exactly like the existing `ecapa` backend.

**Architecture:** Generalize the speaker `Backend` with a `Kind` discriminator (`separation` | `diarmask`); rename the chunk stage name `tse`→`audio_filter`; dispatch `LoadAudioFilter` on `Kind` to build either `SpeakerGate` (ecapa) or `DiarMask`+pyannote-segmenter (pyannote); make the offline C-ABI extract backend-aware; surface the new backend + a model-status row in Swift. Keep config JSON keys, model filenames, and the C-ABI symbol on their legacy `tse` names (scope-bounded back-compat).

**Tech Stack:** Go (core + libhowl C-ABI, onnxruntime_go), Swift/SwiftUI (macOS app + HowlCore package), pyannote/segmentation-3.0 ONNX, ECAPA encoder ONNX, whisper.cpp.

**Spec:** `docs/superpowers/specs/2026-06-21-audio-filter-backend-diarmask-frontend-design.md`

## Global Constraints

- **Stage-name token is `audio_filter`** (lowercase, single token); user-facing label may render "Audio Filter". This replaces the old stage name `tse` and the old `DiarMask` name `diar_mask`.
- **Do NOT rename** (decisions B/C/D in the spec): engine config JSON keys (`tse_enabled`, `tse_backend`, `tse_threshold`, `tse_profile_dir`, `tse_model_path`), model filenames (`tse_model.onnx`), the C-ABI symbol (`howl_tse_extract_file`), or the manifest JSON key (`tse_similarity`). Only ADD a `backend` parameter to the C symbol.
- **Two backends:** `ecapa` (`Kind: separation`, model `tse_model.onnx`), `pyannote` (`Kind: diarmask`, model `pyannote_seg.onnx`). Both use the ECAPA encoder (`speaker_encoder.onnx`, 192-dim) for the cosine SELECT.
- **`tse_threshold` is inert for `pyannote`** — `diar_mask` has no suppression gate. Do not wire `threshold` into `DiarMask`; the UI disables the threshold control when `pyannote` is selected.
- **Compat:** on read, tolerate the legacy stage name `tse` as an alias of `audio_filter` (Go preset resolution + Swift manifest/preset reads). New writes always emit `audio_filter`.
- **Fail-open:** a missing/failed audio-filter model or missing enrollment must NOT crash the pipeline — log + continue without the stage (matches today's `build.go:108-110`).
- **`pyannote_seg.onnx` is NOT committed** to git (large binary); resolved from the models dir at runtime like `tse_model.onnx`.
- **ONNX runtime:** call `speaker.InitONNXRuntime(onnxLibPath)` once before constructing any ONNX session. `speaker.ComputeEmbedding` opens its own session per call (acceptable: latency is post-capture batch).
- **Branch policy:** all work stays on `worktree-speaker-diarization-tse`; do NOT merge to `main` without explicit user say-so.

---

### Task 1: Export `pyannote_seg.onnx` (prerequisite artifact)

> **Controller-run, NOT delegated to a fresh subagent.** This task needs interactive Hugging Face authentication that only the user can perform. The controller runs the commands; the user performs the EULA acceptance + in-session `huggingface-cli login`. No repo code changes — the deliverable is a model file in the models dir, verified by a tagged smoke test.

**Files:**
- Reference: `core/BUILDING_PYANNOTE_SEG.md` (the committed export recipe)
- Produce: `~/Library/Application Support/Howl/models/pyannote_seg.onnx` (NOT committed)
- Verify with: `core/internal/speaker/diarmask_pyannote_test.go` (existing tagged smoke)

**Interfaces:**
- Produces: `pyannote_seg.onnx` with ONNX input `waveform` `[1,1,160000]` → output `segmentation` `[1,num_frames,7]` (opset 17, dynamic `num_frames`), loadable by `speaker.NewPyannoteSegmenter`.

- [ ] **Step 1: Confirm the user has accepted the gated EULA**

Ask the user to confirm they have clicked "Agree and access repository" on `https://huggingface.co/pyannote/segmentation-3.0` while signed into their HF account. Do not proceed until confirmed.

- [ ] **Step 2: Create the python3.12 venv and install deps**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/.claude/worktrees/speaker-diarization-tse
python3.12 -m venv /tmp/pyannote-export-venv
/tmp/pyannote-export-venv/bin/pip install --quiet --upgrade pip
/tmp/pyannote-export-venv/bin/pip install --quiet "torch" "pyannote.audio" "onnx" "huggingface_hub[cli]"
/tmp/pyannote-export-venv/bin/python -c "import torch, pyannote.audio, onnx; print('torch', torch.__version__)"
```
Expected: prints a torch version with no import error.

- [ ] **Step 3: User authenticates in-session (token never handled by the controller)**

Tell the user to run this themselves via the prompt `!` prefix (the token is entered at a hidden prompt and cached locally; the controller never sees it):
```
! /tmp/pyannote-export-venv/bin/huggingface-cli login
```
Then verify the cached login (no token printed):
```bash
/tmp/pyannote-export-venv/bin/huggingface-cli whoami
```
Expected: prints the user's HF username. If it errors, the login didn't take — ask the user to retry.

- [ ] **Step 4: Run the export per the committed recipe**

Follow `core/BUILDING_PYANNOTE_SEG.md` exactly (it contains the authoritative export script). Run it with the venv python, writing to the models dir:
```bash
mkdir -p "$HOME/Library/Application Support/Howl/models"
# Run the export script documented in core/BUILDING_PYANNOTE_SEG.md using
# /tmp/pyannote-export-venv/bin/python, output path:
#   $HOME/Library/Application Support/Howl/models/pyannote_seg.onnx
```
Expected: `pyannote_seg.onnx` written, no export error.

- [ ] **Step 5: Verify the ONNX shape contract**

```bash
/tmp/pyannote-export-venv/bin/python - <<'PY'
import onnx, os
p = os.path.expanduser("~/Library/Application Support/Howl/models/pyannote_seg.onnx")
m = onnx.load(p); onnx.checker.check_model(m)
g = m.graph
print("inputs:", [(i.name, [d.dim_value or d.dim_param for d in i.type.tensor_type.shape.dim]) for i in g.input])
print("outputs:", [(o.name, [d.dim_value or d.dim_param for d in o.type.tensor_type.shape.dim]) for o in g.output])
PY
```
Expected: an input named `waveform` shaped `[1,1,160000]` and an output named `segmentation` with last dim `7`.

- [ ] **Step 6: Verify via the Go tagged smoke test**

```bash
cd core
PYANNOTE_SEG_PATH="$HOME/Library/Application Support/Howl/models/pyannote_seg.onnx" \
  go test -tags cleanupeval ./internal/speaker/ -run TestPyannoteSegmenter_RealModelSmoke -v -count=1
```
Expected: PASS (frames returned, `FrameHopSamples > 0`, each frame has `diarMaxSpeakers` entries). If it SKIPs, the env var/path is wrong — fix the path.

- [ ] **Step 7: Record the outcome (no commit — model is not tracked)**

If the export failed after reasonable iteration, STOP and report to the user: per the spec's Layer 0 contingency, the remaining tasks still proceed (wiring is export-independent; the UI degrades to a "model missing" state), but the `pyannote` backend won't function until a model is produced. If it succeeded, note the model path in the progress ledger and continue.

---

### Task 2: Generalize the speaker `Backend` (Kind + Pyannote registry)

**Files:**
- Modify: `core/internal/speaker/backend.go`
- Test: `core/internal/speaker/backend_test.go`

**Interfaces:**
- Produces: `speaker.BackendKind` (`BackendSeparation`, `BackendDiarMask`); `Backend.Kind BackendKind`; `Backend.SegModelFile string`; `(*Backend).SegPath(modelsDir string) string`; `speaker.Pyannote *Backend` (registered, `Name:"pyannote"`, `Kind:BackendDiarMask`, `EmbeddingDim:192`, `EncoderModelFile:"speaker_encoder.onnx"`, `SegModelFile:"pyannote_seg.onnx"`). `ECAPA` gains `Kind:BackendSeparation`.

- [ ] **Step 1: Write the failing test**

Add to `core/internal/speaker/backend_test.go`:
```go
func TestBackendByName_Pyannote(t *testing.T) {
	b, err := BackendByName("pyannote")
	if err != nil {
		t.Fatalf("BackendByName(pyannote): %v", err)
	}
	if b.Name != "pyannote" {
		t.Errorf("Name = %q, want pyannote", b.Name)
	}
	if b.Kind != BackendDiarMask {
		t.Errorf("Kind = %v, want BackendDiarMask", b.Kind)
	}
	if b.SegModelFile != "pyannote_seg.onnx" {
		t.Errorf("SegModelFile = %q, want pyannote_seg.onnx", b.SegModelFile)
	}
	if got := b.SegPath("/tmp/models"); got != "/tmp/models/pyannote_seg.onnx" {
		t.Errorf("SegPath = %q", got)
	}
	if b.EncoderModelFile != "speaker_encoder.onnx" || b.EmbeddingDim != 192 {
		t.Errorf("encoder/dim = %q/%d", b.EncoderModelFile, b.EmbeddingDim)
	}
}

func TestECAPA_KindIsSeparation(t *testing.T) {
	if ECAPA.Kind != BackendSeparation {
		t.Errorf("ECAPA.Kind = %v, want BackendSeparation", ECAPA.Kind)
	}
}

func TestBackendNames_IncludesPyannote(t *testing.T) {
	names := BackendNames()
	found := false
	for _, n := range names {
		if n == "pyannote" {
			found = true
		}
	}
	if !found {
		t.Errorf("BackendNames %v missing 'pyannote'", names)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd core && go test ./internal/speaker/ -run 'TestBackendByName_Pyannote|TestECAPA_KindIsSeparation|TestBackendNames_IncludesPyannote' -count=1`
Expected: FAIL — `undefined: BackendDiarMask`, `b.Kind undefined`, `b.SegModelFile undefined`, `BackendByName(pyannote)` returns "unknown backend".

- [ ] **Step 3: Implement the Backend generalization**

In `core/internal/speaker/backend.go`, add the kind type above `type Backend struct`:
```go
// BackendKind distinguishes how a backend isolates the enrolled speaker.
type BackendKind int

const (
	// BackendSeparation reconstructs the target's audio (TSE / SpeakerGate).
	BackendSeparation BackendKind = iota
	// BackendDiarMask diarizes, cosine-SELECTs the enrolled track, and
	// time-MASKs the original audio (DiarMask + pyannote segmenter).
	BackendDiarMask
)
```
Add the two fields to `Backend` (keep existing fields, update the comment on `TSEModelFile`):
```go
type Backend struct {
	// Name is the identifier surfaced in flags, logs, and config.
	Name string
	// Kind selects the isolation strategy (separation vs diarize-mask).
	Kind BackendKind
	// EmbeddingDim is the encoder output dimensionality (length of
	// enrollment.emb / ref_embedding tensor).
	EmbeddingDim int
	// EncoderModelFile is the speaker-encoder ONNX filename inside modelsDir.
	EncoderModelFile string
	// TSEModelFile is the combined-TSE (separation) ONNX filename inside
	// modelsDir. Set only for BackendSeparation.
	TSEModelFile string
	// SegModelFile is the segmentation ONNX filename inside modelsDir.
	// Set only for BackendDiarMask.
	SegModelFile string
}
```
Add `SegPath` next to `TSEPath`:
```go
// SegPath resolves the segmentation ONNX file relative to modelsDir.
func (b *Backend) SegPath(modelsDir string) string {
	return filepath.Join(modelsDir, b.SegModelFile)
}
```
Set `ECAPA.Kind` explicitly and register `Pyannote`:
```go
var ECAPA = &Backend{
	Name:             "ecapa",
	Kind:             BackendSeparation,
	EmbeddingDim:     192,
	EncoderModelFile: "speaker_encoder.onnx",
	TSEModelFile:     "tse_model.onnx",
}

// Pyannote: pyannote/segmentation-3.0 powerset diarizer + ECAPA encoder for
// cosine target SELECT, then time-MASK of the original audio (no separation,
// no suppression gate). Inclusion-biased — see DiarMask.
var Pyannote = &Backend{
	Name:             "pyannote",
	Kind:             BackendDiarMask,
	EmbeddingDim:     192,
	EncoderModelFile: "speaker_encoder.onnx",
	SegModelFile:     "pyannote_seg.onnx",
}
```
Add `Pyannote` to the registry:
```go
var backends = map[string]*Backend{
	ECAPA.Name:    ECAPA,
	Pyannote.Name: Pyannote,
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd core && go test ./internal/speaker/ -run 'TestBackend' -count=1`
Expected: PASS (including the existing `TestBackendByName_*`, `TestBackendNames_*`, `TestBackend_PathHelpers`).

- [ ] **Step 5: Commit**

```bash
cd /Users/daniel/Documents/Projects/voice-keyboard/.claude/worktrees/speaker-diarization-tse
git add core/internal/speaker/backend.go core/internal/speaker/backend_test.go
git commit -m "feat(speaker): add BackendKind + register pyannote diarmask backend"
```

---

### Task 3: Rename stage `tse`→`audio_filter` + type-driven similarity hook

**Files:**
- Modify: `core/internal/speaker/speakerbeam.go:112` (`SpeakerGate.Name()`)
- Modify: `core/internal/speaker/diarmask.go:180` (`DiarMask.Name()`)
- Modify: `core/internal/pipeline/manifest.go:52-57` (drop name guard)
- Modify: `core/internal/pipeline/pipeline.go:155-161` (drop name guard)
- Test: `core/internal/speaker/diarmask_test.go:308` (update name assertion)
- Test: `core/internal/pipeline/manifest_test.go:45,83` (update fake stage name)

**Interfaces:**
- Consumes: nothing new.
- Produces: both `SpeakerGate.Name()` and `DiarMask.Name()` return `"audio_filter"`. The manifest writer and event emitter populate similarity for ANY chunk stage implementing `interface{ LastSimilarity() float32 }` (no name dependence).

- [ ] **Step 1: Update the stage-name assertion test (write the failing test first)**

In `core/internal/speaker/diarmask_test.go:308`, change the expected name:
```go
	if d.Name() != "audio_filter" {
		t.Errorf("Name() = %q, want audio_filter", d.Name())
	}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd core && go test ./internal/speaker/ -run TestDiarMask -count=1` (use the test name that contains line 308's assertion; if unsure run the whole file's package)
Expected: FAIL — `Name() = "diar_mask", want audio_filter`.

- [ ] **Step 3: Rename both stage `Name()` implementations**

`core/internal/speaker/speakerbeam.go:112`:
```go
func (g *SpeakerGate) Name() string    { return "audio_filter" }
```
`core/internal/speaker/diarmask.go:180`:
```go
func (d *DiarMask) Name() string    { return "audio_filter" }
```

- [ ] **Step 4: Run to verify the rename test passes**

Run: `cd core && go test ./internal/speaker/ -run TestDiarMask -count=1`
Expected: PASS.

- [ ] **Step 5: Make the similarity hook type-driven (manifest.go)**

In `core/internal/pipeline/manifest.go`, replace the name-guarded block (currently lines 52-57):
```go
		if st.Name() == "tse" {
			if g, ok := st.(interface{ LastSimilarity() float32 }); ok {
				sim := g.LastSimilarity()
				entry.TSESimilarity = &sim
			}
		}
```
with the type-only check:
```go
		// Any chunk stage exposing LastSimilarity reports it (both the
		// ecapa SpeakerGate and the pyannote DiarMask do). The JSON key
		// stays "tse_similarity" for back-compat (see design spec §3 D).
		if g, ok := st.(interface{ LastSimilarity() float32 }); ok {
			sim := g.LastSimilarity()
			entry.TSESimilarity = &sim
		}
```

- [ ] **Step 6: Make the similarity hook type-driven (pipeline.go)**

In `core/internal/pipeline/pipeline.go`, replace the name-guarded block (currently lines 155-161):
```go
					var tseSim *float32
					if st.Name() == "tse" {
						if g, ok := st.(interface{ LastSimilarity() float32 }); ok {
							s := g.LastSimilarity()
							tseSim = &s
						}
					}
```
with:
```go
					var tseSim *float32
					if g, ok := st.(interface{ LastSimilarity() float32 }); ok {
						s := g.LastSimilarity()
						tseSim = &s
					}
```

- [ ] **Step 7: Update the manifest test fake to the new stage name**

In `core/internal/pipeline/manifest_test.go`, line 45, rename the fake stage to reflect reality (its `LastSimilarity` still drives the populated branch):
```go
	tse := &fakeChunkStage{name: "audio_filter", outputRate: 0, withSim: true, simValue: 0.71}
```
and line 83's assertion:
```go
	if m.Stages[2].Name != "audio_filter" || m.Stages[2].Kind != "chunk" || m.Stages[2].RateHz != 16000 {
```

- [ ] **Step 8: Run the pipeline + speaker suites to verify green**

Run: `cd core && go test ./internal/pipeline/ ./internal/speaker/ -count=1`
Expected: PASS. (The synth/WER/HTML tests under `cleanupeval` use `"tse"`/`"diar_mask"` only as report labels, not `Name()` assertions, so they are unaffected and remain untouched.)

- [ ] **Step 9: Commit**

```bash
git add core/internal/speaker/speakerbeam.go core/internal/speaker/diarmask.go \
  core/internal/speaker/diarmask_test.go core/internal/pipeline/manifest.go \
  core/internal/pipeline/pipeline.go core/internal/pipeline/manifest_test.go
git commit -m "refactor(pipeline): rename chunk stage tse->audio_filter, type-driven similarity"
```

---

### Task 4: Preset/CLI rename + legacy-`tse` compat normalization (Go)

**Files:**
- Modify: `core/internal/presets/pipeline-presets.json` (4 presets)
- Modify: `core/internal/presets/resolve.go` (lines 90, 140 + add `normalizeStageName`)
- Modify: `core/cmd/howl-cli/pipe.go:81`
- Test: `core/internal/presets/resolve_test.go` (new cases; create if absent)

**Interfaces:**
- Consumes: nothing new.
- Produces: `presets.normalizeStageName(name string) string` (maps legacy `"tse"`→`"audio_filter"`, else identity). Preset resolution matches the chunk stage by the normalized name, so both `audio_filter` (new) and `tse` (legacy persisted) resolve.

- [ ] **Step 1: Write the failing compat test**

Create/extend `core/internal/presets/resolve_test.go`:
```go
package presets

import "testing"

func TestNormalizeStageName_LegacyTSE(t *testing.T) {
	if got := normalizeStageName("tse"); got != "audio_filter" {
		t.Errorf("normalizeStageName(tse) = %q, want audio_filter", got)
	}
	if got := normalizeStageName("audio_filter"); got != "audio_filter" {
		t.Errorf("normalizeStageName(audio_filter) = %q", got)
	}
	if got := normalizeStageName("denoise"); got != "denoise" {
		t.Errorf("normalizeStageName(denoise) = %q, want denoise (identity)", got)
	}
}

func TestResolve_LegacyTSEChunkStageStillApplies(t *testing.T) {
	p := Preset{
		Name:        "legacy",
		ChunkStages: []StageSpec{{Name: "tse", Enabled: true, Backend: "ecapa"}},
	}
	cfg := Resolve(p, EngineSecrets{})
	if !cfg.TSEEnabled {
		t.Errorf("legacy tse chunk stage did not set TSEEnabled")
	}
	if cfg.TSEBackend != "ecapa" {
		t.Errorf("TSEBackend = %q, want ecapa", cfg.TSEBackend)
	}
}
```
(Confirmed types: `presets.StageSpec{Name string; Enabled bool; Backend string; Threshold *float32}`, `presets.Preset{Name; ChunkStages []StageSpec; …}`, `presets.EngineSecrets{}` — `presets.go:31,50` / `resolve.go:16`. The test lives in `package presets`.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd core && go test ./internal/presets/ -run 'TestNormalizeStageName_LegacyTSE|TestResolve_LegacyTSEChunkStageStillApplies' -count=1`
Expected: FAIL — `undefined: normalizeStageName`, and (after it exists) the legacy resolve test fails because `Resolve` matches `st.Name != "tse"` literally / `"audio_filter"` literally.

- [ ] **Step 3: Add the normalize helper + use it in Resolve and Match**

In `core/internal/presets/resolve.go`, add the helper:
```go
// normalizeStageName maps a persisted/legacy chunk-stage name to the current
// canonical name. The audio-filter slot was historically named "tse"; presets
// and manifests written before the rename carry that. Normalizing on read lets
// old presets keep resolving. New writes always use "audio_filter".
func normalizeStageName(name string) string {
	if name == "tse" {
		return "audio_filter"
	}
	return name
}
```
In `Resolve` (the chunk loop, currently line 90), change the guard:
```go
	for _, st := range p.ChunkStages {
		if normalizeStageName(st.Name) != "audio_filter" {
			continue
		}
		cfg.TSEEnabled = st.Enabled
		cfg.TSEBackend = st.Backend
		if st.Threshold != nil {
			t := *st.Threshold
			cfg.TSEThreshold = &t
		}
	}
```
In `presetMatchesConfig` (the chunk loop, currently line 140), change the guard the same way:
```go
	for _, st := range p.ChunkStages {
		if normalizeStageName(st.Name) != "audio_filter" {
			continue
		}
```
(leave the body of `presetMatchesConfig` unchanged).

- [ ] **Step 4: Update the bundled presets JSON**

In `core/internal/presets/pipeline-presets.json`, change every `chunk_stages` entry's name from `"tse"` to `"audio_filter"` (4 occurrences — `default`, `minimal`, `aggressive`, `paranoid`). Example (default preset):
```json
      "chunk_stages": [
        {"name": "audio_filter", "enabled": false, "backend": "ecapa", "threshold": 0.0}
      ],
```
Apply the identical name change to the other three presets, preserving each preset's existing `enabled`/`backend`/`threshold` values (minimal: `false/ecapa/0.0`; aggressive: `true/ecapa/0.35`; paranoid: `true/ecapa/0.45`).

- [ ] **Step 5: Update the howl-cli preset matcher**

In `core/cmd/howl-cli/pipe.go:81`, change the chunk-stage name check to use the canonical name (and tolerate legacy via the same rule):
```go
		for _, st := range p.ChunkStages {
			if (st.Name != "audio_filter" && st.Name != "tse") || !st.Enabled {
				continue
			}
```
(Keep the rest of the loop body — `*speakerMode = true`, `*tseBackend = st.Backend`, `break` — unchanged.)

- [ ] **Step 6: Run the presets suite + a build of howl-cli**

Run: `cd core && go test ./internal/presets/ -count=1 && go build ./cmd/howl-cli/`
Expected: PASS + clean build. Also run `go test ./internal/presets/ -run TestResolve -count=1` to confirm the bundled presets still match their own Resolve output (the `Match` round-trip).

- [ ] **Step 7: Commit**

```bash
git add core/internal/presets/pipeline-presets.json core/internal/presets/resolve.go \
  core/internal/presets/resolve_test.go core/cmd/howl-cli/pipe.go
git commit -m "feat(presets): rename tse chunk stage to audio_filter with legacy-tse compat"
```

---

### Task 5: `LoadAudioFilter` dispatch + call sites

**Files:**
- Modify: `core/internal/pipeline/pipeline.go:358-403` (rename `LoadTSE`→`LoadAudioFilter`, branch on `Kind`)
- Modify: `core/internal/pipeline/build/build.go:107`
- Modify: `core/cmd/howl-cli/pipe.go:217`
- Modify: `core/internal/speaker/vad.go:37` (comment reference only)
- Test: `core/internal/pipeline/pipeline_test.go` (no-enrollment dispatch, cheap)

**Interfaces:**
- Consumes: `speaker.BackendKind`, `speaker.Pyannote`, `(*Backend).SegPath` (Task 2); `speaker.NewPyannoteSegmenter(modelPath string)`, `speaker.NewDiarMask(speaker.DiarMaskOptions)`, `speaker.ComputeEmbedding(modelPath, samples, dim)`, `speaker.NewSpeakerGate(speaker.SpeakerGateOptions)`.
- Produces: `pipeline.LoadAudioFilter(backend *speaker.Backend, profileDir, modelsDir, onnxLibPath string, threshold float32) (audio.Stage, error)` — returns a `Stage` named `audio_filter` for either backend, or `(nil, nil)` when enrollment is absent.

- [ ] **Step 1: Write the failing cheap dispatch test**

In `core/internal/pipeline/pipeline_test.go` add (this exercises the no-enrollment fast path, which returns before any ONNX work, so it needs no models):
```go
func TestLoadAudioFilter_NoEnrollmentReturnsNil(t *testing.T) {
	dir := t.TempDir() // empty: no speaker.json
	for _, b := range []*speaker.Backend{speaker.ECAPA, speaker.Pyannote} {
		st, err := LoadAudioFilter(b, dir, dir, "", 0)
		if err != nil {
			t.Errorf("LoadAudioFilter(%s) err = %v, want nil", b.Name, err)
		}
		if st != nil {
			t.Errorf("LoadAudioFilter(%s) stage = %v, want nil (no enrollment)", b.Name, st)
		}
	}
}
```
(Ensure the test file imports `github.com/voice-keyboard/core/internal/speaker`.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd core && go test ./internal/pipeline/ -run TestLoadAudioFilter_NoEnrollmentReturnsNil -count=1`
Expected: FAIL — `undefined: LoadAudioFilter`.

- [ ] **Step 3: Replace `LoadTSE` with `LoadAudioFilter`**

In `core/internal/pipeline/pipeline.go`, replace the whole `LoadTSE` function (lines 358-403) with:
```go
// LoadAudioFilter initialises the audio-filter chunk stage for the given
// backend and loads the enrollment embedding from profileDir. Returns a nil
// stage + nil error when speaker.json is absent (filter off). Returns an error
// only on partial state (json present but embedding missing/corrupt) or on a
// model/runtime failure.
//
// Dispatches on backend.Kind: BackendSeparation → SpeakerGate (reconstructing
// TSE, with the optional post-extract similarity gate when threshold > 0);
// BackendDiarMask → DiarMask + pyannote segmenter (diarize → cosine SELECT →
// time MASK, inclusion-biased, no gate — threshold is ignored).
func LoadAudioFilter(backend *speaker.Backend, profileDir, modelsDir, onnxLibPath string, threshold float32) (audio.Stage, error) {
	if backend == nil {
		backend = speaker.Default
	}
	_, err := speaker.LoadProfile(profileDir)
	if os.IsNotExist(err) {
		return nil, nil // no enrollment — audio filter off
	}
	if err != nil {
		return nil, fmt.Errorf("load audiofilter: profile: %w", err)
	}
	embPath := profileDir + "/enrollment.emb"
	ref, err := speaker.LoadEmbedding(embPath, backend.EmbeddingDim)
	if os.IsNotExist(err) {
		return nil, fmt.Errorf("load audiofilter: enrollment.emb missing — re-run enroll.sh")
	}
	if err != nil {
		return nil, fmt.Errorf("load audiofilter: embedding: %w", err)
	}
	if err := speaker.InitONNXRuntime(onnxLibPath); err != nil {
		return nil, fmt.Errorf("load audiofilter: onnx runtime: %w", err)
	}

	switch backend.Kind {
	case speaker.BackendDiarMask:
		seg, err := speaker.NewPyannoteSegmenter(backend.SegPath(modelsDir))
		if err != nil {
			return nil, fmt.Errorf("load audiofilter: segmenter: %w", err)
		}
		encPath := backend.EncoderPath(modelsDir)
		dim := backend.EmbeddingDim
		dm, err := speaker.NewDiarMask(speaker.DiarMaskOptions{
			Segmenter: seg,
			Embed:     func(s []float32) ([]float32, error) { return speaker.ComputeEmbedding(encPath, s, dim) },
			Reference: ref,
			// threshold intentionally not wired: diarmask has no gate.
		})
		if err != nil {
			_ = seg.Close()
			return nil, fmt.Errorf("load audiofilter: diarmask: %w", err)
		}
		return dm, nil
	default: // BackendSeparation
		opts := speaker.SpeakerGateOptions{
			ModelPath: backend.TSEPath(modelsDir),
			Reference: ref,
			Threshold: threshold,
		}
		if threshold > 0 {
			opts.EncoderPath = backend.EncoderPath(modelsDir)
			opts.EncoderDim = backend.EmbeddingDim
		}
		gate, err := speaker.NewSpeakerGate(opts)
		if err != nil {
			return nil, fmt.Errorf("load audiofilter: model: %w", err)
		}
		return gate, nil
	}
}
```

- [ ] **Step 4: Update the two call sites**

`core/internal/pipeline/build/build.go:107`:
```go
		tse, tseErr := pipeline.LoadAudioFilter(backend, cfg.TSEProfileDir, modelsDir, cfg.ONNXLibPath, cfg.TSEThresholdValue())
```
`core/cmd/howl-cli/pipe.go:217`:
```go
		tseStage, err := pipeline.LoadAudioFilter(backend, profileDir, modelsDir, onnxLib, 0)
```
And update the stale comment reference in `core/internal/speaker/vad.go:37` (`pipeline.LoadTSE` → `pipeline.LoadAudioFilter`).

- [ ] **Step 5: Run the dispatch test + build the dependent packages**

Run: `cd core && go test ./internal/pipeline/ -run TestLoadAudioFilter_NoEnrollmentReturnsNil -count=1 && go build ./cmd/howl-cli/ && go build -tags whispercpp ./internal/pipeline/build/`
Expected: PASS + clean builds.

- [ ] **Step 6: (model-gated) Verify the live dispatch end-to-end if artifacts present**

Run the existing pipeline/build tests with the whispercpp tag to confirm nothing regressed:
```bash
cd core && go test -tags whispercpp ./internal/pipeline/... -count=1
```
Expected: PASS (tests needing real models skip cleanly).

- [ ] **Step 7: Commit**

```bash
git add core/internal/pipeline/pipeline.go core/internal/pipeline/build/build.go \
  core/cmd/howl-cli/pipe.go core/internal/speaker/vad.go core/internal/pipeline/pipeline_test.go
git commit -m "feat(pipeline): LoadAudioFilter dispatches ecapa SpeakerGate vs pyannote DiarMask"
```

---

### Task 6: Backend-aware C-ABI offline extract

**Files:**
- Modify: `core/cmd/libhowl/tse_lab_export.go` (add `backend` param + Kind dispatch; rename `runTSEExtractFile`→`runAudioFilterExtractFile`)
- Test: `core/cmd/libhowl/tse_lab_export_test.go` (already `//go:build whispercpp`) — add the pyannote smoke AND update the existing `runTSEExtractFile` call at line 74

**Interfaces:**
- Consumes: `speaker.BackendByName`, `speaker.BackendKind`, construction helpers (`speaker.NewPyannoteSegmenter`, `speaker.NewDiarMask`, `speaker.ComputeEmbedding`, `speaker.NewSpeakerGate`), `(*DiarMask).Process`, `(*SpeakerGate).Extract`.
- Produces: C export `howl_tse_extract_file(inputPath, outputPath, modelsDir, voiceDir, onnxLibPath, backend *C.char) C.int` (6 args — backend appended). Go body `runAudioFilterExtractFile(inputPath, outputPath, modelsDir, voiceDir, onnxLibPath, backendName string) error`.

> NOTE: `core/cmd/libhowl/*.go` files carry `//go:build whispercpp`. All `go build`/`go test` for this package use `-tags whispercpp`; the shipped dylib additionally uses `deepfilter` (see Task 8's `make build-dylib`). Bootstrap deps (`libwhisper`, `libdf`) must be present — run `cd core && make bootstrap` if linking fails.

- [ ] **Step 1: Write the failing tagged smoke test**

Add to the existing `core/cmd/libhowl/tse_lab_export_test.go` (it already carries `//go:build whispercpp` and imports `os`, `filepath`, `audio`; add any missing import). Mirror the model-skip pattern; skip when models/enrollment absent:
```go
func TestRunAudioFilterExtractFile_PyannoteSmoke(t *testing.T) {
	models := os.Getenv("HOWL_MODELS_DIR")
	voice := os.Getenv("HOWL_VOICE_DIR")
	onnx := os.Getenv("ONNXRUNTIME_LIB_PATH")
	seg := filepath.Join(models, "pyannote_seg.onnx")
	emb := filepath.Join(voice, "enrollment.emb")
	if models == "" || voice == "" || onnx == "" {
		t.Skip("set HOWL_MODELS_DIR, HOWL_VOICE_DIR, ONNXRUNTIME_LIB_PATH to run")
	}
	if _, err := os.Stat(seg); err != nil {
		t.Skipf("pyannote_seg.onnx absent: %v", err)
	}
	if _, err := os.Stat(emb); err != nil {
		t.Skipf("enrollment.emb absent: %v", err)
	}
	// A short 16 kHz mono WAV of low-level noise is enough to exercise the
	// path; we assert the output WAV is produced and non-empty, not labels.
	in := filepath.Join(t.TempDir(), "in.wav")
	samples := make([]float32, 16000*3)
	for i := range samples {
		samples[i] = float32(i%11)*0.001 - 0.005
	}
	if err := audio.WriteWAVMono(in, samples, targetSampleRate); err != nil {
		t.Fatalf("write input: %v", err)
	}
	out := filepath.Join(t.TempDir(), "out.wav")
	if err := runAudioFilterExtractFile(in, out, models, voice, onnx, "pyannote"); err != nil {
		t.Fatalf("runAudioFilterExtractFile(pyannote): %v", err)
	}
	got, sr, err := audio.ReadWAVMono(out)
	if err != nil {
		t.Fatalf("read output: %v", err)
	}
	if sr != targetSampleRate || len(got) == 0 {
		t.Errorf("output sr=%d len=%d, want sr=%d len>0", sr, len(got), targetSampleRate)
	}
}
```

- [ ] **Step 2: Run to verify it fails (or skips for the right reason)**

Run: `cd core && HOWL_MODELS_DIR="$HOME/Library/Application Support/Howl/models" HOWL_VOICE_DIR="$HOME/Library/Application Support/Howl/voice" ONNXRUNTIME_LIB_PATH=/opt/homebrew/lib/libonnxruntime.dylib go test -tags whispercpp ./cmd/libhowl/ -run TestRunAudioFilterExtractFile_PyannoteSmoke -count=1`
Expected: FAIL — `undefined: runAudioFilterExtractFile`. (If the model/enrollment are absent it would SKIP, but the symbol is undefined so it fails to compile first — that's the failing state we want.)

- [ ] **Step 3: Generalize the export body to dispatch on backend**

In `core/cmd/libhowl/tse_lab_export.go`, add `"github.com/voice-keyboard/core/internal/pipeline"`-free construction (keep imports minimal — it already imports `audio` and `speaker`; add `"context"` is already present). Replace `runTSEExtractFile` with a backend-aware version and keep the old name as a thin wrapper is NOT needed (single caller). Rename it:
```go
// runAudioFilterExtractFile is the testable body of howl_tse_extract_file.
// It dispatches on the named backend's Kind: separation backends run the
// reconstructing SpeakerGate; diarmask backends run DiarMask (diarize →
// cosine SELECT → time MASK). Both read a 16 kHz mono WAV and write one.
func runAudioFilterExtractFile(inputPath, outputPath, modelsDir, voiceDir, onnxLibPath, backendName string) error {
	samples, sr, err := audio.ReadWAVMono(inputPath)
	if err != nil {
		return fmt.Errorf("read input wav: %w", err)
	}
	if sr != targetSampleRate {
		return fmt.Errorf("input sample rate %d != %d", sr, targetSampleRate)
	}
	if len(samples) == 0 {
		return fmt.Errorf("input wav is empty")
	}

	backend, err := speaker.BackendByName(backendName)
	if err != nil {
		return fmt.Errorf("backend: %w", err)
	}
	embPath := filepath.Join(voiceDir, "enrollment.emb")
	ref, err := speaker.LoadEmbedding(embPath, backend.EmbeddingDim)
	if err != nil {
		return fmt.Errorf("load enrollment: %w", err)
	}
	if err := speaker.InitONNXRuntime(onnxLibPath); err != nil {
		return fmt.Errorf("init onnx runtime: %w", err)
	}

	var filtered []float32
	switch backend.Kind {
	case speaker.BackendDiarMask:
		seg, err := speaker.NewPyannoteSegmenter(backend.SegPath(modelsDir))
		if err != nil {
			return fmt.Errorf("new segmenter: %w", err)
		}
		defer seg.Close()
		encPath := backend.EncoderPath(modelsDir)
		dim := backend.EmbeddingDim
		dm, err := speaker.NewDiarMask(speaker.DiarMaskOptions{
			Segmenter: seg,
			Embed:     func(s []float32) ([]float32, error) { return speaker.ComputeEmbedding(encPath, s, dim) },
			Reference: ref,
		})
		if err != nil {
			return fmt.Errorf("new diarmask: %w", err)
		}
		filtered, err = dm.Process(context.Background(), samples)
		if err != nil {
			return fmt.Errorf("diarmask process: %w", err)
		}
	default: // BackendSeparation
		gate, err := speaker.NewSpeakerGate(speaker.SpeakerGateOptions{
			ModelPath:   backend.TSEPath(modelsDir),
			Reference:   ref,
			Threshold:   0.40,
			EncoderPath: backend.EncoderPath(modelsDir),
			EncoderDim:  backend.EmbeddingDim,
		})
		if err != nil {
			return fmt.Errorf("new speaker gate: %w", err)
		}
		defer gate.Close()
		filtered, err = gate.Extract(context.Background(), samples)
		if err != nil {
			return fmt.Errorf("extract: %w", err)
		}
	}

	if err := audio.WriteWAVMono(outputPath, filtered, targetSampleRate); err != nil {
		return fmt.Errorf("write output wav: %w", err)
	}
	return nil
}
```

- [ ] **Step 4: Add the `backend` param to the C export + marshal it**

Replace the export signature + body in `core/cmd/libhowl/tse_lab_export.go`:
```go
//export howl_tse_extract_file
func howl_tse_extract_file(inputPath, outputPath, modelsDir, voiceDir, onnxLibPath, backend *C.char) C.int {
	e := getEngine()
	if e == nil {
		return -1
	}
	if inputPath == nil || outputPath == nil || modelsDir == nil || voiceDir == nil || onnxLibPath == nil {
		e.setLastError("howl_tse_extract_file: NULL argument")
		return -1
	}
	in := C.GoString(inputPath)
	out := C.GoString(outputPath)
	models := C.GoString(modelsDir)
	voice := C.GoString(voiceDir)
	onnxLib := C.GoString(onnxLibPath)
	backendName := "" // empty → speaker.Default (ecapa)
	if backend != nil {
		backendName = C.GoString(backend)
	}
	if in == "" || out == "" || models == "" || voice == "" || onnxLib == "" {
		e.setLastError("howl_tse_extract_file: empty argument")
		return -1
	}
	if err := runAudioFilterExtractFile(in, out, models, voice, onnxLib, backendName); err != nil {
		e.setLastError("howl_tse_extract_file: " + err.Error())
		return -1
	}
	return 0
}
```
Update the doc comment above the export: note `backend` is the optional backend name (`""`/`ecapa`/`pyannote`), and that `modelsDir` may also contain `pyannote_seg.onnx`.

- [ ] **Step 5: Update the existing test's caller (the rename broke it)**

`core/cmd/libhowl/tse_lab_export_test.go:74-75` currently calls the old name:
```go
	if err := runTSEExtractFile(mixPath, outPath, modelsDir, voiceDir, onnxLib); err != nil {
		t.Fatalf("runTSEExtractFile: %v", err)
```
Change to the new name + explicit `ecapa` backend (this test exercises the separation path it always has):
```go
	if err := runAudioFilterExtractFile(mixPath, outPath, modelsDir, voiceDir, onnxLib, "ecapa"); err != nil {
		t.Fatalf("runAudioFilterExtractFile(ecapa): %v", err)
```

- [ ] **Step 6: Build libhowl + run the smokes**

```bash
cd core && go build -tags whispercpp ./cmd/libhowl/
HOWL_MODELS_DIR="$HOME/Library/Application Support/Howl/models" \
HOWL_VOICE_DIR="$HOME/Library/Application Support/Howl/voice" \
ONNXRUNTIME_LIB_PATH=/opt/homebrew/lib/libonnxruntime.dylib \
  go test -tags whispercpp ./cmd/libhowl/ -run 'TestRunAudioFilterExtractFile|ExtractFile' -count=1
```
Expected: clean build; the existing ecapa lab test still passes (or skips if models absent); the pyannote smoke PASSES if `pyannote_seg.onnx`+enrollment exist (else SKIPs cleanly).

- [ ] **Step 7: Commit**

```bash
git add core/cmd/libhowl/tse_lab_export.go core/cmd/libhowl/tse_lab_export_test.go
git commit -m "feat(libhowl): backend-aware howl_tse_extract_file (adds backend param)"
```

---

### Task 7: Swift — backend picker, threshold gating, compat, model-status row

**Files:**
- Modify: `mac/Howl/UI/Settings/Pipeline/StageDetailPane.swift` (lines 36, 74, backend picker 119-124, threshold gating)
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Storage/SettingsStore.swift:128`
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Editor/RecentSimilarityProbe.swift:21`
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Bridge/SessionManifest.swift` (add `isAudioFilter` helper)
- Modify: `mac/Howl/AppDelegate.swift` (add `ModelPaths.pyannoteSeg`)
- Modify: `mac/Howl/UI/Settings/VoiceTab.swift` (add pyannote model-status row)

**Interfaces:**
- Consumes: nothing from earlier Go tasks at compile time (Swift links the prebuilt dylib; this task is UI-only).
- Produces: `SessionManifest.Stage.isAudioFilter: Bool` (true for `"audio_filter"` or legacy `"tse"`); `ModelPaths.pyannoteSeg: URL`. The backend picker offers `ecapa` + `pyannote`; the threshold row is hidden for `pyannote`.

- [ ] **Step 1: Add the `isAudioFilter` compat helper on the manifest stage**

In `mac/Packages/HowlCore/Sources/HowlCore/Bridge/SessionManifest.swift`, inside `public struct Stage`, after the CodingKeys enum add:
```swift
        /// True for the audio-filter chunk stage, tolerating the legacy
        /// name "tse" persisted in pre-rename session manifests.
        public var isAudioFilter: Bool { name == "audio_filter" || name == "tse" }
```

- [ ] **Step 2: Use the helper in RecentSimilarityProbe**

In `mac/Packages/HowlCore/Sources/HowlCore/Editor/RecentSimilarityProbe.swift:21`, change the lookup:
```swift
            guard let af = m.stages.first(where: { $0.isAudioFilter }) else { continue }
            guard let sim = af.tseSimilarity else { continue }
```

- [ ] **Step 3: Update SettingsStore preset application to the new name (legacy-tolerant)**

In `mac/Packages/HowlCore/Sources/HowlCore/Storage/SettingsStore.swift:128`, change the chunk-stage filter:
```swift
        for st in preset.chunkStages where st.name == "audio_filter" || st.name == "tse" {
            s.tseEnabled = st.enabled
            s.tseThreshold = st.threshold
            s.tseBackend = st.backend ?? ""
        }
```

- [ ] **Step 4: Add the pyannote model path**

In `mac/Howl/AppDelegate.swift`, inside `enum ModelPaths` (after `speakerEncoder`), add:
```swift
    /// pyannote/segmentation-3.0 diarizer used by the audio-filter "pyannote"
    /// backend. Not bundled in the .app — resolved from the models dir only;
    /// absence is surfaced as a "model missing" state in Settings → Voice.
    static var pyannoteSeg: URL {
        return modelsDir.appendingPathComponent("pyannote_seg.onnx")
    }
```

- [ ] **Step 5: Add the pyannote model-status row in VoiceTab**

In `mac/Howl/UI/Settings/VoiceTab.swift`, under `SettingsGroupHeader("Voice models")`, after the speaker-encoder row, add:
```swift
            modelStatusRow(label: "Diarization model (pyannote)",
                           url: ModelPaths.pyannoteSeg)
```
(No change to `modelsPresent` — the pyannote model is optional and must not gate enrollment.)

- [ ] **Step 6: Add `pyannote` to the backend picker + gate the threshold row**

In `mac/Howl/UI/Settings/Pipeline/StageDetailPane.swift`:

Update the chunk-stage guards (lines 36 and 74) to tolerate the new name. Line 36:
```swift
                if ref.lane == .chunk && (ref.name == "audio_filter" || ref.name == "tse") {
```
Line 74:
```swift
            if (ref.name == "audio_filter" || ref.name == "tse"), let stage = draft.stage(for: ref) {
```
Add the second backend option in `backendRow` (the Picker, lines 119-124):
```swift
            )) {
                Text("ecapa — target extraction").tag("ecapa")
                Text("pyannote — diarization mask").tag("pyannote")
            }
```
Gate the threshold row in `tseBody` so it only shows for separation backends, and surface a missing-model note for pyannote:
```swift
    @ViewBuilder
    private func tseBody(ref: StageRef, stage: Preset.StageSpec) -> some View {
        backendRow(ref: ref, stage: stage)
        if (stage.backend ?? "ecapa") == "pyannote" {
            pyannoteNote()
        } else {
            thresholdRow(ref: ref, stage: stage)
            recentSimilarityRow(stage: stage)
        }
    }

    @ViewBuilder
    private func pyannoteNote() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Diarization mask is inclusion-biased — it keeps your voice and masks others, with no suppression threshold.")
                .font(.caption).foregroundStyle(.secondary)
            if !FileManager.default.fileExists(atPath: ModelPaths.pyannoteSeg.path) {
                Label("pyannote_seg.onnx not found in models dir — backend inactive until installed.",
                      systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }
```

- [ ] **Step 7: Build the macOS app + HowlCore package**

```bash
cd mac
swift build --package-path Packages/HowlCore 2>&1 | tail -20
xcodebuild -project Howl.xcodeproj -scheme Howl -configuration Debug build 2>&1 | tail -25
```
Expected: HowlCore builds; the app builds (`** BUILD SUCCEEDED **`). Fix any compile errors (e.g. `af`/binding name clashes) before proceeding.

- [ ] **Step 8: Manual verification**

Launch the Debug build, open Settings → Pipeline, select the `audio_filter` chunk stage. Confirm: the Backend picker shows `ecapa` and `pyannote`; selecting `pyannote` hides the threshold slider and shows the inclusion-biased note (and the red "model missing" line if `pyannote_seg.onnx` is absent). Open Settings → Voice and confirm the "Diarization model (pyannote)" status row shows Installed/Missing correctly.

- [ ] **Step 9: Commit**

```bash
git add mac/Howl/UI/Settings/Pipeline/StageDetailPane.swift \
  mac/Packages/HowlCore/Sources/HowlCore/Storage/SettingsStore.swift \
  mac/Packages/HowlCore/Sources/HowlCore/Editor/RecentSimilarityProbe.swift \
  mac/Packages/HowlCore/Sources/HowlCore/Bridge/SessionManifest.swift \
  mac/Howl/AppDelegate.swift mac/Howl/UI/Settings/VoiceTab.swift
git commit -m "feat(mac): pyannote backend picker, threshold gating, model-status row"
```

---

### Task 8: Swift — Lab wiring through the backend-aware C signature

**Files:**
- Modify: `mac/Packages/HowlCore/Sources/CVKB/include/libhowl_shim.h:40` (add 6th param)
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Bridge/LibhowlEngine.swift:187-205` (pass backend)
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Bridge/CoreEngine.swift:98` (protocol)
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Bridge/TSELabClient.swift` (thread backend)
- Modify: `mac/Howl/UI/Settings/Pipeline/TSELabView.swift` (backend selector)

**Interfaces:**
- Consumes: the rebuilt `libhowl.dylib` from Task 6 (6-arg `howl_tse_extract_file`).
- Produces: `CoreEngine.tseExtractFile(..., backend: String)`; `TSELabClient.extract(input: URL, backend: String)`.

- [ ] **Step 1: Update the C shim header**

In `mac/Packages/HowlCore/Sources/CVKB/include/libhowl_shim.h:40`:
```c
int howl_tse_extract_file(char* inputPath, char* outputPath, char* modelsDir, char* voiceDir, char* onnxLibPath, char* backend);
```

- [ ] **Step 2: Thread the param through the bridge implementation**

In `mac/Packages/HowlCore/Sources/HowlCore/Bridge/LibhowlEngine.swift`, replace the `tseExtractFile` method (lines 187-205) with a 6-arg version:
```swift
    public func tseExtractFile(inputPath: String, outputPath: String, modelsDir: String, voiceDir: String, onnxLibPath: String, backend: String) -> Int32 {
        return inputPath.withCString { cIn in
            outputPath.withCString { cOut in
                modelsDir.withCString { cModels in
                    voiceDir.withCString { cVoice in
                        onnxLibPath.withCString { cLib in
                            backend.withCString { cBackend in
                                howl_tse_extract_file(
                                    UnsafeMutablePointer(mutating: cIn),
                                    UnsafeMutablePointer(mutating: cOut),
                                    UnsafeMutablePointer(mutating: cModels),
                                    UnsafeMutablePointer(mutating: cVoice),
                                    UnsafeMutablePointer(mutating: cLib),
                                    UnsafeMutablePointer(mutating: cBackend)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
```

- [ ] **Step 3: Update the protocol declaration**

In `mac/Packages/HowlCore/Sources/HowlCore/Bridge/CoreEngine.swift:98`:
```swift
    func tseExtractFile(inputPath: String, outputPath: String, modelsDir: String, voiceDir: String, onnxLibPath: String, backend: String) async -> Int32
```
The only conformers are `LibhowlEngine` (Step 2, done) and the test mock `SpyCoreEngine` (`mac/Packages/HowlCore/Tests/HowlCoreTests/CoreEngineTests.swift:51`) — that mock's `tseExtractFile` is updated in Step 5.

- [ ] **Step 4: Thread backend through TSELabClient**

In `mac/Packages/HowlCore/Sources/HowlCore/Bridge/TSELabClient.swift`, change the protocol method and impl to take a backend:
```swift
public protocol TSELabClient: Sendable {
    func extract(input: URL, backend: String) async throws -> URL
}
```
and in `LibVKBTSELabClient.extract`:
```swift
    public func extract(input: URL, backend: String) async throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tse-lab-\(UUID().uuidString).wav")
        let rc = await engine.tseExtractFile(
            inputPath: input.path,
            outputPath: outURL.path,
            modelsDir: modelsDir.path,
            voiceDir: voiceDir.path,
            onnxLibPath: onnxLibPath,
            backend: backend
        )
        guard rc == 0 else {
            let detail = await engine.lastError() ?? "howl_tse_extract_file failed (rc=\(rc))"
            throw TSELabClientError.backend("rc=\(rc): \(detail)")
        }
        return outURL
    }
```

- [ ] **Step 5: Update the test mock + test callers (the signature changes broke them)**

`SpyCoreEngine` (`mac/Packages/HowlCore/Tests/HowlCoreTests/CoreEngineTests.swift:51`) conforms to `CoreEngine`; add the `backend` param to its `tseExtractFile`:
```swift
    func tseExtractFile(inputPath: String, outputPath: String, modelsDir: String, voiceDir: String, onnxLibPath: String, backend: String) -> Int32 {
```
(keep its existing body; if it records args for assertions, optionally capture `backend` too.)

`TSELabClientTests` (`mac/Packages/HowlCore/Tests/HowlCoreTests/TSELabClientTests.swift`) calls `c.extract(input:)` at lines 18, 42, 57 — add the backend arg to each:
```swift
        let out = try await c.extract(input: input, backend: "ecapa")        // line 18
        _ = try await c.extract(input: URL(fileURLWithPath: "/missing.wav"), backend: "ecapa")  // lines 42, 57
```

- [ ] **Step 6: Add a backend selector to the Lab view**

In `mac/Howl/UI/Settings/Pipeline/TSELabView.swift`, add state and a picker, and pass it into `extract`:
```swift
    @State private var labBackend: String = "ecapa"
```
In the `header` (or `inputRow`) add a small picker:
```swift
            Picker("Backend", selection: $labBackend) {
                Text("ecapa").tag("ecapa")
                Text("pyannote").tag("pyannote")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
```
In `runTSE()` (line ~309), pass the selected backend:
```swift
            let out = try await client.extract(input: input, backend: labBackend)
```

- [ ] **Step 7: Rebuild the dylib, run the package tests, build the app**

The app links `core/build/libhowl.dylib`; the 6-arg C signature must propagate there. Use the repo Makefiles (NOT an ad-hoc `go build` — `make build-dylib` also regenerates `core/build/libhowl.h` and runs `install_name_tool`):
```bash
cd core && make build-dylib                        # rebuilds core/build/libhowl.dylib with the 6-arg export
cd ../mac && swift test --package-path Packages/HowlCore 2>&1 | tail -25   # SpyCoreEngine + TSELabClientTests must compile + pass
make build 2>&1 | tail -25                          # generates the xcodeproj + xcodebuild
```
Expected: `make build-dylib` succeeds (rebuilds dylib + header); HowlCore package tests PASS; `make build` ends with `** BUILD SUCCEEDED **`. A linker/signature mismatch means the dylib wasn't rebuilt with the 6-arg export — re-run `make build-dylib`. (If `make bootstrap` deps are missing, run `cd core && make bootstrap` first.)

- [ ] **Step 8: Manual end-to-end verification**

Launch the Debug build, open Settings → Pipeline → TSE Lab. Select `pyannote`, choose/record a 2-speaker 16 kHz WAV, run it, and confirm the extracted output plays and sounds like the enrolled speaker (others time-masked, original audio preserved where you speak). Switch to `ecapa` and confirm it still runs the reconstructing path. With `pyannote_seg.onnx` absent, confirm `pyannote` fails gracefully with the `lastError` surfaced (no crash).

- [ ] **Step 9: Commit**

```bash
git add mac/Packages/HowlCore/Sources/CVKB/include/libhowl_shim.h \
  mac/Packages/HowlCore/Sources/HowlCore/Bridge/LibhowlEngine.swift \
  mac/Packages/HowlCore/Sources/HowlCore/Bridge/CoreEngine.swift \
  mac/Packages/HowlCore/Sources/HowlCore/Bridge/TSELabClient.swift \
  mac/Packages/HowlCore/Tests/HowlCoreTests/CoreEngineTests.swift \
  mac/Packages/HowlCore/Tests/HowlCoreTests/TSELabClientTests.swift \
  mac/Howl/UI/Settings/Pipeline/TSELabView.swift
git commit -m "feat(mac): TSE Lab runs the selected audio-filter backend (ecapa|pyannote)"
```

---

## Final verification (after all tasks)

- [ ] **Go:** `cd core && go test ./... -count=1` and `go test -tags whispercpp ./... -count=1` (model-gated tests skip cleanly). Expected: all PASS/SKIP, no FAIL.
- [ ] **Swift:** `cd mac && swift build --package-path Packages/HowlCore && xcodebuild -project Howl.xcodeproj -scheme Howl -configuration Debug build` → `** BUILD SUCCEEDED **`.
- [ ] **Manual smoke:** enroll a voice; in TSE Lab run a 2-speaker clip through both `ecapa` and `pyannote`; confirm the pipeline (live capture) works with `tse_backend:"pyannote"` selected via the picker; confirm an old session manifest (name `tse`) still renders its similarity badge in Compare.
- [ ] Per project memory: do NOT merge to `main`. Use superpowers:finishing-a-development-branch to choose how to finish.

## Notes / deferred

- **Persistent encoder session:** `LoadAudioFilter`'s diarmask `Embed` closure calls `speaker.ComputeEmbedding`, which opens an ONNX session per call (≤3/window). Acceptable because latency is post-capture batch. A future optimization can hold one encoder session open for the stage's lifetime.
- **"TSE Lab" / `tse_*` config keys / `tse_similarity` / `howl_tse_extract_file`** keep their legacy names by design (spec §3 B/C/D). A future cosmetic-only pass can finish the rename if desired.
