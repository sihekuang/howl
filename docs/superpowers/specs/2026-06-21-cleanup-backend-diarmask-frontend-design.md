# Cleanup Backend (diar_mask) macOS Frontend — Design Spec

**Date:** 2026-06-21
**Status:** Draft for review
**Branch:** `worktree-speaker-diarization-tse`
**Predecessor spec:** `docs/superpowers/specs/2026-06-20-diarization-mask-select-design.md` (the core `diar_mask` algorithm — already implemented and tested under `core/internal/speaker/`)

## 1. Goal

Make the already-built `diar_mask` cleanup algorithm a **user-selectable backend** in the macOS app, sitting in the same pipeline slot as today's TSE/`SpeakerGate`, chosen the same way the existing `ecapa` backend is chosen. The user can pick **`ecapa`** (target-speaker *extraction* — reconstructs the target, can over-suppress) or **`pyannote`** (diarize → cosine-SELECT the enrolled track → time-MASK the original audio — inclusion-biased, never reconstructs). Both are opt-in, both feed the same downstream Whisper → dict → LLM stages.

This ships the *mechanism* to swap in `diar_mask`, not a claim that it is universally better. Our WER sweep (`diarmask_wer_sweep_test.go`) was inconclusive on easy synthesized conditions; `diar_mask`'s value is the *safety* property (it will not filter out the user's own voice), which is exactly the pain that motivated this work. A selectable backend is the right shape for that trade-off.

## 2. Architecture: the "cleanup" slot

Today the single chunk-stage slot is named **`tse`** and only ever holds a `SpeakerGate`. Approach B (chosen) renames that **stage name** to **`cleanup`** and makes the slot backend-agnostic: it holds whatever `Stage` the selected backend constructs.

```
FrameStages: [denoise→decimate3, 48k→16k]
        │
     Chunker (16 kHz utterance chunks)
        │
   ChunkStages: [ cleanup ]   ← was [ tse ]; now backend-dispatched
        │         ├─ backend "ecapa"    → SpeakerGate           (Kind: separation)
        │         └─ backend "pyannote" → DiarMask+pyannoteSeg  (Kind: diarmask)
        │
     Whisper → dict → LLM
```

The backend is selected exactly as today: `config.TSEBackend` (engine config) / the preset stage's `backend` field / the Swift backend picker. We add `pyannote` to the registry alongside `ecapa`. The *stage* is named `cleanup`; the *backend* keeps its own identity name (`ecapa` / `pyannote`).

### 2.1 Why "cleanup", not "tse"

`tse` (target-speaker extraction) names a *technique*. The `pyannote` backend is not extraction — it is diarize-select-mask. Keeping the slot named `tse` while it holds a non-TSE algorithm is a lie in the data model (manifests, events, presets all carry `"name":"tse"`). `cleanup` names the slot by its *role* (clean up the utterance to the enrolled speaker), which both backends satisfy. This is the entire reason Approach B was chosen over Approach A (keep the `tse` slot name).

## 3. Scope boundary — what renames, what stays

The string `tse` lives in **four distinct contracts**. Approach B's intent is only the first. Renaming the others buys cosmetic consistency at a steep cost (cross-language contract breaks, a UserDefaults migration, model-file re-exports, bridge-symbol churn). The spec deliberately scopes the rename to **(A) only** and documents the rest as a back-compat decision.

| # | Contract | Examples | Decision | Rationale |
|---|----------|----------|----------|-----------|
| **A** | **Stage name** | `SpeakerGate.Name()=="tse"`, preset `{"name":"tse"}`, `st.Name()=="tse"` guards (Go ×6, Swift ×4) | **RENAME → `cleanup`** | The semantic core of Approach B. This is what makes the slot backend-agnostic in the data model. |
| **B** | **Engine config JSON keys** | `tse_enabled`, `tse_backend`, `tse_threshold`, `tse_profile_dir`, `tse_model_path` (Go `config.Config` + Swift `EngineConfig` CodingKeys) | **KEEP** | Cross-language wire contract + persisted Swift `UserDefaults`. Renaming needs a coordinated Go+Swift change *and* a settings migration, for zero functional gain. A code comment notes these keys configure the `cleanup` slot. |
| **C** | **Model-file fields** | `Backend.TSEModelFile`, `tse_model.onnx`, `Backend.TSEPath()` | **KEEP (+ generalize)** | `tse_model.onnx` is genuinely the *ecapa* backend's ConvTasNet separator — it *is* a TSE model. The `pyannote` backend brings its own `pyannote_seg.onnx`. We *add* fields, we don't rename existing ones. |
| **D** | **C-ABI symbol + debug surface** | `howl_tse_extract_file`, `tse_similarity` manifest key, "TSE Lab" tab | **KEEP symbol/key; relabel UI** | Renaming the exported C symbol churns the Swift bridge; renaming the `tse_similarity` JSON key breaks reading old session manifests. We add a `backend` *param* to the export and relabel the *visible* tab text only (open question 9.1). |

**Net:** the rename is `tse` → `cleanup` for the **stage name** everywhere it appears as a stage identity, plus a backend-struct generalization. Config keys, model filenames, the C symbol, and the manifest similarity key retain `tse` names behind a one-line comment each. A future cosmetic-only PR can finish the rename if desired.

## 4. Component design

### Layer 0 — Model: `pyannote_seg.onnx`

Produce the pyannote/segmentation-3.0 ONNX export per the committed recipe `core/BUILDING_PYANNOTE_SEG.md` (input `waveform` `[1,1,160000]`, output `segmentation` `[1,num_frames,7]`, opset 17, dynamic `num_frames`). Place it in the models dir alongside `tse_model.onnx` / `speaker_encoder.onnx`.

- **Environment:** `python3.12` (3.12.13, Homebrew) is available and torch/pyannote-compatible (default `python3` is 3.14, too new). Export runs in a throwaway `python3.12 -m venv` with `pip install torch pyannote.audio onnx`.
- **Auth (security):** the model is gated. The user must (1) accept the EULA on `huggingface.co/pyannote/segmentation-3.0` with their account, and (2) authenticate **in-session** via the `!` prefix (`huggingface-cli login`) so the token caches to `~/.cache/huggingface` by their own action — the export script reads the cache and never handles the raw token in chat. The token is never echoed, committed, or persisted to the repo.
- **Contingency (de-risk before building on it):** if `torch.onnx.export` of segmentation-3.0 fails or needs op-level iteration we can't resolve, fall back to one of: (a) wire the backend end-to-end now and ship the `.onnx` in a follow-up (the registry entry + UI degrade gracefully to a "model missing" state, see Layer 4); (b) keep the oracle/stub segmenter for tests. The Go/Swift wiring does **not** depend on the export succeeding — the model I/O contract is already fixed and unit-tested via the oracle segmenter. **Run Task 0 (the export) first** so the rest of the plan builds on a known outcome.

The `pyannote_seg.onnx` is **not** committed to git (large binary); it is resolved from the models dir at runtime exactly like `tse_model.onnx`.

### Layer 1 — Go: backend generalization + stage rename

**1a. Generalize `Backend`** (`core/internal/speaker/backend.go`). Add a `Kind` discriminator and a segmentation-model field; keep all existing fields.

```go
type BackendKind int

const (
    BackendSeparation BackendKind = iota // reconstructs target (ecapa/SpeakerGate)
    BackendDiarMask                       // diarize → select → mask (pyannote/DiarMask)
)

type Backend struct {
    Name             string
    Kind             BackendKind
    EmbeddingDim     int
    EncoderModelFile string // speaker encoder ONNX (both kinds use ECAPA encoder for cosine SELECT)
    TSEModelFile     string // separation ONNX — set only for BackendSeparation
    SegModelFile     string // segmentation ONNX — set only for BackendDiarMask
}

func (b *Backend) SegPath(modelsDir string) string { return filepath.Join(modelsDir, b.SegModelFile) }
```

Register `pyannote`:

```go
var Pyannote = &Backend{
    Name:             "pyannote",
    Kind:             BackendDiarMask,
    EmbeddingDim:     192,                    // reuses the ECAPA encoder for cosine SELECT
    EncoderModelFile: "speaker_encoder.onnx",
    SegModelFile:     "pyannote_seg.onnx",
}
// backends registry gains: Pyannote.Name: Pyannote
```

`ECAPA` gains `Kind: BackendSeparation` (zero-value, but set explicitly for clarity). `Default` stays `ECAPA`.

**1b. Rename the stage name** `tse` → `cleanup`:
- `core/internal/speaker/speakerbeam.go:112` — `SpeakerGate.Name()` returns `"cleanup"` (currently `"tse"`).
- `core/internal/speaker/diarmask.go:180` — `DiarMask.Name()` returns `"cleanup"` (currently `"diar_mask"`).
- Both backends' stages now report the same slot name `cleanup`, which is correct — only one occupies the slot at a time. (`diarmask.go`'s tests assert `Name()`; update those fixtures alongside.)

**1c. `LoadCleanup` dispatch** — rename/replace `LoadTSE` (`core/internal/pipeline/pipeline.go:367`) with a backend-kind switch returning an `audio.Stage` named `cleanup`. It reuses the existing profile-load / `LoadEmbedding` / `InitONNXRuntime` preamble verbatim (lines 368-388) and only branches on the final construction. The real constructors take **options structs**, and `DiarMask` takes an `Embed` *closure* (built over the ECAPA encoder via `speaker.ComputeEmbedding`), not an encoder path:

```go
func LoadCleanup(backend *speaker.Backend, profileDir, modelsDir, onnxLibPath string, threshold float32) (audio.Stage, error) {
    if backend == nil { backend = speaker.Default }
    // ── identical preamble to today's LoadTSE ──
    if _, err := speaker.LoadProfile(profileDir); os.IsNotExist(err) {
        return nil, nil // no enrollment — cleanup off
    } else if err != nil { return nil, fmt.Errorf("load cleanup: profile: %w", err) }
    ref, err := speaker.LoadEmbedding(profileDir+"/enrollment.emb", backend.EmbeddingDim)
    if err != nil { return nil, fmt.Errorf("load cleanup: embedding: %w", err) }
    if err := speaker.InitONNXRuntime(onnxLibPath); err != nil {
        return nil, fmt.Errorf("load cleanup: onnx runtime: %w", err)
    }
    // ── branch on backend kind ──
    switch backend.Kind {
    case speaker.BackendSeparation:
        opts := speaker.SpeakerGateOptions{ModelPath: backend.TSEPath(modelsDir), Reference: ref, Threshold: threshold}
        if threshold > 0 {
            opts.EncoderPath = backend.EncoderPath(modelsDir)
            opts.EncoderDim = backend.EmbeddingDim
        }
        return speaker.NewSpeakerGate(opts)
    case speaker.BackendDiarMask:
        seg, err := speaker.NewPyannoteSegmenter(backend.SegPath(modelsDir)) // InitONNXRuntime already called
        if err != nil { return nil, fmt.Errorf("load cleanup: segmenter: %w", err) }
        encPath, dim := backend.EncoderPath(modelsDir), backend.EmbeddingDim
        return speaker.NewDiarMask(speaker.DiarMaskOptions{
            Segmenter: seg,
            Embed:     func(s []float32) ([]float32, error) { return speaker.ComputeEmbedding(encPath, s, dim) },
            Reference: ref,
            // NOTE: `threshold` is deliberately NOT wired — diarmask has no
            // suppression gate (decision 1f). Defaults apply (MinSelectCosine 0.40,
            // FallbackPassthrough true, BoundaryRampMs 15).
        })
    default:
        return nil, fmt.Errorf("load cleanup: unknown backend kind %v", backend.Kind)
    }
}
```

`core/internal/pipeline/build/build.go:107` calls `LoadCleanup` instead of `LoadTSE`. The `cfg.TSE*` field reads are unchanged (decision B). The `tse:`/`load tse:` error-prefix strings become `cleanup:`/`load cleanup:` (these are internal log strings, low-risk to rename and improve clarity).

**Perf note (plan-level):** `ComputeEmbedding` opens the encoder ONNX session *per call*, and `DiarMask` embeds up to 3 candidate tracks per 10 s window. In the live per-chunk path that is wasteful. The plan should build the `Embed` closure over a **persistent** encoder session (open once in `LoadCleanup`, reuse across calls, close on stage `Close()`) rather than calling the session-opening `ComputeEmbedding` each time. The offline Lab path (batch) can tolerate the simpler form.

**1d. Type-driven similarity hook** — drop the now-redundant name guard at `manifest.go:52` and `pipeline.go:156`. Both sites *already* do `st.(interface{ LastSimilarity() float32 })` after the name check; since both backends implement `LastSimilarity() float32`, the name check is removable and the type assertion alone is correct and more robust:

```go
// manifest.go and pipeline.go — was: if st.Name()=="tse" { if g,ok := st.(...) ... }
if g, ok := st.(interface{ LastSimilarity() float32 }); ok {
    sim := g.LastSimilarity()
    entry.TSESimilarity = &sim // JSON key stays "tse_similarity" (decision B/D)
}
```

`DiarMask.LastSimilarity()` already returns `float32` (verified at `diarmask.go:185` — it tracks the best target-track cosine from the last `Process`), so it satisfies the interface directly.

**1e. Preset / CLI name matching** — `core/internal/presets/resolve.go:90,140` (`st.Name != "tse"`) and `core/cmd/howl-cli/pipe.go:81` change `"tse"` → `"cleanup"`. The bundled `pipeline-presets.json` (4 presets) change each chunk stage `"name":"tse"` → `"name":"cleanup"`. CLI flag `--tse-backend` keeps its name (decision B; it maps to `cfg.TSEBackend`).

**1f. Threshold semantics across backends** — the single `tse_threshold` config value means *post-extract suppression gate* for `ecapa` (zeros a chunk that doesn't sound enough like the user). `diarmask` has **no such gate** — it is inclusion-biased by construction. So for the `pyannote` backend the threshold is **inert** (not wired into `MinSelectCosine`; the preset values 0.35/0.45 were calibrated for the TSE gate and have no analogous meaning here). The UI disables/hides the threshold control when `pyannote` is selected (Layer 4) so the inert control doesn't mislead.

### Layer 2 — Compat shim: legacy `tse` stage name

Presets and session manifests written **before** this change carry `"name":"tse"`. After the rename, name-matching against `"cleanup"` would silently ignore them (old Compare sessions wouldn't show the cleanup stage; an old saved preset wouldn't apply). Add a single normalization point on **read**:

- **Go (preset load):** in `presets/resolve.go` where preset stages are read, map a stage whose name is `"tse"` → `"cleanup"` before matching. One helper `normalizeStageName(name string) string`.
- **Swift (manifest + preset read):** in `SettingsStore.applyPreset` (`SettingsStore.swift:128`) and `RecentSimilarityProbe` (`:21`) and `StageDetailPane` (`:36,:74`), match `name == "cleanup" || name == "tse"` (legacy). A single `Stage.isCleanup` computed helper avoids scattering the `||`.

New writes always emit `cleanup`. We do **not** rewrite old session manifests on disk; reads tolerate both. No version bump needed (additive tolerance).

### Layer 3 — C-ABI: backend-aware offline extract

`howl_tse_extract_file` (`core/cmd/libhowl/tse_lab_export.go:41`) currently hardcodes `speaker.Default` (ecapa → `SpeakerGate`). Add a `backend` param so the Lab / Compare can exercise either backend offline:

```go
//export howl_tse_extract_file
func howl_tse_extract_file(inputPath, outputPath, modelsDir, voiceDir, onnxLibPath, backend *C.char) C.int
```

Internally: `b, err := speaker.BackendByName(C.GoString(backend))` (empty → Default), then dispatch on `b.Kind` mirroring `LoadCleanup` — `BackendSeparation` runs the existing `SpeakerGate` path; `BackendDiarMask` constructs `DiarMask` and runs its offline `Process` over the file's 16 kHz PCM, writing a 16 kHz WAV. The export **name stays** `howl_tse_extract_file` (decision D — avoids bridge-symbol churn); only its signature gains the param. The single Swift caller (`TSELabClient`) is updated in lockstep.

### Layer 4 — Swift: backend picker, model status, wiring

**4a. Backend picker** (`mac/Howl/UI/Settings/Pipeline/StageDetailPane.swift:120-123`) — the picker currently has a single hardcoded `Text("ecapa").tag("ecapa")`. Add `pyannote`:

```swift
Picker("Backend", selection: backendBinding) {
    Text("ecapa — target extraction").tag("ecapa")
    Text("pyannote — diarization mask").tag("pyannote")
}
```

The stage-detail guards (`:36`, `:74`) match the cleanup slot via the `isCleanup` helper (Layer 2). When the selected backend is `pyannote`, **disable/hide the threshold control** in this pane (decision 1f — the threshold is inert for diarmask) and show a one-line note that pyannote is inclusion-biased and has no suppression gate.

**4b. Model-status row** (`mac/Howl/UI/Settings/VoiceTab.swift`, beside the existing `tse_model.onnx` / `speaker_encoder.onnx` help text ~line 118) — add a `pyannote_seg.onnx` presence row. When the `pyannote` backend is selected but the model file is absent, show a clear **"Diarization model missing — pyannote_seg.onnx not found in models dir"** state and disable enabling the backend (graceful degradation; this is the Layer 0 contingency's UI surface). Model presence is checked the same way `AppDelegate.swift:205-219` resolves `tse_model.onnx`.

**4c. Lab wiring** — `TSELabClient` (Swift) passes the selected backend string through to `howl_tse_extract_file`'s new `backend` param. The Lab view (`TSELabView.swift`) gains a backend selector (or reads the current cleanup-stage backend) so a developer can run either backend on an arbitrary clip.

**4d. Reused unchanged** — enrollment (`howl_enroll_compute`, `EnrollmentSheet`), `WAVPlayer`, `ComparePane`, `StageList`, the per-stage similarity badge (driven by `tseSimilarity` in `SessionManifest.swift`, populated for whichever backend per Layer 1d), and `WaveformView`. The stage label shown in the pipeline UI follows the stage name → reads "cleanup".

## 5. Data flow

```
Swift backend picker ("ecapa"|"pyannote")
   → UserSettings.tseBackend  (key "tse_backend", decision B)
   → EngineConfig JSON → Go config.Config.TSEBackend
   → build.FromOptions: BackendByName(cfg.TSEBackend) → LoadCleanup(backend, …)
        → SpeakerGate  (Kind separation)  OR  DiarMask+pyannoteSeg (Kind diarmask)
        → p.ChunkStages = [ stage named "cleanup" ]
   → per chunk: stage.Process → LastSimilarity() (type-driven) → Event + manifest "tse_similarity"
   → SessionManifest stage {name:"cleanup", kind:"chunk", tse_similarity:…}
   → Swift Compare / similarity badge render generically
```

## 6. Error handling

| Condition | Behavior |
|-----------|----------|
| `pyannote` selected, `pyannote_seg.onnx` missing | `LoadCleanup` returns error → `build.FromOptions` logs + `setLastError`, pipeline continues **without** the cleanup stage (same fail-open path as today's TSE load failure, `build.go:108-110`). Swift shows the "model missing" row (4b). |
| Enrollment profile missing | `LoadCleanup` returns `nil` stage (today's behavior) → no cleanup stage; log "no enrollment found". |
| Unknown backend name | `BackendByName` returns error → fail-open, logged. |
| Segmenter ONNX shape mismatch | `pyannoteSegmenter`/`powersetToActivity` already guard last-dim==7 and frame count; surfaced as a `Process` error → chunk worker error (existing path `pipeline.go:147`). |
| Export (Layer 0) fails | Contingency in §4 Layer 0 — wiring ships, model follows; UI degrades to "model missing". |

## 7. Testing

Per `core/CLAUDE.md`, audio changes plug into the existing harness — already satisfied by the committed `diar_mask` tests (`diarmask_synth_test.go`, `diarmask_wer_sweep_test.go`). This frontend work adds **wiring** tests, not new audio-quality claims:

- **Go — backend dispatch** (`backend_test.go` / `pipeline` test): `LoadCleanup` with backend `pyannote` (Kind diarmask) returns a `Stage` named `cleanup` and constructs a `DiarMask`; with `ecapa` returns a `SpeakerGate` named `cleanup`. `BackendByName("pyannote")` resolves; `BackendNames()` includes it sorted.
- **Go — type-driven similarity** (`manifest_test.go`): a `DiarMask`-shaped fake exposing `LastSimilarity() float32` populates `TSESimilarity` with the name guard removed; a stage without the method leaves it nil. (Existing `manifest_test.go:45` `fakeChunkStage` already covers the shape.)
- **Go — compat shim** (`resolve` test): a preset stage named `tse` normalizes to `cleanup` and matches; a `cleanup` stage matches directly.
- **C-ABI smoke** (tag-gated, needs the model): `howl_tse_extract_file` with `backend="pyannote"` on a 2-speaker WAV produces a 16 kHz output WAV (skips cleanly if `pyannote_seg.onnx` absent — mirrors existing `diarmask_pyannote_test.go` skip).
- **Swift — build + manual**: app builds; select `pyannote` in the picker, run the Lab on a clip, confirm the cleanup stage appears in Compare with a similarity badge; confirm the "model missing" state when the model is absent.

## 8. File-change inventory (for the plan)

**Go:** `speaker/backend.go` (Kind, SegModelFile, Pyannote, registry) · `speaker/speakerbeam.go:112` + `speaker/diarmask.go` (Name→"cleanup") · `pipeline/pipeline.go` (LoadTSE→LoadCleanup, drop name guard :156) · `pipeline/manifest.go:52` (drop name guard) · `pipeline/build/build.go:107` (LoadCleanup) · `presets/resolve.go:90,140` + `presets/normalize` (compat) · `cmd/howl-cli/pipe.go:81` · `assets/pipeline-presets.json` (×4) · `cmd/libhowl/tse_lab_export.go` (backend param + dispatch). Tests: `backend_test.go`, `manifest_test.go`, `resolve` test, tagged C-ABI/pyannote smoke.

**Swift:** `StageDetailPane.swift:36,74,120-123` (picker + isCleanup) · `SettingsStore.swift:128` (compat) · `RecentSimilarityProbe.swift:21` (compat) · `VoiceTab.swift` (model-status row) · `TSELabClient.swift` + `TSELabView.swift` (backend param) · a `Stage.isCleanup` helper. Unchanged: `EngineConfig.swift`, `SessionManifest.swift` (keys keep `tse_*` per B/D), enrollment, players, Compare.

## 9. Open questions / risks

1. **"TSE Lab" tab label** — rename to "Cleanup Lab" for consistency with the renamed stage, or leave as "TSE Lab" (it is a developer debug surface)? Recommendation: leave the tab label as-is this pass (decision D); it is dev-only and renaming is pure cosmetics. *Confirm during review.*
2. **`tse_similarity` misnomer for diarmask** — the manifest key carries the cosine SELECT similarity for the `pyannote` backend, which is a *selection* score, not a TSE score. Kept for back-compat (decision B/D). Acceptable misnomer; documented in code.
3. **Export risk** — the Layer 0 contingency covers a failed ONNX export; the wiring is export-independent. This is the single biggest schedule risk and is sequenced first.
4. **Branch policy** — per project memory, cleanup-router work stays on the feature branch; do not merge to `main` without explicit say-so. This spec does not change that.

## 10. Non-goals

- No change to the `diar_mask` algorithm itself (already specced + implemented).
- No renaming of config JSON keys, model filenames, or the C-ABI symbol (decisions B/C/D).
- No claim that `pyannote` beats `ecapa` on WER — it is an opt-in safety-biased alternative.
- No new noise-fixture work (the deferred MUSAN/DEMAND stress test remains deferred).
