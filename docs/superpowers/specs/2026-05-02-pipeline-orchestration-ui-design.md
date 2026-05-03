# Pipeline Orchestration UI — Design Spec

**Status**: Draft for review
**Date**: 2026-05-02
**Audience**: Power users / contributors (gated behind a Developer-mode toggle)

## Overview

A "Pipeline" Settings tab, hidden behind a Developer-mode toggle, that lets power users **observe, configure, and compare** the audio pipeline that turns mic input into typed text. Four sub-features layered into one tab:

1. **Inspector** — live read-only view of the active pipeline, showing each stage, its sample-rate contract, and per-stage outputs (WAVs + transcripts) from the most recent dictation.
2. **Per-stage capture** — automatic capture of every dictation's per-stage WAVs + transcripts to a temp folder, surfaced in the Inspector. Always-on while Developer mode is active. Last N sessions retained; user-controllable bulk and per-session delete.
3. **Editable graph** — drag-and-drop pipeline editor anchored to known-good preset configurations. Users can swap stage implementations, toggle stages on/off, reorder within a lane (with constraint validation), and tune per-stage parameters (TSE threshold, etc.). Edits silently fork the active preset to a synthetic "Custom" entry; one-click Reset returns to Default.
4. **A/B comparison** — capture a dictation once, replay the captured audio through N presets via `audio.FakeCapture`, render the resulting transcripts side-by-side. Same audio, different pipelines — the only fair-apples-to-apples way to evaluate alternative configurations.

Plus a **CLI parity surface** (`vkb-cli presets`, `vkb-cli sessions`, `vkb-cli compare`) so the Mac app and `vkb-cli` are two consumers of the same underlying Go primitives, never talking process-to-process.

### Audience and scope

The Pipeline tab is **not for casual users**. It only appears when "Developer mode" is enabled in General Settings. Public-launch posture: most users never see this; the curious / contributing crowd unlocks it.

### Out of scope (v1)

- Plugin API for user-supplied stages — stages stay Go-defined and `Backend`-registered.
- Cross-process pipeline editing — single-process Settings UI; engine rebuilds on save like every other setting.
- Telemetry / quality scoring of comparisons — transcripts shown side-by-side; user judges quality.
- Migration code for existing settings — versioning infrastructure is in place (see "Versioning policy"), but no schema breaks happen in this spec.

## Architecture

### Code layout

```
core/
├── configs/
│   └── pipeline-presets.json            NEW — bundled presets (read by both consumers)
└── internal/
    ├── presets/                          NEW
    │   ├── presets.go                    Loader + schema + Resolve / Match
    │   ├── builtin.go                    //go:embed of pipeline-presets.json
    │   ├── user.go                       Save / Load / Delete user presets on disk
    │   └── presets_test.go
    ├── sessions/                         NEW
    │   ├── sessions.go                   List / Show / Delete / Clear; pruning
    │   ├── manifest.go                   session.json schema
    │   └── sessions_test.go
    ├── replay/                           NEW
    │   ├── replay.go                     RunReplay; uses FakeCapture + transient pipelines
    │   └── replay_test.go
    ├── pipeline/                         existing — Pipeline, FrameStages, ChunkStages
    ├── recorder/                         existing — extended to write session.json
    ├── speaker/                          existing — TSE + Backend; new threshold field
    └── llm/                              existing — Provider registry

mac/VoiceKeyboard/UI/Settings/
├── Pipeline/                             NEW (subdirectory for the new tab)
│   ├── PipelineTab.swift                 SettingsPane container, sub-view router
│   ├── InspectorView.swift               Phase 1+2 — live status + session picker
│   ├── EditorView.swift                  Phase 3 — preset dropdown + drag-drop graph
│   ├── CompareView.swift                 Phase 4 — pick session + presets, side-by-side
│   ├── PresetPicker.swift                shared dropdown
│   ├── StageGraph.swift                  drag-drop graph (used in Editor + Inspector read-only)
│   └── SaveAsPresetSheet.swift           naming sheet for user presets
├── GeneralTab.swift                      modified — add Developer mode toggle
└── SettingsView.swift                    modified — Pipeline page added when dev mode on
```

### Data flow

The Mac app and `vkb-cli` are **two separate consumers of the same Go packages**. The Mac app talks to `libvkb.dylib` via the existing C ABI (in-process); `vkb-cli` imports the Go packages directly. No process-to-process communication.

```
┌──────────────────────────────────────────────────────────┐
│  Go packages (single source of truth)                    │
│  presets/   sessions/   replay/                          │
│  pipeline/  speaker/    llm/   ...                       │
└────────────┬─────────────────────────────────┬───────────┘
             │ Go imports                      │ Go imports
             ▼                                 ▼
┌────────────────────────┐         ┌──────────────────────┐
│ libvkb.dylib (C ABI)   │         │ vkb-cli binary       │
└────────────┬───────────┘         └──────────────────────┘
             │ cgo bridge
             ▼
┌────────────────────────┐
│ Mac SwiftUI app        │
└────────────────────────┘
```

### C ABI extensions

```c
// Presets
const char* vkb_list_presets(void);                   // JSON array of {name, description, source}
const char* vkb_get_preset(const char* name);         // JSON-resolved EngineConfig
int         vkb_save_preset(const char* name,
                             const char* description,
                             const char* engine_config_json);
int         vkb_delete_preset(const char* name);      // user presets only

// Sessions
const char* vkb_list_sessions(void);                  // JSON array of session manifests
const char* vkb_get_session(const char* id);          // JSON manifest
int         vkb_delete_session(const char* id);
int         vkb_clear_sessions(void);

// Replay (A/B comparison)
const char* vkb_replay(const char* session_id,
                       const char* presets_csv);      // JSON: [{preset, transcript, error?, timings...}]

// Versioning
const char* vkb_abi_version(void);                    // semver string e.g. "1.0.0"
```

All return JSON for the cgo bridge. Same ownership convention as `vkb_poll_event`: the library mallocs the returned string; the caller frees via `vkb_free`.

## Component breakdown

### Developer mode toggle

Lives in **General tab**, beneath "Open at login":

```
Toggle: "Developer mode"
Caption: "Show the Pipeline tab — captures per-stage audio + transcripts to /tmp on every dictation."
```

Stored as `UserSettings.developerMode: Bool` (default `false`). When true: Pipeline tab appears in the Settings sidebar; engine starts capturing sessions on every dictation. When toggled off: Pipeline tab disappears; capture stops; existing temp sessions left in place (deletable by user via Clear all, or by macOS on next reboot).

### Preset system

#### JSON schema (versioned at birth)

`core/configs/pipeline-presets.json`, loaded into Go via `//go:embed`:

```json
{
  "version": 1,
  "presets": [
    {
      "name": "default",
      "description": "Standard pipeline: denoise → decimate → TSE → Whisper → dict → LLM cleanup.",
      "frame_stages": [
        {"name": "denoise",   "enabled": true},
        {"name": "decimate3", "enabled": true}
      ],
      "chunk_stages": [
        {"name": "tse", "enabled": true, "backend": "ecapa", "threshold": 0.0}
      ],
      "transcribe": {"model_size": "small"},
      "llm":        {"provider": "anthropic"},
      "timeout_sec": 10
    }
  ]
}
```

`name` keys into the existing `audio.Stage` registry (unknown name = load error). `backend` is per-stage (only TSE has multiple backends today; future stages slot in cleanly). `transcribe`, `llm`, and `timeout_sec` re-use the existing field names from `EngineConfig` so the resolver is a one-to-one mapping.

#### Bundled presets (v1)

1. **`default`** — current pipeline. Mirrors today's defaults bit-identical.
2. **`minimal`** — no denoise, no TSE, raw mic → Whisper → dict → LLM. Fast baseline; A/B anchor.
3. **`aggressive`** — denoise + TSE + larger Whisper (`base`). Quality-leaning.
4. **`paranoid`** — denoise + TSE with threshold 0.7 (silences low-confidence chunks). Hallucination-resistant in noisy environments.

#### User presets

Stored in `~/Library/Application Support/VoiceKeyboard/presets/<name>.json`, one file per preset. Same schema as bundled. Filenames must match `^[a-z0-9_-]{1,40}$`. Bundled-name collisions are rejected. Malformed user presets are skipped at load with a logged error (one bad file mustn't break the picker).

#### Resolver and "Custom" detection

```go
// presets/presets.go
func Load() ([]Preset, error)                               // bundled + user, in that order
func Resolve(p Preset, secrets EngineSecrets) EngineConfig  // preset → EngineConfig
func Match(cfg EngineConfig, all []Preset) string           // "default" / "minimal" / ... / "custom"
```

`Match` is pure structural comparison on the resolved `EngineConfig` fields the preset specifies. The UI dropdown shows the matched preset, or silently flips to "Custom" the moment the user diverges.

### Phase 1+2 — Inspector + always-on capture

Live status panel showing each stage of the active pipeline + the per-stage outputs from the most recent session.

#### Capture mechanics

When Developer mode is on, every dictation writes to:

```
/tmp/voicekeyboard/sessions/<timestamp>/
├── session.json            (manifest)
├── frame-stages/
│   ├── denoise.wav
│   └── decimate3.wav
├── chunk-stages/
│   └── tse.wav
└── transcripts/
    ├── raw.txt             (Whisper output, before dict)
    ├── dict.txt            (after fuzzy-dict correction)
    └── cleaned.txt         (after LLM cleanup)
```

- **Retention**: keep last 10 sessions (configurable later); prune older at session start.
- **Cleanup**: temp folder; macOS evicts on reboot or under pressure.
- **Privacy**: only happens when Developer mode is on (informed-consent gate).
- **No "arm" button**: outputs are always available.

#### Session manifest schema

```json
{
  "version": 1,
  "id": "2026-05-02T14:32:11Z",
  "preset": "default",
  "duration_sec": 3.2,
  "stages": [
    {"name": "denoise",   "kind": "frame", "wav": "frame-stages/denoise.wav",   "rate_hz": 48000},
    {"name": "decimate3", "kind": "frame", "wav": "frame-stages/decimate3.wav", "rate_hz": 16000},
    {"name": "tse",       "kind": "chunk", "wav": "chunk-stages/tse.wav",       "rate_hz": 16000,
                          "tse_similarity": 0.62}
  ],
  "transcripts": {"raw": "transcripts/raw.txt", "dict": "transcripts/dict.txt", "cleaned": "transcripts/cleaned.txt"}
}
```

The manifest is the contract between writers (Go pipeline + recorder) and readers (Mac Inspector, `vkb-cli sessions`, replay engine). New optional fields can be added without bumping `version`; structural changes bump.

#### UI surfaces

- **Session picker** (top of tab): "Latest" or one of the last N sessions. Each row shows timestamp + preview of cleaned transcript + 🗑 delete button. "Reveal in Finder" + "Clear all" buttons next to it.
- **Live status indicator**: idle / recording / processing.
- **Stage rows** in three labeled groups:
  - **Streaming stages** (frame stages: denoise, decimate3) — sample-rate badge, ▶ Play button, file size.
  - **Chunker boundary** (visual separator).
  - **Per-utterance stages** (chunk stages: TSE) — same controls + backend badge.
- **Transcribe + cleanup chain** — shows raw / dict / cleaned text inline + 📄 View buttons.
- **▶ Play** opens the WAV in the system audio player (`NSWorkspace.open`).
- **📄 View** opens a sheet with the transcript text + Copy button.

### Phase 3 — Editable graph

#### Layout

Three lanes feeding a fixed terminal chain:

```
Streaming stages → Chunker → Per-utterance stages → [Whisper → Dict → LLM]
   (drag within)              (drag within)              (fixed, not draggable)
```

The chunker boundary and the terminal chain are structural — not draggable.

#### Drag mechanics

- **Within a lane**: reorder via SwiftUI `List` + `onMove`. Constraint validator runs on drop; sample-rate-incompatible orderings are rejected with a red overlay + tooltip ("decimate3 outputs 16 kHz; denoise expects 48 kHz — incompatible").
- **Across lanes**: blocked structurally (cross-lane moves are physically invalid — chunk stages need a chunk to operate on). The drop target doesn't accept the drag at all.

#### Per-stage detail panel

Selected stage highlights in the graph; detail panel below shows its tunables:

- **Enabled** toggle (per-stage on/off).
- **Backend** dropdown (e.g., `ecapa`; populated from the existing `Backend` registry).
- **Threshold** slider (TSE-specific; 0.0–1.0).
- **Recent similarity** readout (TSE-specific): last 5 chunk cosine similarities pulled from session manifests, color-coded above/below threshold for live calibration.

#### Toolbar

```
Preset: [Default ▾]  [💾 Save as preset…]  [↺ Reset]  |  Timeout: [10] s
```

- **Save as preset…** opens a sheet (name + description, with regex validation + collision check).
- **Reset** returns to whatever bundled preset was active before edits.
- **Timeout** is a per-preset value, mirrored into `EngineConfig.PipelineTimeoutSec`.

### Phase 4 — Compare view

Pick one captured session as the audio source; replay through N presets via `FakeCapture`; render results side-by-side.

#### Mechanics

- The source session's `denoise.wav` (raw 48 kHz mic input) is fed via `audio.FakeCapture` into a fresh transient pipeline built from each chosen preset.
- Each replay writes a *new* session under the source's prefix: `<source-id>/replay-<preset>/`. Replays don't pollute the main session list (filterable in the Inspector).
- Results render as cards (one per preset): pipeline summary string, per-stage transcripts (raw / dict / cleaned), per-stage timings, total time, ▶ TSE-output play button.
- The "closest match" badge marks the result with the lowest Levenshtein distance to the original dictation's final transcript — heuristic pointer, not a quality verdict.

#### Cold-start optimization

Replays in the same Compare run reuse a warm Whisper instance when the model size is identical (which it usually is). Avoids 3× model-load latency for a 3-preset comparison.

### Pipeline timeout (best-effort)

New per-preset field `timeout_sec` (default 10s); mirrored into `EngineConfig.PipelineTimeoutSec`. Engine wraps `pipeline.Run(ctx, …)` with `context.WithTimeout`. On expiry: in-flight LLM/Whisper/TSE calls abort via their existing context plumbing → pipeline returns whatever cleaned text streamed so far. If no cleaned text, dict-corrected raw is the fallback (matches the existing "LLM error → fall back to dict-corrected raw" pattern).

The Mac UI surfaces a transient warning: *"Pipeline timed out after 10s. Increase the timeout in the Pipeline tab if this is a slow-model cold start."*

`timeout_sec: 0` disables the timeout entirely (escape hatch).

### TSE threshold + cosine similarity

New `Threshold float32` field on `SpeakerGate`. After computing similarity, if below threshold, returns zeros (same length as input). Default 0.0 = no gating (back-compat with current behavior).

The cosine similarity per chunk is added to the chunk event payload (new field `tse_similarity float32`) and to `session.json`'s per-stage entry. The Editor view's "Recent similarity" readout pulls the last 5 from session manifests for calibration.

### CLI parity (`vkb-cli`)

Same Go primitives, no SwiftUI. Subcommands:

```
vkb-cli pipe --preset <name>                       # use a named preset
vkb-cli pipe --preset <name> --capture             # explicit capture (CLI default: off)
vkb-cli pipe --no-capture                          # explicit override
vkb-cli presets list                               # human table or --json
vkb-cli presets show <name>                        # resolved EngineConfig
vkb-cli presets save <name> [--description "…"] [--from <session-id>]
vkb-cli presets delete <name>                      # user presets only
vkb-cli sessions list                              # ID, timestamp, preset, duration, transcript
vkb-cli sessions show <id>                         # session.json manifest
vkb-cli sessions delete <id>
vkb-cli sessions clear [--force]
vkb-cli compare <session-id> --presets <a,b,c> [--json]
```

Existing `pipe` flags (`--llm-provider`, `--llm-model`, `--dict`, `--speaker`, `--tse-backend`) keep working; they layer **after** the preset for ad-hoc field overrides.

Every list/show command supports `--json` for piping into tooling. Default human format is for terminals.

## Versioning policy

| Artifact | Version field | Notes |
|---|---|---|
| Preset JSON | explicit `"version": 1` | Loader rejects unknown major versions. Migrations land when v2 ships. |
| Session manifest | explicit `"version": 1` | Forward-/backward-compat at read time. New fields default sensibly. |
| `EngineConfig` (UserDefaults) | implicit via `…UserSettings.v1` key suffix | All schema growth so far additive. Bump key suffix when breaking compat; write one-time migration adapter then. |
| C ABI | `vkb_abi_version()` returns semver | Mac app asserts compat at startup. Cheap insurance against dylib mismatch. |

**Migration code is deliberately out of scope for v1.** Versioning infrastructure is in place; migration logic lands when the first breaking change happens.

## Engineering risks + mitigations

### 1. SwiftUI drag-and-drop on a graph (not a list) is real engineering

3–5 days for the editor UI alone. Constrain drag scope: only within a lane (cross-lane is structurally invalid anyway). For within-lane reorder, lean on SwiftUI's `List` with `onMove` (battle-tested). Custom code only for the constraint validation overlay (~50 lines). If validation UX gets fiddly, simplify to a post-drop modal rather than live red-line feedback.

### 2. Replay path has more edge cases than it looks

Two-step rollout:
- **(a)** Replay against the **input WAV** (raw 48 kHz mic) — every preset starts from the same point.
- **(b)** Defer "replay starting from a midstream stage" to v2.

The full-pipeline replay is the 80% case.

### 3. C ABI surface grows by ~7 functions

Each needs error reporting (existing `vkb_last_error`), JSON encoding, and ownership convention. Inconsistencies cause leaks or crashes that don't surface in the Go test suite.

**Mitigation**: follow the `vkb_poll_event` pattern (library mallocs, caller frees via `vkb_free`). Add `core/cmd/libvkb/c_abi_test.go` exercising each new function via the C ABI directly, with leak-detector assertions.

### Mid-tier risks

- **Backwards compatibility**: existing `UserSettings.tseEnabled` etc. must keep working. Mitigation: presets resolve to *exactly* the existing `EngineConfig` shape; the `default` preset produces a config bit-identical to today's defaults. Verified by `TestResolve_DefaultPresetMatchesEngineConfig`.
- **Cold-start cost on Compare**: warm Whisper instance reused across replays in the same compare run when model size is identical.
- **Test surface explosion**: each new package tested at its own boundary; integration tests only at the C ABI seam and the Compare-end-to-end seam.

## Testing strategy

### Go unit tests

**`presets`**:
- `TestLoad_BundledFileParses`
- `TestLoad_RejectsUnknownStage`
- `TestLoad_RejectsUnknownVersion`
- `TestLoad_RejectsMalformedJSON`
- `TestLoad_SkipsMalformedUserPreset_LogsAndContinues`
- `TestResolve_DefaultPresetMatchesEngineConfig` (back-compat regression)
- `TestMatch_AllBundledPresetsAreSelfMatching`
- `TestMatch_DivergedConfigReturnsCustom`
- `TestSaveUser_RoundTrips`
- `TestSaveUser_RejectsBundledNameCollision`
- `TestSaveUser_RejectsInvalidName`
- `TestDeleteUser_RemovesFile`
- `TestDeleteUser_RejectsBundled`

**`sessions`**:
- `TestManifest_WriteReadRoundTrip`
- `TestList_ReturnsChronologicalOrder`
- `TestDelete_RemovesFolder`
- `TestClear_RemovesAll`
- `TestPruning_KeepsNMostRecent`

**`replay`**:
- `TestReplay_PreservesAudioLength`
- `TestReplay_DefaultPresetReproducesSourceTranscript`
- `TestReplay_DifferentPresetProducesDifferentOutput`
- `TestRunCompare_ReturnsResultPerPreset`

**`speaker` (TSE additions)**:
- `TestTSE_BelowThresholdReturnsZeros`
- `TestTSE_AboveThresholdReturnsExtracted`
- `TestTSE_ThresholdZeroDisablesGating`
- `TestTSE_EmitsCosineSimilarityInEvent`

**`pipeline` (timeout additions)**:
- `TestRun_TimeoutFires_PartialReturnedOnBestEffort`
- `TestRun_TimeoutZero_NoTimeoutApplied`
- `TestRun_TimeoutDefault10s`

### C ABI integration tests

`core/cmd/libvkb/c_abi_test.go`:
- `TestCABI_ListPresets_OwnershipAndJSON`
- `TestCABI_ListSessions_*`, `TestCABI_GetSession_*`, `TestCABI_DeleteSession_*`, `TestCABI_ClearSessions_*`
- `TestCABI_Replay_RoundTrip`
- `TestCABI_Version_ReturnsExpectedSemver`
- `TestCABI_ErrorReporting_*`

All new functions exercised; ownership / error paths tested; leak counter asserts no leaks per call.

### Swift tests (SwiftPM)

- `PresetsClientTests` — wraps C ABI calls; JSON decoding.
- `PipelinePresetMatcherTests` — given `UserSettings`, identifies matching preset or "Custom".
- `SessionsClientTests` — list/delete/clear round-trips against a tmpfs fixture.

UI rendering tests are out of scope (no SwiftUI snapshot infrastructure today).

### End-to-end (`vkb-cli`)

`core/cmd/vkb-cli/e2e_test.go`, gated behind `-tags=e2e`:
- `TestE2E_Pipe_WithPreset`
- `TestE2E_PresetsList_IncludesBundled`
- `TestE2E_Compare_ProducesNResults`
- `TestE2E_Sessions_ListShowDeleteClear`
- `TestE2E_README_Examples` — parses README's `vkb-cli` code blocks, runs each, fails if docs drift.

### Coverage targets

- New Go packages: 85%+ line coverage.
- C ABI: 100% of new functions exercised.
- Swift: cover codecs + matchers; UI rendering smoke-tested manually before each release.

## Documentation

### README updates (in Slice 5)

New section after **Building**:

```markdown
## Debugging the pipeline (vkb-cli)

`vkb-cli` is the headless equivalent of the Mac app — useful for CI, scripting,
and reproducing issues without launching the GUI. Same Go primitives, no SwiftUI.

### Quick reference

# List + inspect presets
vkb-cli presets list
vkb-cli presets show default

# Run dictation with a specific preset
vkb-cli pipe --preset minimal --live
vkb-cli pipe --preset default FILE.wav

# Inspect captured sessions
vkb-cli sessions list
vkb-cli sessions show <id>
vkb-cli sessions delete <id>

# A/B compare presets against the same captured audio
vkb-cli compare <session-id> --presets default,minimal,paranoid
```

Plus a line in `CONTRIBUTING.md`: *"For local pipeline experimentation, enable Developer Mode in Settings or use `vkb-cli` directly — see README §Debugging the pipeline."*

`TestE2E_README_Examples` parses these code blocks and runs each, so docs can't silently drift.

## Phasing / delivery

Five PR-sized slices, each shipping usable value:

### Slice 1 — Foundation (~800 LOC)

- `sessions` package + manifest schema (versioned)
- Always-on capture in `recorder` when Developer mode is set
- Developer mode toggle in General tab
- Pipeline tab scaffold (Inspector skeleton only)
- C ABI: `vkb_list_sessions`, `vkb_get_session`, `vkb_delete_session`, `vkb_clear_sessions`, `vkb_abi_version`

**Ships**: working Inspector reading captured sessions.

### Slice 2 — Presets (~600 LOC)

- `presets` package, bundled JSON, `Resolve` / `Match`
- User preset save/load/delete
- Editor view with preset picker (no drag-drop yet) — Save / Reset buttons
- C ABI: `vkb_list_presets`, `vkb_get_preset`, `vkb_save_preset`, `vkb_delete_preset`
- TSE threshold field (Go side) + per-stage detail panel UI

**Ships**: pick from preset dropdown, save user presets, tune TSE threshold.

### Slice 3 — Editable graph (~700 LOC)

- Drag-and-drop within lanes (SwiftUI `List` + `onMove`)
- Constraint validator (sample-rate compat)
- Cross-lane structural blocking
- Inline error overlay for invalid orderings

**Ships**: full Editor view as designed.

### Slice 4 — Compare (~500 LOC)

- `replay` package
- Compare view (UI)
- C ABI: `vkb_replay`

**Ships**: A/B comparison flow.

### Slice 5 — Polish + CLI parity (~400 LOC)

- Pipeline timeout (best-effort) — new field on `EngineConfig` + preset
- All `vkb-cli` subcommands (`presets`, `sessions`, `compare`)
- E2E test suite + README updates + CONTRIBUTING.md note

**Ships**: feature-complete + CLI parity + tested end-to-end.

### Total

~3000 LOC, ~6 weeks of focused work. Sequential delivery — each slice depends on the prior's data structures or UI scaffold, and ships value to existing Developer-mode contributors.
