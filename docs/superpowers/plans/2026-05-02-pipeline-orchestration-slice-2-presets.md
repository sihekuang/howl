# Pipeline Orchestration UI — Slice 2 (Presets) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `presets` Go package + UI Editor that lets the user pick from bundled presets ("default", "minimal", "aggressive", "paranoid"), save their own under `~/Library/Application Support/VoiceKeyboard/presets/`, and tune the per-stage TSE similarity threshold (with cosine similarity now actually computed and surfaced through events).

**Architecture:** Add a `presets` Go package (loader for embedded JSON + user-disk JSON, `Resolve` from `Preset` to `EngineConfig`, `Match` from `EngineConfig` back to a preset name). Extend `speaker.SpeakerGate` to load the speaker_encoder ONNX session at construction, compute the cosine similarity between extracted output and the reference embedding after each `Extract`, gate with zeros when below the configured threshold, and emit the similarity in a new pipeline event field. New C ABI exports (`vkb_list_presets`, `vkb_get_preset`, `vkb_save_preset`, `vkb_delete_preset`) follow the established JSON+`vkb_free_string` pattern. On the Swift side, mirror `SessionsClient` with a `PresetsClient`, add a segmented control to `PipelineTab` for Inspector/Editor switching, and ship an `EditorView` with a preset picker + Save/Reset/Save-as sheet + a per-stage detail panel exposing the TSE threshold slider and a recent-similarity readout pulled from session manifests.

**Tech Stack:** Go 1.22+ (existing core, embed for JSON), `cgo` for the C ABI, ONNX Runtime via `github.com/yalue/onnxruntime_go` (already in use), SwiftUI + SwiftPM for the Mac side. No new external dependencies.

---

## File Structure

### Go (new)

- `core/configs/pipeline-presets.json` — bundled preset definitions, embedded into the binary.
- `core/internal/presets/presets.go` — `Preset` / `StageSpec` / `Spec` types + `Load() ([]Preset, error)` (bundled+user merge).
- `core/internal/presets/builtin.go` — `//go:embed` of the bundled JSON.
- `core/internal/presets/resolve.go` — `Resolve(p Preset, secrets EngineSecrets) EngineConfig` and `Match(cfg EngineConfig, all []Preset) string`.
- `core/internal/presets/user.go` — `SaveUser(p Preset) error` / `LoadUser() ([]Preset, error)` / `DeleteUser(name string) error` + name validation.
- `core/internal/presets/presets_test.go` / `resolve_test.go` / `user_test.go` — coverage per file.

### Go (modified)

- `core/internal/speaker/speakerbeam.go` — add `Threshold float32`, optional `encoderPath string`, load encoder ONNX session at `NewSpeakerGate`, compute cosine similarity after each `Extract`, gate output to zeros below threshold. Expose latest similarity via `LastSimilarity() float32` for the pipeline to surface in the event.
- `core/internal/speaker/speakerbeam_test.go` — extend with threshold tests.
- `core/internal/pipeline/event.go` — add `TSESimilarity *float32` field to `Event`.
- `core/internal/pipeline/pipeline.go` — emit similarity in the `EventStageProcessed` event for the `tse` stage, walking the `(*SpeakerGate).LastSimilarity()` accessor.
- `core/cmd/libvkb/state.go` — **carryover**: remove the recorder construction from `buildPipeline`. Move it to a new helper called from `vkb_start_capture`. Hold the recorder on the engine so the capture goroutine can `Close()` it.
- `core/cmd/libvkb/exports.go` — **carryover**: in the capture goroutine defer, walk `pipe.FrameStages`/`ChunkStages` to build the manifest's stage list (no more hardcoded names). After manifest write, `Close()` the recorder so WAV `data_bytes` headers are patched. Plus four new presets exports.
- `core/internal/sessions/manifest.go` — package doc fix-up referencing flat `<stage>.wav` paths (drift noted in Slice 1 review).

### Swift (new)

- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/Preset.swift` — Codable `Preset`/`PresetSummary`/`StageSpec` types decoded from `vkb_*_preset` JSON.
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/PresetsClient.swift` — `PresetsClient` protocol + `LibVKBPresetsClient` impl wrapping the four C ABI calls.
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/PresetsClientTests.swift` — unit tests against `SpyCoreEngine`.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift` — preset picker + Save/Reset + per-stage detail panel.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/SaveAsPresetSheet.swift` — naming sheet for user presets.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/SessionPaths.swift` — small helper hoisting `/tmp/voicekeyboard/sessions/<id>/<rel>` URL construction.

### Swift (modified)

- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift` — add four new methods (`presetsListJSON`, `presetGetJSON`, `presetSaveJSON`, `presetDelete`).
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/LibvkbEngine.swift` — implement them via the new C ABI.
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CoreEngineTests.swift` — extend `SpyCoreEngine` with stubs.
- `mac/Packages/VoiceKeyboardCore/Sources/CVKB/include/libvkb_shim.h` — declare the four new C functions.
- `mac/Packages/VoiceKeyboardCore/Sources/CVKBStubs/cvkb_stubs.c` — stub the four new functions for SwiftPM test linkage.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift` — add a segmented control switching between `InspectorView` and `EditorView`.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/InspectorView.swift` — replace 3 hardcoded `/tmp/...` URLs with `SessionPaths` helper; surface `TSESimilarity` from session manifest in the TSE row.
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/SessionManifest.swift` — already has `tseSimilarity: Float?` so no schema change needed; just consumed from the new InspectorView TSE row.
- `docs/superpowers/specs/2026-05-02-pipeline-orchestration-ui-design.md` — one-line errata noting `SessionsClient` is async (the spec said sync; actor-based `LibvkbEngine` forced async).

---

## Phase A — Pre-Slice-2 hygiene (carryovers from Slice 1 PR)

### Task 1: Spec errata — note SessionsClient is async

**Files:**
- Modify: `docs/superpowers/specs/2026-05-02-pipeline-orchestration-ui-design.md`

- [ ] **Step 1: Locate the SessionsClient code block**

Run: `grep -n "func list() throws -> \[SessionManifest\]\|protocol SessionsClient" docs/superpowers/specs/2026-05-02-pipeline-orchestration-ui-design.md`
Expected: shows the `protocol SessionsClient` block, around line 250-260.

- [ ] **Step 2: Update the protocol signatures to async**

Edit the spec. Find:

```swift
public protocol SessionsClient: Sendable {
    func list() throws -> [SessionManifest]
    func get(_ id: String) throws -> SessionManifest
    func delete(_ id: String) throws
    func clear() throws
}
```

Replace with:

```swift
public protocol SessionsClient: Sendable {
    func list() async throws -> [SessionManifest]
    func get(_ id: String) async throws -> SessionManifest
    func delete(_ id: String) async throws
    func clear() async throws
}
```

Add a one-line note immediately after the block:

```markdown
> Note: methods are `async` because `LibvkbEngine` is an `actor` — the cgo
> bridge can't be called synchronously from outside the actor. The
> earlier sync draft of the spec was a mistake.
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-05-02-pipeline-orchestration-ui-design.md
git commit -m "docs(spec): SessionsClient is async (errata)"
```

---

### Task 2: Hoist /tmp/voicekeyboard/sessions path into a Mac helper

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/SessionPaths.swift`
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/InspectorView.swift`

- [ ] **Step 1: Create the helper**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/SessionPaths.swift
import Foundation

/// Resolves on-disk paths for captured pipeline sessions. Single source
/// of truth for the directory layout the libvkb capture goroutine writes
/// to; UI code should never construct these paths inline.
///
/// Today the base is hardcoded `/tmp/voicekeyboard/sessions/`. If this
/// ever becomes user-configurable, swap the base for a dependency
/// without touching call sites.
enum SessionPaths {
    static let base: URL = URL(fileURLWithPath: "/tmp/voicekeyboard/sessions")

    /// Absolute folder path for a session id.
    static func dir(for id: String) -> URL {
        base.appendingPathComponent(id)
    }

    /// Absolute path for a file inside a session folder
    /// (e.g. `denoise.wav`, `transcripts/raw.txt`).
    static func file(in id: String, rel: String) -> URL {
        dir(for: id).appendingPathComponent(rel)
    }
}
```

- [ ] **Step 2: Replace the three hardcoded sites in InspectorView**

In `mac/VoiceKeyboard/UI/Settings/Pipeline/InspectorView.swift`, find and replace:

Old (around the `sessionURL` private function, ~line 134):

```swift
private func sessionURL(_ id: String, _ rel: String) -> URL {
    URL(fileURLWithPath: "/tmp/voicekeyboard/sessions/\(id)/\(rel)")
}

private func openInPlayer(sessionID: String, relPath: String) {
    let url = sessionURL(sessionID, relPath)
    #if canImport(AppKit)
    NSWorkspace.shared.open(url)
    #endif
}

private func revealInFinder(_ s: SessionManifest) {
    let url = URL(fileURLWithPath: "/tmp/voicekeyboard/sessions/\(s.id)")
    #if canImport(AppKit)
    NSWorkspace.shared.activateFileViewerSelecting([url])
    #endif
}
```

New:

```swift
private func openInPlayer(sessionID: String, relPath: String) {
    let url = SessionPaths.file(in: sessionID, rel: relPath)
    #if canImport(AppKit)
    NSWorkspace.shared.open(url)
    #endif
}

private func revealInFinder(_ s: SessionManifest) {
    let url = SessionPaths.dir(for: s.id)
    #if canImport(AppKit)
    NSWorkspace.shared.activateFileViewerSelecting([url])
    #endif
}
```

(`sessionURL` private helper deleted entirely — `SessionPaths.file` replaces it.)

- [ ] **Step 3: Build to verify**

Run: `cd mac && make build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/SessionPaths.swift \
        mac/VoiceKeyboard/UI/Settings/Pipeline/InspectorView.swift
git commit -m "refactor(mac): hoist session path construction into SessionPaths helper"
```

---

### Task 3: Manifest stage list from pipeline walk (replaces hardcoded list)

**Files:**
- Modify: `core/cmd/libvkb/exports.go` (the capture goroutine defer in `vkb_start_capture`)

The current defer hardcodes `[denoise, decimate3, tse?]` for the manifest. After Slice 2's preset work lands a non-default preset, this would lie. Walk `pipe.FrameStages`/`ChunkStages` instead — same source of truth `pipeline.registerRecorderStages` uses.

- [ ] **Step 1: Read the current manifest construction**

Run: `grep -n "Stages: \[\]sessions.StageEntry\|TSEEnabled" core/cmd/libvkb/exports.go`
Expected: shows the manifest construction inside the capture goroutine defer (around line 220-235).

- [ ] **Step 2: Replace hardcoded list with a pipe walk**

In `core/cmd/libvkb/exports.go`, find the manifest-building block in `vkb_start_capture`'s capture-goroutine defer. The existing code looks like:

```go
m := sessions.Manifest{
    Version:     sessions.CurrentManifestVersion,
    ID:          sessionID,
    Preset:      "default",
    DurationSec: 0,
    Stages: []sessions.StageEntry{
        {Name: "denoise", Kind: "frame", WavRel: "denoise.wav", RateHz: 48000},
        {Name: "decimate3", Kind: "frame", WavRel: "decimate3.wav", RateHz: 16000},
    },
    Transcripts: sessions.TranscriptEntries{Raw: "raw.txt", Dict: "dict.txt", Cleaned: "cleaned.txt"},
}
if tseEnabled {
    m.Stages = append(m.Stages, sessions.StageEntry{
        Name: "tse", Kind: "chunk", WavRel: "tse.wav", RateHz: 16000,
    })
}
```

Replace with a walk over the captured `pipe`:

```go
// Build the stage list from the captured pipeline so a non-default
// preset (Slice 2) doesn't lie about which stages actually ran.
// Mirrors pipeline.registerRecorderStages's rate-tracking logic.
const inputRate = 48000
stages := make([]sessions.StageEntry, 0, len(pipe.FrameStages)+len(pipe.ChunkStages))
rate := inputRate
for _, st := range pipe.FrameStages {
    r := rate
    if out := st.OutputRate(); out != 0 {
        r = out
    }
    stages = append(stages, sessions.StageEntry{
        Name:   st.Name(),
        Kind:   "frame",
        WavRel: st.Name() + ".wav",
        RateHz: r,
    })
    if out := st.OutputRate(); out != 0 {
        rate = out
    }
}
for _, st := range pipe.ChunkStages {
    r := rate
    if out := st.OutputRate(); out != 0 {
        r = out
    }
    stages = append(stages, sessions.StageEntry{
        Name:   st.Name(),
        Kind:   "chunk",
        WavRel: st.Name() + ".wav",
        RateHz: r,
    })
    if out := st.OutputRate(); out != 0 {
        rate = out
    }
}

m := sessions.Manifest{
    Version:     sessions.CurrentManifestVersion,
    ID:          sessionID,
    Preset:      "default", // populated correctly once Slice 2 lands the presets package
    DurationSec: 0,
    Stages:      stages,
    Transcripts: sessions.TranscriptEntries{Raw: "raw.txt", Dict: "dict.txt", Cleaned: "cleaned.txt"},
}
```

The conditional `if tseEnabled { ... }` block disappears — TSE is in `pipe.ChunkStages` iff the engine was configured with TSE enabled, and the walk includes it automatically. Also delete the `tseEnabled := e.cfg.TSEEnabled` line that was reading config purely for this branch.

- [ ] **Step 3: Build + run libvkb tests**

Run: `cd core && make build-dylib && go test -tags=whispercpp ./cmd/libvkb/... -v`
Expected: PASS — `make build-dylib` clean, all libvkb tests still pass (the manifest write isn't unit-tested directly; the existing tests exercise other paths).

- [ ] **Step 4: Commit**

```bash
git add core/cmd/libvkb/exports.go
git commit -m "refactor(libvkb): build manifest stage list from pipe walk, not hardcoded names"
```

---

### Task 4: Move recorder construction per-dictation, not per-configure

**Files:**
- Modify: `core/cmd/libvkb/state.go` (remove from `buildPipeline`)
- Modify: `core/cmd/libvkb/exports.go` (add to `vkb_start_capture` before goroutine launch)
- Test: `core/cmd/libvkb/sessions_export_test.go` (add a regression test)

This is the architectural fix from Slice 1's Known Follow-up #1: each dictation must produce its own session folder, not append to a shared one across captures.

- [ ] **Step 1: Add a regression test that two dictations produce two session folders**

The existing `sessions_export_test.go` tests don't exercise `vkb_start_capture` (the engine isn't fully initialized in those unit tests). Instead, add a smaller regression test that directly exercises the new `openSessionRecorder` helper that this task introduces.

Append to `core/cmd/libvkb/sessions_export_test.go`:

```go
func TestOpenSessionRecorder_TwoCallsProduceTwoFolders(t *testing.T) {
	dir := withTempSessionsStore(t)
	getEngine().cfg.DeveloperMode = true
	t.Cleanup(func() {
		// Don't leave the cfg in DeveloperMode for the next test.
		getEngine().cfg.DeveloperMode = false
		// Nil out any active session metadata.
		getEngine().activeSessionID = ""
		getEngine().activeSessionDir = ""
		getEngine().activeRecorder = nil
	})

	// Two calls in sequence must produce two distinct session folders.
	if err := openSessionRecorder(getEngine()); err != nil {
		t.Fatalf("first openSessionRecorder: %v", err)
	}
	id1 := getEngine().activeSessionID
	getEngine().activeSessionID = ""
	getEngine().activeSessionDir = ""
	getEngine().activeRecorder = nil

	// Sleep 1 ms to ensure RFC3339-nanos timestamps differ.
	time.Sleep(time.Millisecond)

	if err := openSessionRecorder(getEngine()); err != nil {
		t.Fatalf("second openSessionRecorder: %v", err)
	}
	id2 := getEngine().activeSessionID

	if id1 == "" || id2 == "" {
		t.Fatalf("session IDs not set: id1=%q id2=%q", id1, id2)
	}
	if id1 == id2 {
		t.Errorf("two calls produced the same id %q", id1)
	}
	for _, id := range []string{id1, id2} {
		if _, err := os.Stat(filepath.Join(dir, id)); err != nil {
			t.Errorf("session folder %q missing: %v", id, err)
		}
	}
}
```

Add `"time"` to the imports if not already there.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd core && go test -tags=whispercpp ./cmd/libvkb/... -run TestOpenSessionRecorder -v`
Expected: FAIL with "undefined: openSessionRecorder" — the helper doesn't exist yet.

- [ ] **Step 3: Add `engine.activeRecorder` field**

In `core/cmd/libvkb/state.go`, find the `engine` struct and add a field next to `activeSessionID`:

```go
type engine struct {
    // ... existing fields ...
    sessions         *sessions.Store
    activeSessionID  string
    activeSessionDir string
    // activeRecorder is the recorder.Session for the currently in-flight
    // capture. nil between captures. Set by openSessionRecorder (called
    // from vkb_start_capture); the capture goroutine's defer Closes it
    // and nils it out after the manifest write.
    activeRecorder *recorder.Session
}
```

- [ ] **Step 4: Remove the recorder block from `buildPipeline`**

In `core/cmd/libvkb/state.go`, find the `if e.cfg.DeveloperMode && e.sessions != nil { ... }` block at the end of `buildPipeline` and **delete the entire block**. `buildPipeline` no longer touches the recorder; `pipe.Recorder` stays nil after `pipeline.New`.

Also delete the imports that become unused if no longer referenced (`time`, `recorder` may still be needed by exports.go but check).

Also delete the `e.activeSessionID = ""; e.activeSessionDir = ""` lines at the top of `buildPipeline` (they were defensive because buildPipeline used to write to those fields; now it doesn't).

- [ ] **Step 5: Add `openSessionRecorder` helper to exports.go**

In `core/cmd/libvkb/exports.go`, add a new helper near the top of the file (after the imports):

```go
// openSessionRecorder constructs a recorder.Session for the next
// capture cycle when DeveloperMode is on. Called from vkb_start_capture
// before the capture goroutine is launched, so the engine is single-
// threaded at this point and lock-free access to e.cfg / e.sessions is
// fine. The capture goroutine's defer reads the recorder via
// e.activeRecorder, writes the manifest, then closes + nils it.
//
// All errors are non-fatal — capture proceeds without recording if the
// session can't be opened. Returns the error only so tests can assert
// on it; callers should log and continue.
func openSessionRecorder(e *engine) error {
    if !e.cfg.DeveloperMode || e.sessions == nil {
        return nil
    }
    if err := e.sessions.Prune(10); err != nil {
        log.Printf("[vkb] openSessionRecorder: prune failed (continuing): %v", err)
    }
    id := time.Now().UTC().Format("2006-01-02T15:04:05.000000000Z")
    dir := e.sessions.SessionDir(id)
    rec, err := recorder.Open(recorder.Options{
        Dir:         dir,
        AudioStages: true,
        Transcripts: true,
    })
    if err != nil {
        log.Printf("[vkb] openSessionRecorder: recorder.Open failed (continuing without capture): %v", err)
        return err
    }
    e.activeSessionID = id
    e.activeSessionDir = dir
    e.activeRecorder = rec
    return nil
}
```

Add `"time"` and `"github.com/voice-keyboard/core/internal/recorder"` to the imports if not already there.

- [ ] **Step 6: Wire `openSessionRecorder` into `vkb_start_capture`**

In `vkb_start_capture`, find the place where `pipe := e.pipeline` is captured (right before the goroutine launch). Just before assigning `e.pushCh = pushCh`, add:

```go
// Open a per-capture session recorder under DeveloperMode. Errors are
// non-fatal; we proceed without recording in that case.
_ = openSessionRecorder(e)
if e.activeRecorder != nil {
    pipe.Recorder = e.activeRecorder
}
```

- [ ] **Step 7: Run the regression test**

Run: `cd core && go test -tags=whispercpp ./cmd/libvkb/... -run TestOpenSessionRecorder -v`
Expected: PASS.

Also run the full libvkb suite to confirm no regression:

Run: `cd core && go test -tags=whispercpp ./cmd/libvkb/... -v`
Expected: PASS — all tests, no SKIPs flipping unexpectedly.

- [ ] **Step 8: Build the dylib**

Run: `cd core && make build-dylib`
Expected: clean build.

- [ ] **Step 9: Commit**

```bash
git add core/cmd/libvkb/state.go core/cmd/libvkb/exports.go core/cmd/libvkb/sessions_export_test.go
git commit -m "refactor(libvkb): per-dictation recorder via openSessionRecorder, not per-configure"
```

---

### Task 5: Recorder.Close() after each capture (WAV header patching)

**Files:**
- Modify: `core/cmd/libvkb/exports.go` (capture goroutine defer)

WAV writers patch the `data_bytes` header field on `Close()`. Without it, downstream players see a header that says "0 bytes of audio" even though the file has plenty. Some players cope, some don't. Fix by closing the recorder in the capture goroutine's defer, after the manifest write.

- [ ] **Step 1: Read the current defer's manifest-write block**

Run: `grep -n "writes session.json\|m.Write(sessionDir)\|capture goroutine: exited" core/cmd/libvkb/exports.go`
Expected: shows the lines in the capture goroutine defer where the manifest is written and the "exited" log fires.

- [ ] **Step 2: Snapshot + close the recorder in the defer**

In `core/cmd/libvkb/exports.go`, the defer currently snapshots `sessionID` / `sessionDir` under `e.mu.Lock()`. Extend that snapshot to also pull and clear `activeRecorder`:

```go
e.mu.Lock()
sessionID := e.activeSessionID
sessionDir := e.activeSessionDir
rec := e.activeRecorder
e.activeSessionID = ""
e.activeSessionDir = ""
e.activeRecorder = nil
e.pushCh = nil
e.cancel = nil
drops := e.dropCount
pushes := e.pushCount
e.dropCount = 0
e.pushCount = 0
tseEnabled := e.cfg.TSEEnabled  // (kept; used elsewhere if applicable)
e.mu.Unlock()
```

Then, **after** `m.Write(sessionDir)` (success or failure), add:

```go
if rec != nil {
    if err := rec.Close(); err != nil {
        log.Printf("[vkb] capture goroutine: recorder.Close failed: %v", err)
    }
}
```

Place this immediately before the existing `log.Printf("[vkb] capture goroutine: exited (...)`.

- [ ] **Step 3: Build + test**

Run: `cd core && make build-dylib && go test -tags=whispercpp ./cmd/libvkb/... -v`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add core/cmd/libvkb/exports.go
git commit -m "fix(libvkb): close recorder after each capture so WAV headers are patched"
```

---

## Phase B — Slice 2 Presets (Go side)

### Task 6: presets package — schema types + bundled JSON + Load

**Files:**
- Create: `core/configs/pipeline-presets.json`
- Create: `core/internal/presets/presets.go`
- Create: `core/internal/presets/builtin.go`
- Create: `core/internal/presets/presets_test.go`

- [ ] **Step 1: Write the bundled JSON**

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
      "llm":        {"provider": "anthropic"}
    },
    {
      "name": "minimal",
      "description": "No denoise, no TSE — fastest, lowest quality. Useful baseline.",
      "frame_stages": [
        {"name": "denoise",   "enabled": false},
        {"name": "decimate3", "enabled": true}
      ],
      "chunk_stages": [
        {"name": "tse", "enabled": false, "backend": "ecapa", "threshold": 0.0}
      ],
      "transcribe": {"model_size": "small"},
      "llm":        {"provider": "anthropic"}
    },
    {
      "name": "aggressive",
      "description": "Denoise + TSE + larger Whisper. Higher quality, more latency.",
      "frame_stages": [
        {"name": "denoise",   "enabled": true},
        {"name": "decimate3", "enabled": true}
      ],
      "chunk_stages": [
        {"name": "tse", "enabled": true, "backend": "ecapa", "threshold": 0.0}
      ],
      "transcribe": {"model_size": "base"},
      "llm":        {"provider": "anthropic"}
    },
    {
      "name": "paranoid",
      "description": "Default + TSE threshold 0.7 (silences low-confidence chunks; resists hallucinations in noisy rooms).",
      "frame_stages": [
        {"name": "denoise",   "enabled": true},
        {"name": "decimate3", "enabled": true}
      ],
      "chunk_stages": [
        {"name": "tse", "enabled": true, "backend": "ecapa", "threshold": 0.7}
      ],
      "transcribe": {"model_size": "small"},
      "llm":        {"provider": "anthropic"}
    }
  ]
}
```

Save to `core/configs/pipeline-presets.json`.

- [ ] **Step 2: Write the failing tests**

```go
// core/internal/presets/presets_test.go
package presets

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestLoad_BundledFileParses(t *testing.T) {
	got, err := loadBundled()
	if err != nil {
		t.Fatalf("loadBundled: %v", err)
	}
	if len(got) < 4 {
		t.Errorf("expected at least 4 bundled presets, got %d", len(got))
	}
	wantNames := map[string]bool{"default": false, "minimal": false, "aggressive": false, "paranoid": false}
	for _, p := range got {
		if _, ok := wantNames[p.Name]; ok {
			wantNames[p.Name] = true
		}
	}
	for n, found := range wantNames {
		if !found {
			t.Errorf("bundled preset %q missing", n)
		}
	}
}

func TestLoad_RejectsUnknownVersion(t *testing.T) {
	body := `{"version": 99, "presets": []}`
	_, err := parseBundle([]byte(body))
	if err == nil {
		t.Fatal("expected version-mismatch error")
	}
	if !strings.Contains(err.Error(), "version") {
		t.Errorf("error %q should mention 'version'", err)
	}
}

func TestLoad_RejectsMalformedJSON(t *testing.T) {
	_, err := parseBundle([]byte("{not json"))
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestPreset_DefaultPresetTSEThresholdIsZero(t *testing.T) {
	all, _ := loadBundled()
	for _, p := range all {
		if p.Name != "default" {
			continue
		}
		for _, s := range p.ChunkStages {
			if s.Name == "tse" {
				if s.Threshold == nil || *s.Threshold != 0.0 {
					t.Errorf("default preset's tse threshold = %v, want 0.0", s.Threshold)
				}
				return
			}
		}
		t.Error("default preset has no tse chunk stage")
	}
	t.Error("default preset missing")
}

func TestPreset_ParanoidPresetTSEThresholdIs07(t *testing.T) {
	all, _ := loadBundled()
	for _, p := range all {
		if p.Name == "paranoid" {
			for _, s := range p.ChunkStages {
				if s.Name == "tse" && s.Threshold != nil && *s.Threshold == 0.7 {
					return
				}
			}
			t.Error("paranoid preset's tse threshold is not 0.7")
			return
		}
	}
	t.Error("paranoid preset missing")
}

func TestPreset_JSONRoundTrip(t *testing.T) {
	thr := float32(0.5)
	in := Preset{
		Name: "test", Description: "x",
		FrameStages: []StageSpec{{Name: "denoise", Enabled: true}},
		ChunkStages: []StageSpec{{Name: "tse", Enabled: true, Backend: "ecapa", Threshold: &thr}},
		Transcribe:  TranscribeSpec{ModelSize: "small"},
		LLM:         LLMSpec{Provider: "anthropic"},
	}
	buf, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	var out Preset
	if err := json.Unmarshal(buf, &out); err != nil {
		t.Fatal(err)
	}
	if out.Name != "test" || len(out.ChunkStages) != 1 ||
		out.ChunkStages[0].Threshold == nil || *out.ChunkStages[0].Threshold != 0.5 {
		t.Errorf("round-trip mismatch: %+v", out)
	}
}
```

- [ ] **Step 3: Verify failure**

Run: `cd core && go test ./internal/presets/... -v`
Expected: FAIL with "package presets does not exist".

- [ ] **Step 4: Implement the schema + loader**

```go
// core/internal/presets/presets.go

// Package presets manages bundled and user-defined pipeline presets.
//
// Bundled presets live in core/configs/pipeline-presets.json (embedded
// at build time). User presets live in
//   ~/Library/Application Support/VoiceKeyboard/presets/<name>.json
// (one file per preset).
//
// The schema is versioned at birth (CurrentVersion). Add new optional
// fields without bumping; structural changes bump.
package presets

import (
	"encoding/json"
	"fmt"
)

// CurrentVersion is the major version this build understands. The
// bundle loader rejects anything else; the user preset loader is more
// forgiving (skips unparseable files with a log).
const CurrentVersion = 1

// Bundle is the wire shape of pipeline-presets.json.
type Bundle struct {
	Version int      `json:"version"`
	Presets []Preset `json:"presets"`
}

// Preset is one named pipeline configuration.
type Preset struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	FrameStages []StageSpec    `json:"frame_stages"`
	ChunkStages []StageSpec    `json:"chunk_stages"`
	Transcribe  TranscribeSpec `json:"transcribe"`
	LLM         LLMSpec        `json:"llm"`
}

// StageSpec is a per-stage entry inside a preset. Threshold is a
// pointer so 0.0 (legitimately disable gating) is distinguishable from
// "not set in JSON" (also nil after decode of an absent key).
type StageSpec struct {
	Name      string   `json:"name"`
	Enabled   bool     `json:"enabled"`
	Backend   string   `json:"backend,omitempty"`
	Threshold *float32 `json:"threshold,omitempty"`
}

// TranscribeSpec mirrors the transcribe-related fields of EngineConfig.
type TranscribeSpec struct {
	ModelSize string `json:"model_size"`
}

// LLMSpec mirrors the LLM-related fields of EngineConfig.
type LLMSpec struct {
	Provider string `json:"provider"`
}

// parseBundle parses a pipeline-presets.json blob and returns its
// Presets slice. Rejects unknown major versions.
func parseBundle(buf []byte) ([]Preset, error) {
	var b Bundle
	if err := json.Unmarshal(buf, &b); err != nil {
		return nil, fmt.Errorf("presets: parse bundle: %w", err)
	}
	if b.Version != CurrentVersion {
		return nil, fmt.Errorf("presets: unsupported bundle version %d (this build supports %d)", b.Version, CurrentVersion)
	}
	return b.Presets, nil
}

// loadBundled parses the //go:embed bundle.
func loadBundled() ([]Preset, error) {
	return parseBundle(builtinJSON)
}
```

```go
// core/internal/presets/builtin.go
package presets

import _ "embed"

//go:embed pipeline-presets.json
var builtinJSON []byte
```

Symlink the JSON into the package so `//go:embed` finds it:

Run from project root: `ln -s ../../configs/pipeline-presets.json core/internal/presets/pipeline-presets.json`

(Alternative: copy the file. Symlink keeps `core/configs/` as the canonical location while satisfying `embed`'s "file must be in the package directory" requirement.)

- [ ] **Step 5: Run tests**

Run: `cd core && go test ./internal/presets/... -v`
Expected: PASS — 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add core/configs/pipeline-presets.json \
        core/internal/presets/presets.go \
        core/internal/presets/builtin.go \
        core/internal/presets/pipeline-presets.json \
        core/internal/presets/presets_test.go
git commit -m "feat(presets): bundled JSON + Load with version validation (v1)"
```

---

### Task 7: presets — Resolve (Preset → EngineConfig)

**Files:**
- Create: `core/internal/presets/resolve.go`
- Create: `core/internal/presets/resolve_test.go`

`Resolve` translates a `Preset` into an `EngineConfig` the libvkb engine can consume. Fields the preset doesn't specify get sensible defaults from `WithDefaults`. Secrets (LLM API key) come from the caller, not the preset.

- [ ] **Step 1: Write the failing tests**

```go
// core/internal/presets/resolve_test.go
package presets

import (
	"testing"

	"github.com/voice-keyboard/core/internal/config"
)

func TestResolve_DefaultPresetMatchesEngineConfig(t *testing.T) {
	all, _ := loadBundled()
	def := findPreset(t, all, "default")

	got := Resolve(def, EngineSecrets{LLMAPIKey: "test-key"})

	// Critical fields the default preset specifies:
	if got.WhisperModelSize != "small" {
		t.Errorf("WhisperModelSize = %q, want small", got.WhisperModelSize)
	}
	if got.LLMProvider != "anthropic" {
		t.Errorf("LLMProvider = %q, want anthropic", got.LLMProvider)
	}
	if got.LLMAPIKey != "test-key" {
		t.Errorf("LLMAPIKey = %q, want test-key", got.LLMAPIKey)
	}
	if got.DisableNoiseSuppression {
		t.Errorf("default should have noise suppression on")
	}
	if !got.TSEEnabled {
		t.Errorf("default should have TSE on")
	}
}

func TestResolve_MinimalDisablesDenoiseAndTSE(t *testing.T) {
	all, _ := loadBundled()
	min := findPreset(t, all, "minimal")
	got := Resolve(min, EngineSecrets{})

	if !got.DisableNoiseSuppression {
		t.Errorf("minimal: DisableNoiseSuppression should be true")
	}
	if got.TSEEnabled {
		t.Errorf("minimal: TSEEnabled should be false")
	}
}

func TestResolve_ParanoidPropagatesThresholdInTSEBackend(t *testing.T) {
	all, _ := loadBundled()
	p := findPreset(t, all, "paranoid")
	got := Resolve(p, EngineSecrets{})

	if got.TSEThreshold == nil || *got.TSEThreshold != 0.7 {
		t.Errorf("TSEThreshold = %v, want 0.7", got.TSEThreshold)
	}
}

func TestResolve_BackendSelected(t *testing.T) {
	all, _ := loadBundled()
	def := findPreset(t, all, "default")
	got := Resolve(def, EngineSecrets{})
	if got.TSEBackend != "ecapa" {
		t.Errorf("TSEBackend = %q, want ecapa", got.TSEBackend)
	}
}

func findPreset(t *testing.T, all []Preset, name string) Preset {
	t.Helper()
	for _, p := range all {
		if p.Name == name {
			return p
		}
	}
	t.Fatalf("preset %q not found in bundled set", name)
	return Preset{}
}

// Compile-time check: Resolve produces a config.Config.
var _ = config.Config{}
```

- [ ] **Step 2: Run to verify failures**

Run: `cd core && go test ./internal/presets/... -run TestResolve -v`
Expected: FAIL with "undefined: Resolve" or "undefined: EngineSecrets".

- [ ] **Step 3: Add `TSEThreshold` field to `config.Config`**

In `core/internal/config/config.go`, add a new field:

```go
type Config struct {
    // ... existing fields ...

    // TSEThreshold is the cosine-similarity threshold below which the
    // SpeakerGate gates its output to zeros (silences a chunk that
    // doesn't sound enough like the enrolled speaker). nil or 0.0
    // disables the gate entirely (current default behavior).
    TSEThreshold *float32 `json:"tse_threshold,omitempty"`
}
```

- [ ] **Step 4: Implement Resolve**

```go
// core/internal/presets/resolve.go
package presets

import (
	"github.com/voice-keyboard/core/internal/config"
)

// EngineSecrets carries values that don't live in preset JSON because
// they're per-installation (API keys) or per-machine (model paths).
// The Resolve caller fills these in from settings storage.
type EngineSecrets struct {
	LLMAPIKey           string
	WhisperModelPath    string
	DeepFilterModelPath string
	TSEProfileDir       string
	TSEModelPath        string
	SpeakerEncoderPath  string
	ONNXLibPath         string
	CustomDict          []string
	Language            string
	LLMBaseURL          string
	LLMModel            string
}

// Resolve produces a config.Config equivalent to running this preset.
// secrets supplies fields the preset doesn't (and shouldn't) specify.
//
// The resulting Config is bit-equivalent to what the user would have
// produced by clicking through Settings to assemble the same options.
// Both this Config and one written by the existing settings UI should
// pass `Match(cfg, []Preset{p})` if they describe the same preset.
func Resolve(p Preset, secrets EngineSecrets) config.Config {
	cfg := config.Config{
		WhisperModelPath:    secrets.WhisperModelPath,
		WhisperModelSize:    p.Transcribe.ModelSize,
		Language:            secrets.Language,
		DeepFilterModelPath: secrets.DeepFilterModelPath,
		LLMProvider:         p.LLM.Provider,
		LLMModel:            secrets.LLMModel,
		LLMAPIKey:           secrets.LLMAPIKey,
		LLMBaseURL:          secrets.LLMBaseURL,
		CustomDict:          secrets.CustomDict,
		DeveloperMode:       true, // presets only apply when dev mode is on
		TSEProfileDir:       secrets.TSEProfileDir,
		TSEModelPath:        secrets.TSEModelPath,
		SpeakerEncoderPath:  secrets.SpeakerEncoderPath,
		ONNXLibPath:         secrets.ONNXLibPath,
	}
	// Frame stages: walk the preset's list and translate per-name
	// (denoise → DisableNoiseSuppression, decimate3 → no toggle today).
	for _, st := range p.FrameStages {
		switch st.Name {
		case "denoise":
			cfg.DisableNoiseSuppression = !st.Enabled
		case "decimate3":
			// No corresponding Config field today (always on);
			// preset author can disable for documentation but the
			// engine still inserts decimate3.
		}
	}
	// Chunk stages: only TSE today.
	for _, st := range p.ChunkStages {
		if st.Name != "tse" {
			continue
		}
		cfg.TSEEnabled = st.Enabled
		cfg.TSEBackend = st.Backend
		if st.Threshold != nil {
			t := *st.Threshold
			cfg.TSEThreshold = &t
		}
	}
	return cfg
}
```

- [ ] **Step 5: Run tests**

Run: `cd core && go test ./internal/presets/... ./internal/config/... -v`
Expected: PASS — including all Resolve tests + existing config tests.

- [ ] **Step 6: Commit**

```bash
git add core/internal/presets/resolve.go core/internal/presets/resolve_test.go core/internal/config/config.go
git commit -m "feat(presets): Resolve preset to EngineConfig + TSEThreshold field"
```

---

### Task 8: presets — Match (EngineConfig → preset name or "custom")

**Files:**
- Modify: `core/internal/presets/resolve.go` (append `Match`)
- Modify: `core/internal/presets/resolve_test.go` (append tests)

- [ ] **Step 1: Append failing tests**

```go
// Append to core/internal/presets/resolve_test.go:

func TestMatch_AllBundledPresetsAreSelfMatching(t *testing.T) {
	all, _ := loadBundled()
	for _, p := range all {
		cfg := Resolve(p, EngineSecrets{})
		got := Match(cfg, all)
		if got != p.Name {
			t.Errorf("Match(Resolve(%q)) = %q, want %q", p.Name, got, p.Name)
		}
	}
}

func TestMatch_DivergedConfigReturnsCustom(t *testing.T) {
	all, _ := loadBundled()
	def := findPreset(t, all, "default")
	cfg := Resolve(def, EngineSecrets{})
	cfg.DisableNoiseSuppression = !cfg.DisableNoiseSuppression  // diverge

	if got := Match(cfg, all); got != "custom" {
		t.Errorf("Match(divergent) = %q, want \"custom\"", got)
	}
}

func TestMatch_EmptyPresetListReturnsCustom(t *testing.T) {
	if got := Match(config.Config{}, nil); got != "custom" {
		t.Errorf("Match(empty list) = %q, want \"custom\"", got)
	}
}
```

- [ ] **Step 2: Append `Match` to resolve.go**

```go
// Match returns the name of the preset whose Resolve(...) would produce
// `cfg`'s preset-relevant fields, or "custom" if no preset matches.
//
// Preset-relevant fields: those Resolve actually sets from the preset
// (TSEEnabled, TSEBackend, TSEThreshold, DisableNoiseSuppression,
// LLMProvider, WhisperModelSize). Fields populated only from secrets
// (LLMAPIKey, WhisperModelPath, etc.) are intentionally ignored —
// changing your API key doesn't make your config "custom."
func Match(cfg config.Config, all []Preset) string {
	for _, p := range all {
		if presetMatchesConfig(p, cfg) {
			return p.Name
		}
	}
	return "custom"
}

func presetMatchesConfig(p Preset, cfg config.Config) bool {
	if cfg.LLMProvider != p.LLM.Provider {
		return false
	}
	if cfg.WhisperModelSize != p.Transcribe.ModelSize {
		return false
	}
	for _, st := range p.FrameStages {
		switch st.Name {
		case "denoise":
			wantOff := !st.Enabled
			if cfg.DisableNoiseSuppression != wantOff {
				return false
			}
		}
	}
	for _, st := range p.ChunkStages {
		if st.Name != "tse" {
			continue
		}
		if cfg.TSEEnabled != st.Enabled {
			return false
		}
		if cfg.TSEEnabled {
			if cfg.TSEBackend != st.Backend {
				return false
			}
			// Threshold compare: nil-or-0 are treated as equivalent
			// ("no gating"); explicit non-zero must match.
			cfgThr := float32(0)
			if cfg.TSEThreshold != nil {
				cfgThr = *cfg.TSEThreshold
			}
			presetThr := float32(0)
			if st.Threshold != nil {
				presetThr = *st.Threshold
			}
			if cfgThr != presetThr {
				return false
			}
		}
	}
	return true
}
```

- [ ] **Step 3: Run tests**

Run: `cd core && go test ./internal/presets/... -v`
Expected: PASS — all preset tests including new Match tests.

- [ ] **Step 4: Commit**

```bash
git add core/internal/presets/resolve.go core/internal/presets/resolve_test.go
git commit -m "feat(presets): Match resolves cfg back to preset name (or \"custom\")"
```

---

### Task 9: presets — user save / load / delete on disk

**Files:**
- Create: `core/internal/presets/user.go`
- Create: `core/internal/presets/user_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// core/internal/presets/user_test.go
package presets

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestSaveUser_RoundTrips(t *testing.T) {
	dir := t.TempDir()
	thr := float32(0.4)
	in := Preset{
		Name: "my-quiet-room", Description: "office",
		ChunkStages: []StageSpec{{Name: "tse", Enabled: true, Backend: "ecapa", Threshold: &thr}},
		Transcribe:  TranscribeSpec{ModelSize: "small"},
		LLM:         LLMSpec{Provider: "anthropic"},
	}
	if err := SaveUserAt(dir, in); err != nil {
		t.Fatalf("SaveUserAt: %v", err)
	}
	got, err := LoadUserAt(dir)
	if err != nil {
		t.Fatalf("LoadUserAt: %v", err)
	}
	if len(got) != 1 || got[0].Name != "my-quiet-room" {
		t.Errorf("got %+v", got)
	}
}

func TestSaveUser_RejectsBundledNameCollision(t *testing.T) {
	dir := t.TempDir()
	for _, bad := range []string{"default", "minimal", "aggressive", "paranoid"} {
		err := SaveUserAt(dir, Preset{Name: bad})
		if !errors.Is(err, ErrReservedName) {
			t.Errorf("SaveUserAt(%q) error = %v, want ErrReservedName", bad, err)
		}
	}
}

func TestSaveUser_RejectsInvalidName(t *testing.T) {
	dir := t.TempDir()
	for _, bad := range []string{
		"", "UPPERCASE", "has space", "../escape", "foo/bar",
		"way-too-long-name-that-exceeds-forty-characters-easily",
	} {
		if err := SaveUserAt(dir, Preset{Name: bad}); !errors.Is(err, ErrInvalidName) {
			t.Errorf("SaveUserAt(%q) error = %v, want ErrInvalidName", bad, err)
		}
	}
}

func TestLoadUser_SkipsMalformedPreset_LogsAndContinues(t *testing.T) {
	dir := t.TempDir()
	// One valid file, one corrupt file.
	if err := SaveUserAt(dir, Preset{Name: "good", LLM: LLMSpec{Provider: "anthropic"}, Transcribe: TranscribeSpec{ModelSize: "small"}}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "bad.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := LoadUserAt(dir)
	if err != nil {
		t.Fatalf("LoadUserAt: %v (one bad file must not fail load)", err)
	}
	if len(got) != 1 {
		t.Errorf("len = %d, want 1 (corrupt file should be skipped)", len(got))
	}
}

func TestDeleteUser_RemovesFile(t *testing.T) {
	dir := t.TempDir()
	if err := SaveUserAt(dir, Preset{Name: "tmp", LLM: LLMSpec{Provider: "anthropic"}, Transcribe: TranscribeSpec{ModelSize: "small"}}); err != nil {
		t.Fatal(err)
	}
	if err := DeleteUserAt(dir, "tmp"); err != nil {
		t.Fatalf("DeleteUserAt: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "tmp.json")); !os.IsNotExist(err) {
		t.Errorf("file not deleted: %v", err)
	}
}

func TestDeleteUser_RejectsBundled(t *testing.T) {
	dir := t.TempDir()
	for _, bad := range []string{"default", "minimal", "aggressive", "paranoid"} {
		if err := DeleteUserAt(dir, bad); !errors.Is(err, ErrReservedName) {
			t.Errorf("DeleteUserAt(%q) error = %v, want ErrReservedName", bad, err)
		}
	}
}

func TestDeleteUser_UnknownIsNoOp(t *testing.T) {
	dir := t.TempDir()
	if err := DeleteUserAt(dir, "nope"); err != nil {
		t.Errorf("DeleteUserAt on missing should be no-op: %v", err)
	}
}
```

- [ ] **Step 2: Verify failure**

Run: `cd core && go test ./internal/presets/... -run "TestSaveUser|TestLoadUser|TestDeleteUser" -v`
Expected: FAIL with undefined symbols.

- [ ] **Step 3: Implement user save/load/delete**

```go
// core/internal/presets/user.go
package presets

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// ErrReservedName is returned by SaveUserAt / DeleteUserAt when the
// caller tries to overwrite or delete a bundled preset.
var ErrReservedName = errors.New("presets: name collides with a bundled preset")

// ErrInvalidName is returned when the preset name doesn't match the
// allowed pattern (lowercase alphanumerics + dash/underscore, 1-40 chars).
var ErrInvalidName = errors.New("presets: invalid name (lowercase a-z0-9_-, 1-40 chars)")

var nameRE = regexp.MustCompile(`^[a-z0-9_-]{1,40}$`)

// reservedNames lists bundled preset names that user files must not
// shadow. Sourced from loadBundled at init so adding a bundled preset
// in JSON doesn't desync from the deny list.
var reservedNames = func() map[string]bool {
	out := map[string]bool{}
	if all, err := loadBundled(); err == nil {
		for _, p := range all {
			out[p.Name] = true
		}
	}
	return out
}()

// SaveUserAt writes preset p to <dir>/<name>.json. dir must exist.
// Returns ErrInvalidName for bad names, ErrReservedName if the name
// collides with a bundled preset.
func SaveUserAt(dir string, p Preset) error {
	if !nameRE.MatchString(p.Name) {
		return fmt.Errorf("%w: %q", ErrInvalidName, p.Name)
	}
	if reservedNames[p.Name] {
		return fmt.Errorf("%w: %q", ErrReservedName, p.Name)
	}
	buf, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return fmt.Errorf("presets: marshal: %w", err)
	}
	return os.WriteFile(filepath.Join(dir, p.Name+".json"), buf, 0o644)
}

// LoadUserAt walks <dir>/*.json and returns the parsed presets. Files
// that fail to parse are skipped with a logged warning — one bad file
// doesn't break the picker.
func LoadUserAt(dir string) ([]Preset, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("presets: read user dir: %w", err)
	}
	out := make([]Preset, 0, len(entries))
	for _, ent := range entries {
		if ent.IsDir() || !strings.HasSuffix(ent.Name(), ".json") {
			continue
		}
		path := filepath.Join(dir, ent.Name())
		buf, err := os.ReadFile(path)
		if err != nil {
			log.Printf("[vkb] presets: skipping %s: %v", path, err)
			continue
		}
		var p Preset
		if err := json.Unmarshal(buf, &p); err != nil {
			log.Printf("[vkb] presets: skipping %s: parse: %v", path, err)
			continue
		}
		out = append(out, p)
	}
	return out, nil
}

// DeleteUserAt removes <dir>/<name>.json. Idempotent: removing a
// non-existent name returns nil. Refuses to delete a bundled preset
// name (those don't live on disk anyway, so this is purely defensive).
func DeleteUserAt(dir, name string) error {
	if reservedNames[name] {
		return fmt.Errorf("%w: %q", ErrReservedName, name)
	}
	if !nameRE.MatchString(name) {
		return fmt.Errorf("%w: %q", ErrInvalidName, name)
	}
	err := os.Remove(filepath.Join(dir, name+".json"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("presets: delete %q: %w", name, err)
	}
	return nil
}

// Load returns the union of bundled + user presets, bundled first.
// Used by the C ABI / CLI; production callers want this. Tests use the
// per-dir variants for isolation.
//
// User presets are loaded from `~/Library/Application Support/VoiceKeyboard/presets/`
// on macOS. Errors loading user presets are logged but not returned —
// the bundled list is always available even if disk is unreadable.
func Load() ([]Preset, error) {
	all, err := loadBundled()
	if err != nil {
		return nil, err
	}
	dir, err := defaultUserDir()
	if err != nil {
		// No usable user dir → just return bundled.
		log.Printf("[vkb] presets.Load: no user dir (%v); bundled only", err)
		return all, nil
	}
	user, err := LoadUserAt(dir)
	if err != nil {
		log.Printf("[vkb] presets.Load: LoadUserAt(%s): %v; bundled only", dir, err)
		return all, nil
	}
	// Skip user presets whose name collides with a bundled name —
	// bundled wins, by construction.
	seen := map[string]bool{}
	for _, p := range all {
		seen[p.Name] = true
	}
	for _, p := range user {
		if seen[p.Name] {
			log.Printf("[vkb] presets.Load: skipping user preset %q (collides with bundled)", p.Name)
			continue
		}
		all = append(all, p)
	}
	return all, nil
}

// defaultUserDir returns the on-disk location for user presets. Creates
// it if missing so the first save succeeds.
func defaultUserDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, "Library", "Application Support", "VoiceKeyboard", "presets")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}

// SaveUser saves to defaultUserDir.
func SaveUser(p Preset) error {
	dir, err := defaultUserDir()
	if err != nil {
		return err
	}
	return SaveUserAt(dir, p)
}

// DeleteUser deletes from defaultUserDir.
func DeleteUser(name string) error {
	dir, err := defaultUserDir()
	if err != nil {
		return err
	}
	return DeleteUserAt(dir, name)
}
```

- [ ] **Step 4: Run tests**

Run: `cd core && go test ./internal/presets/... -v`
Expected: PASS — all presets tests including 7 new user tests.

- [ ] **Step 5: Commit**

```bash
git add core/internal/presets/user.go core/internal/presets/user_test.go
git commit -m "feat(presets): user preset save / load / delete with name validation"
```

---

## Phase C — Slice 2 Presets (C ABI)

### Task 10: C ABI — vkb_list_presets / vkb_get_preset / vkb_save_preset / vkb_delete_preset

**Files:**
- Modify: `core/cmd/libvkb/exports.go` (append four exports)
- Modify: `core/cmd/libvkb/sessions_goapi.go` (append wrappers; rename file later if needed)
- Modify: `core/cmd/libvkb/sessions_export_test.go` (append tests; or split into a new presets_export_test.go)

- [ ] **Step 1: Write the failing tests**

Create a new test file `core/cmd/libvkb/presets_export_test.go`:

```go
//go:build whispercpp

package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/voice-keyboard/core/internal/presets"
)

func TestExport_ListPresets_IncludesBundled(t *testing.T) {
	if getEngine() == nil {
		_ = vkb_init()
	}
	got := presetListGo()
	if got == "" {
		t.Fatal("expected non-empty result")
	}
	var arr []presets.Preset
	if err := json.Unmarshal([]byte(got), &arr); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(arr) < 4 {
		t.Errorf("len = %d, want at least 4 (bundled count)", len(arr))
	}
}

func TestExport_GetPreset_DefaultRoundTrips(t *testing.T) {
	if getEngine() == nil {
		_ = vkb_init()
	}
	got := presetGetGo("default")
	if got == "" {
		t.Fatal("expected non-empty result for default preset")
	}
	var p presets.Preset
	if err := json.Unmarshal([]byte(got), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.Name != "default" {
		t.Errorf("Name = %q, want default", p.Name)
	}
}

func TestExport_GetPreset_UnknownReturnsEmpty(t *testing.T) {
	if getEngine() == nil {
		_ = vkb_init()
	}
	got := presetGetGo("nope")
	if got != "" {
		t.Errorf("expected empty for unknown preset, got %q", got)
	}
}

func TestExport_SavePreset_RoundTrips(t *testing.T) {
	if getEngine() == nil {
		_ = vkb_init()
	}
	dir, err := os.MkdirTemp("", "vkb-presets-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })

	// Override the user dir for the save call so we don't pollute
	// the real ~/Library location.
	t.Setenv("VKB_PRESETS_USER_DIR", dir)

	body := `{"name":"my-test","description":"x","frame_stages":[],"chunk_stages":[],"transcribe":{"model_size":"small"},"llm":{"provider":"anthropic"}}`
	if rc := presetSaveGo("my-test", "x", body); rc != 0 {
		t.Fatalf("save rc=%d", rc)
	}
	// Listed back in the next List() call.
	listJSON := presetListGo()
	if !strings.Contains(listJSON, `"name":"my-test"`) {
		t.Errorf("saved preset not in list: %s", listJSON)
	}
}

func TestExport_DeletePreset_BundledNameRejected(t *testing.T) {
	if getEngine() == nil {
		_ = vkb_init()
	}
	if rc := presetDeleteGo("default"); rc != 5 {
		t.Errorf("rc = %d, want 5 (reserved name)", rc)
	}
}
```

- [ ] **Step 2: Add Go-string wrappers**

Append to `core/cmd/libvkb/sessions_goapi.go`:

```go
// presetListGo wraps vkb_list_presets and returns a Go string.
func presetListGo() string {
    cstr := vkb_list_presets()
    if cstr == nil {
        return ""
    }
    defer vkb_free_string(cstr)
    return C.GoString(cstr)
}

// presetGetGo wraps vkb_get_preset.
func presetGetGo(name string) string {
    cn := C.CString(name)
    defer C.free(unsafe.Pointer(cn))
    cstr := vkb_get_preset(cn)
    if cstr == nil {
        return ""
    }
    defer vkb_free_string(cstr)
    return C.GoString(cstr)
}

// presetSaveGo wraps vkb_save_preset. body must be a JSON-encoded Preset.
func presetSaveGo(name, description, body string) C.int {
    cn := C.CString(name)
    cd := C.CString(description)
    cb := C.CString(body)
    defer C.free(unsafe.Pointer(cn))
    defer C.free(unsafe.Pointer(cd))
    defer C.free(unsafe.Pointer(cb))
    return vkb_save_preset(cn, cd, cb)
}

// presetDeleteGo wraps vkb_delete_preset.
func presetDeleteGo(name string) C.int {
    cn := C.CString(name)
    defer C.free(unsafe.Pointer(cn))
    return vkb_delete_preset(cn)
}
```

Add `"unsafe"` to the imports if not present.

- [ ] **Step 3: Add the four exports**

Append to `core/cmd/libvkb/exports.go`:

```go
// vkb_list_presets returns a JSON array of presets (bundled + user).
// Caller frees via vkb_free_string. Returns NULL on engine-not-init.
//
//export vkb_list_presets
func vkb_list_presets() *C.char {
    e := getEngine()
    if e == nil {
        return nil
    }
    all, err := presets.Load()
    if err != nil {
        e.setLastError("vkb_list_presets: " + err.Error())
        return nil
    }
    if all == nil {
        all = []presets.Preset{}
    }
    buf, err := json.Marshal(all)
    if err != nil {
        e.setLastError("vkb_list_presets: marshal: " + err.Error())
        return nil
    }
    return C.CString(string(buf))
}

// vkb_get_preset returns the JSON-encoded Preset for the given name,
// or NULL if not found. Caller frees via vkb_free_string.
//
//export vkb_get_preset
func vkb_get_preset(nameC *C.char) *C.char {
    e := getEngine()
    if e == nil {
        return nil
    }
    if nameC == nil {
        e.setLastError("vkb_get_preset: name is NULL")
        return nil
    }
    name := C.GoString(nameC)
    all, err := presets.Load()
    if err != nil {
        e.setLastError("vkb_get_preset: " + err.Error())
        return nil
    }
    for _, p := range all {
        if p.Name == name {
            buf, err := json.Marshal(p)
            if err != nil {
                e.setLastError("vkb_get_preset: marshal: " + err.Error())
                return nil
            }
            return C.CString(string(buf))
        }
    }
    return nil
}

// vkb_save_preset persists a user preset. body is a JSON-encoded
// Preset. Returns 0 on success, 1 if engine not initialized, 5 for
// invalid/reserved name, 6 for filesystem error, 2 for JSON parse error.
//
//export vkb_save_preset
func vkb_save_preset(nameC, descriptionC, bodyC *C.char) C.int {
    e := getEngine()
    if e == nil {
        return 1
    }
    if nameC == nil || bodyC == nil {
        e.setLastError("vkb_save_preset: nil argument")
        return 5
    }
    body := C.GoString(bodyC)
    var p presets.Preset
    if err := json.Unmarshal([]byte(body), &p); err != nil {
        e.setLastError("vkb_save_preset: parse: " + err.Error())
        return 2
    }
    // The plan threads name + description in case the body lacks them
    // (e.g. constructed from an EngineConfig) — overwrite name + desc.
    p.Name = C.GoString(nameC)
    if descriptionC != nil {
        p.Description = C.GoString(descriptionC)
    }
    if err := presets.SaveUser(p); err != nil {
        e.setLastError("vkb_save_preset: " + err.Error())
        if errors.Is(err, presets.ErrInvalidName) || errors.Is(err, presets.ErrReservedName) {
            return 5
        }
        return 6
    }
    return 0
}

// vkb_delete_preset removes a user preset. Returns 0 on success
// (idempotent), 1 if engine not init, 5 for invalid/reserved name,
// 6 for filesystem error.
//
//export vkb_delete_preset
func vkb_delete_preset(nameC *C.char) C.int {
    e := getEngine()
    if e == nil {
        return 1
    }
    if nameC == nil {
        e.setLastError("vkb_delete_preset: name is NULL")
        return 5
    }
    name := C.GoString(nameC)
    if err := presets.DeleteUser(name); err != nil {
        e.setLastError("vkb_delete_preset: " + err.Error())
        if errors.Is(err, presets.ErrInvalidName) || errors.Is(err, presets.ErrReservedName) {
            return 5
        }
        return 6
    }
    return 0
}
```

Add `"github.com/voice-keyboard/core/internal/presets"` to the imports.

- [ ] **Step 4: Modify `defaultUserDir` to honor `VKB_PRESETS_USER_DIR` for tests**

In `core/internal/presets/user.go`:

```go
func defaultUserDir() (string, error) {
    if dir := os.Getenv("VKB_PRESETS_USER_DIR"); dir != "" {
        if err := os.MkdirAll(dir, 0o755); err != nil {
            return "", err
        }
        return dir, nil
    }
    home, err := os.UserHomeDir()
    // ... rest unchanged ...
```

- [ ] **Step 5: Add stubs for the four new symbols in cvkb_stubs.c**

In `mac/Packages/VoiceKeyboardCore/Sources/CVKBStubs/cvkb_stubs.c`, append (matching the existing pattern):

```c
// Preset management — Slice 2 stubs for SwiftPM test build.
const char* vkb_list_presets(void) { return NULL; }
const char* vkb_get_preset(const char* name) { (void)name; return NULL; }
int vkb_save_preset(const char* name, const char* description, const char* body) {
    (void)name; (void)description; (void)body; return 1;
}
int vkb_delete_preset(const char* name) { (void)name; return 1; }
```

In `mac/Packages/VoiceKeyboardCore/Sources/CVKB/include/libvkb_shim.h`, append the matching declarations.

- [ ] **Step 6: Run tests**

Run: `cd core && go test -tags=whispercpp ./cmd/libvkb/... -v`
Expected: PASS — all 5 new TestExport_*Preset tests.

- [ ] **Step 7: Build the dylib**

Run: `cd core && make build-dylib`
Expected: clean build.

- [ ] **Step 8: Commit**

```bash
git add core/cmd/libvkb/exports.go core/cmd/libvkb/sessions_goapi.go \
        core/cmd/libvkb/presets_export_test.go core/internal/presets/user.go \
        mac/Packages/VoiceKeyboardCore/Sources/CVKBStubs/cvkb_stubs.c \
        mac/Packages/VoiceKeyboardCore/Sources/CVKB/include/libvkb_shim.h
git commit -m "feat(libvkb): vkb_list_presets / vkb_get_preset / vkb_save_preset / vkb_delete_preset"
```

---

## Phase D — Slice 2 TSE threshold

### Task 11: SpeakerGate threshold + similarity computation + gating

**Files:**
- Modify: `core/internal/speaker/speakerbeam.go`
- Modify: `core/internal/speaker/speakerbeam_test.go`

This is the biggest task in the slice. SpeakerGate gains:
- A `Threshold float32` field.
- An optional `encoderSession *ort.DynamicAdvancedSession` loaded at `NewSpeakerGate` from `encoderPath`.
- After `Extract`, if encoder is loaded and threshold > 0: encode the extracted audio, compute cosine similarity vs ref, store as `lastSimilarity`. If similarity < threshold, return zeros instead of extract.
- A new `LastSimilarity() float32` accessor for the pipeline to surface in events.

- [ ] **Step 1: Read existing SpeakerGate to understand the constructor**

Run: `sed -n '20,55p' core/internal/speaker/speakerbeam.go`
Expected: shows `SpeakerGate` struct and `NewSpeakerGate`.

- [ ] **Step 2: Write failing tests**

Append to `core/internal/speaker/speakerbeam_test.go`:

```go
func TestSpeakerGate_ThresholdZeroDisablesGating(t *testing.T) {
    // Without threshold (or threshold = 0), Extract returns the model
    // output unchanged. The fakeTSE in the existing test setup
    // produces a known waveform; verify Extract returns it.
    g := newFakeSpeakerGate(t, []float32{1, 2, 3, 4})
    g.threshold = 0
    out, err := g.Extract(context.Background(), []float32{0.1, 0.2, 0.3, 0.4})
    if err != nil {
        t.Fatalf("Extract: %v", err)
    }
    if len(out) != 4 || out[0] != 1 {
        t.Errorf("got %v, want fake output", out)
    }
}

func TestSpeakerGate_BelowThresholdReturnsZeros(t *testing.T) {
    // Force similarity well below threshold; Extract should silence.
    g := newFakeSpeakerGate(t, []float32{1, 2, 3, 4})
    g.threshold = 0.9
    g.fakeSimilarity = 0.3 // < threshold
    out, err := g.Extract(context.Background(), []float32{0.1, 0.2, 0.3, 0.4})
    if err != nil {
        t.Fatalf("Extract: %v", err)
    }
    for i, v := range out {
        if v != 0 {
            t.Errorf("out[%d] = %v, want 0 (gated)", i, v)
        }
    }
}

func TestSpeakerGate_AboveThresholdReturnsExtracted(t *testing.T) {
    g := newFakeSpeakerGate(t, []float32{1, 2, 3, 4})
    g.threshold = 0.5
    g.fakeSimilarity = 0.8
    out, err := g.Extract(context.Background(), []float32{0.1, 0.2, 0.3, 0.4})
    if err != nil {
        t.Fatalf("Extract: %v", err)
    }
    if out[0] != 1 {
        t.Errorf("got %v, want fake output unchanged", out)
    }
}

func TestSpeakerGate_LastSimilarity(t *testing.T) {
    g := newFakeSpeakerGate(t, []float32{1, 2, 3, 4})
    g.fakeSimilarity = 0.62
    _, _ = g.Extract(context.Background(), []float32{0.1, 0.2, 0.3, 0.4})
    if got := g.LastSimilarity(); got != 0.62 {
        t.Errorf("LastSimilarity = %v, want 0.62", got)
    }
}
```

The tests reference a `newFakeSpeakerGate` helper and assume internal fields `threshold` / `fakeSimilarity`. We'll declare them in the implementation.

- [ ] **Step 3: Verify failure**

Run: `cd core && go test ./internal/speaker/... -run TestSpeakerGate -v`
Expected: FAIL with undefined symbols.

- [ ] **Step 4: Implement threshold + similarity in SpeakerGate**

Modify `core/internal/speaker/speakerbeam.go`. Update the struct + constructor:

```go
type SpeakerGate struct {
    session *ort.DynamicAdvancedSession
    ref     []float32

    // Threshold — when > 0 AND encoder is loaded, the post-Extract
    // cosine similarity gate fires. Below the threshold, Extract
    // returns zeros same length as input. 0 disables gating entirely.
    threshold float32

    // encoderSession — speaker encoder ONNX session, loaded at
    // construction if encoderPath is provided. Used to encode the
    // extracted output for similarity computation. nil disables the
    // post-extract similarity gate even if threshold > 0.
    encoderSession *ort.DynamicAdvancedSession
    encoderDim     int

    // lastSimilarity — most recent cosine similarity computed in
    // Extract, exposed via LastSimilarity() for event emission.
    // Value semantics: 1.0 means no gate ran (encoder absent or
    // threshold == 0), so callers checking "did the gate run?" should
    // also check whether encoderSession != nil.
    lastSimilarity float32

    // fakeSimilarity — testing hook. When non-zero, Extract uses this
    // value instead of computing one from the encoder. Production
    // callers leave this at zero.
    fakeSimilarity float32
}

// SpeakerGateOptions configures NewSpeakerGate.
type SpeakerGateOptions struct {
    ModelPath   string
    Reference   []float32
    Threshold   float32
    EncoderPath string  // optional; if empty, similarity gate doesn't run
    EncoderDim  int     // required if EncoderPath is set
}

// NewSpeakerGate loads the TSE model. If opts.EncoderPath is set, also
// loads the encoder ONNX so post-extract similarity gating works.
func NewSpeakerGate(opts SpeakerGateOptions) (*SpeakerGate, error) {
    if len(opts.Reference) == 0 {
        return nil, fmt.Errorf("speakergate: empty reference embedding")
    }
    captured := make([]float32, len(opts.Reference))
    copy(captured, opts.Reference)
    sess, err := ort.NewDynamicAdvancedSession(
        opts.ModelPath,
        []string{"mixed", "ref_embedding"},
        []string{"extracted"},
        nil,
    )
    if err != nil {
        return nil, fmt.Errorf("speakergate: load %q: %w", opts.ModelPath, err)
    }
    g := &SpeakerGate{session: sess, ref: captured, threshold: opts.Threshold, encoderDim: opts.EncoderDim}
    if opts.EncoderPath != "" {
        encSess, err := ort.NewDynamicAdvancedSession(
            opts.EncoderPath,
            []string{"audio"},
            []string{"embedding"},
            nil,
        )
        if err != nil {
            _ = sess.Destroy()
            return nil, fmt.Errorf("speakergate: load encoder %q: %w", opts.EncoderPath, err)
        }
        g.encoderSession = encSess
    }
    return g, nil
}

// LastSimilarity returns the most recent cosine similarity computed by
// Extract. Returns 1.0 if the gate didn't run (no encoder configured
// or threshold is 0).
func (g *SpeakerGate) LastSimilarity() float32 {
    if g == nil {
        return 0
    }
    return g.lastSimilarity
}
```

Modify `Extract` to compute similarity + gate after the existing inference:

```go
func (g *SpeakerGate) Extract(_ context.Context, mixed []float32) ([]float32, error) {
    // ... existing inference code unchanged, producing `out` ...

    // Threshold gate: only runs if (a) gate is configured (threshold > 0)
    // AND (b) we can compute similarity (encoder loaded OR fakeSimilarity set).
    if g.threshold > 0 && (g.encoderSession != nil || g.fakeSimilarity != 0) {
        var sim float32
        if g.fakeSimilarity != 0 {
            sim = g.fakeSimilarity
        } else {
            emb, err := g.encodeExtracted(out)
            if err != nil {
                // Encoder failed; log + bypass gate to avoid eating user audio.
                log.Printf("[vkb] speakergate: encode for similarity failed (bypassing gate): %v", err)
                g.lastSimilarity = 1.0
                return out, nil
            }
            sim = cosineSimilarity(emb, g.ref)
        }
        g.lastSimilarity = sim
        if sim < g.threshold {
            zeros := make([]float32, len(out))
            return zeros, nil
        }
        return out, nil
    }
    g.lastSimilarity = 1.0
    return out, nil
}

// encodeExtracted runs the speaker encoder on the extracted audio.
func (g *SpeakerGate) encodeExtracted(audio []float32) ([]float32, error) {
    audioT, err := ort.NewTensor(ort.NewShape(1, int64(len(audio))), audio)
    if err != nil {
        return nil, fmt.Errorf("encoder: audio tensor: %w", err)
    }
    defer audioT.Destroy()
    embT, err := ort.NewEmptyTensor[float32](ort.NewShape(1, int64(g.encoderDim)))
    if err != nil {
        return nil, fmt.Errorf("encoder: emb tensor: %w", err)
    }
    defer embT.Destroy()
    if err := g.encoderSession.Run([]ort.Value{audioT}, []ort.Value{embT}); err != nil {
        return nil, fmt.Errorf("encoder: inference: %w", err)
    }
    out := make([]float32, g.encoderDim)
    copy(out, embT.GetData())
    return out, nil
}

// cosineSimilarity assumes a is L2-normalized but computes the norm
// for b on the fly (the extracted-audio embedding isn't normalized
// inside the model).
func cosineSimilarity(a, b []float32) float32 {
    if len(a) != len(b) {
        return 0
    }
    var dot, normB float64
    for i := range a {
        dot += float64(a[i]) * float64(b[i])
        normB += float64(b[i]) * float64(b[i])
    }
    if normB == 0 {
        return 0
    }
    return float32(dot / float64(float32(math.Sqrt(normB))))
}
```

Add `"log"` and `"math"` to imports.

Update `Close` to release the encoder session too:

```go
func (g *SpeakerGate) Close() error {
    if g.encoderSession != nil {
        _ = g.encoderSession.Destroy()
        g.encoderSession = nil
    }
    return g.session.Destroy()
}
```

Add the deprecated old constructor as a compatibility shim so existing call sites don't break:

```go
// Deprecated: use NewSpeakerGate(SpeakerGateOptions{...}) instead.
func newSpeakerGateLegacy(modelPath string, ref []float32) (*SpeakerGate, error) {
    return NewSpeakerGate(SpeakerGateOptions{ModelPath: modelPath, Reference: ref})
}
```

Existing call sites: search for `NewSpeakerGate(` and update each to use `SpeakerGateOptions`. The libvkb composer (in pipeline.LoadTSE or similar) will need updating to thread `EncoderPath` + `EncoderDim` + `Threshold` through.

- [ ] **Step 5: Add the test helper `newFakeSpeakerGate`**

Append to `core/internal/speaker/speakerbeam_test.go`:

```go
// fakeOnnx replaces the real ONNX session for tests by returning a
// fixed output. Lives only in tests.
type fakeOnnx struct {
    output []float32
}

// newFakeSpeakerGate constructs a SpeakerGate without the real ONNX
// session. The fakeOutput is what Extract returns post-inference
// (before any gating logic runs). Used only in tests.
func newFakeSpeakerGate(t *testing.T, fakeOutput []float32) *SpeakerGate {
    t.Helper()
    return &SpeakerGate{
        ref:           []float32{0.5, 0.5}, // arbitrary
        threshold:     0,
        // No real session — rely on fakeSimilarity path; tests that
        // care about Extract output must monkey-patch via t.Cleanup
        // or use a wrapper, but for the threshold tests we need a
        // way to bypass the real inference. We'll add a fakeOutput
        // hook on the struct.
    }
}
```

Hmm, this won't work cleanly because the existing Extract calls into the real `g.session.Run`. To make this testable cleanly, we'd need to extract an interface for the inference. That's a meaningful refactor.

**Pragmatic shortcut for v1**: skip the `_AboveThresholdReturnsExtracted` and `_BelowThresholdReturnsZeros` Extract-output tests in pure unit form, and instead:

- Unit-test `cosineSimilarity` directly (mathematically deterministic; no ONNX needed).
- Unit-test the threshold-gate logic by extracting it into a helper `gate(out []float32, threshold, similarity float32) []float32` that just does the if/else. Test that helper.
- Document the integration test (full Extract path with real ONNX) as a separate suite gated on the model being present.

Let me restructure the test:

```go
// Append to core/internal/speaker/speakerbeam_test.go:

func TestCosineSimilarity_Identical(t *testing.T) {
    a := []float32{1, 0, 0}  // already L2-normalized
    if got := cosineSimilarity(a, a); got < 0.999 || got > 1.001 {
        t.Errorf("got %v, want ~1.0", got)
    }
}

func TestCosineSimilarity_Orthogonal(t *testing.T) {
    a := []float32{1, 0}
    b := []float32{0, 1}
    if got := cosineSimilarity(a, b); got < -0.001 || got > 0.001 {
        t.Errorf("got %v, want ~0.0", got)
    }
}

func TestApplyThreshold_BelowReturnsZeros(t *testing.T) {
    in := []float32{1, 2, 3, 4}
    out := applyThreshold(in, 0.3, 0.5)
    for i, v := range out {
        if v != 0 {
            t.Errorf("out[%d] = %v, want 0", i, v)
        }
    }
}

func TestApplyThreshold_AboveReturnsInput(t *testing.T) {
    in := []float32{1, 2, 3, 4}
    out := applyThreshold(in, 0.7, 0.5)
    if len(out) != 4 || out[0] != 1 {
        t.Errorf("expected pass-through, got %v", out)
    }
}

func TestApplyThreshold_ZeroDisables(t *testing.T) {
    in := []float32{1, 2, 3, 4}
    out := applyThreshold(in, 0.0, 0.0)
    if out[0] != 1 {
        t.Errorf("threshold=0 should pass through, got %v", out)
    }
}
```

And extract `applyThreshold` from Extract:

```go
// applyThreshold returns zeros same length as in if similarity is below
// threshold AND threshold is positive. Otherwise returns in unchanged.
// Pure function, no allocation when passing through.
func applyThreshold(in []float32, similarity, threshold float32) []float32 {
    if threshold > 0 && similarity < threshold {
        return make([]float32, len(in))
    }
    return in
}
```

Then in Extract:

```go
g.lastSimilarity = sim
return applyThreshold(out, sim, g.threshold), nil
```

This is much cleaner. Strike the `newFakeSpeakerGate` and `fakeSimilarity` plumbing — replace with the pure helper.

- [ ] **Step 6: Final test set**

Replace the test additions (Step 2 + Step 5 above) with just the `TestCosineSimilarity_*` and `TestApplyThreshold_*` tests above. The end-to-end Extract path is exercised by the existing integration tests against the real ONNX model.

- [ ] **Step 7: Run tests**

Run: `cd core && go test ./internal/speaker/... -v`
Expected: PASS — including the 5 new tests + existing speaker tests.

- [ ] **Step 8: Update libvkb composer to thread EncoderPath/Dim/Threshold**

Find where `NewSpeakerGate` is called in the libvkb composer (likely `pipeline.LoadTSE` or a sibling). Update the call to use `SpeakerGateOptions`:

Run: `grep -rn "NewSpeakerGate" core/`
Expected: shows the call site (likely 1-2 places).

Update each call to pass:
- `Threshold: cfg.TSEThresholdValue()` (a helper that returns 0 if cfg.TSEThreshold is nil, else the deref)
- `EncoderPath: cfg.SpeakerEncoderPath`
- `EncoderDim: backend.EmbeddingDim` (192 for ECAPA)

Add a helper to `core/internal/config/config.go`:

```go
// TSEThresholdValue returns the configured TSE threshold or 0 if unset.
// 0 disables gating; the SpeakerGate treats 0 as a no-op.
func (c *Config) TSEThresholdValue() float32 {
    if c == nil || c.TSEThreshold == nil {
        return 0
    }
    return *c.TSEThreshold
}
```

- [ ] **Step 9: Build dylib + run libvkb tests**

Run: `cd core && make build-dylib && go test -tags=whispercpp ./cmd/libvkb/... -v`
Expected: PASS — all libvkb tests still green.

- [ ] **Step 10: Commit**

```bash
git add core/internal/speaker/speakerbeam.go core/internal/speaker/speakerbeam_test.go core/internal/config/config.go core/cmd/libvkb/state.go
git commit -m "feat(speaker): TSE threshold gating + cosine similarity computation"
```

---

### Task 12: Pipeline event emits TSE similarity

**Files:**
- Modify: `core/internal/pipeline/event.go` (add `TSESimilarity *float32`)
- Modify: `core/internal/pipeline/pipeline.go` (set the field after TSE Process)

- [ ] **Step 1: Add the field**

In `core/internal/pipeline/event.go`, add to the `Event` struct:

```go
type Event struct {
    // ... existing fields ...

    // TSESimilarity, when non-nil, is the cosine similarity the TSE
    // chunk stage computed for this chunk. Populated only on
    // EventStageProcessed events for the "tse" stage. nil for all
    // other events / stages.
    TSESimilarity *float32
}
```

- [ ] **Step 2: Set the field after the TSE chunk stage runs**

In `core/internal/pipeline/pipeline.go`, find the chunk-stage loop (around line 139). After `out, err := st.Process(...)` but before `p.emit(Event{...})`, add:

```go
var tseSim *float32
if st.Name() == "tse" {
    if g, ok := st.(interface{ LastSimilarity() float32 }); ok {
        s := g.LastSimilarity()
        tseSim = &s
    }
}
p.emit(Event{
    Kind:           EventStageProcessed,
    Stage:          st.Name(),
    DurationMs:     int(time.Since(t0).Milliseconds()),
    TSESimilarity:  tseSim,
})
```

(Adjust to fit the existing emit-call surface — the snippet shows the additional TSESimilarity field; preserve existing fields like RMSOut.)

- [ ] **Step 3: Run pipeline tests**

Run: `cd core && go test ./internal/pipeline/... -v`
Expected: PASS — no regressions.

- [ ] **Step 4: Surface the similarity in the session manifest stage entry**

In `core/cmd/libvkb/exports.go`, the manifest builder from Task 3 walks `pipe.ChunkStages`. For the "tse" stage, also populate `TSESimilarity` from the SpeakerGate's `LastSimilarity()`:

In the chunk-stage walk:

```go
for _, st := range pipe.ChunkStages {
    r := rate
    if out := st.OutputRate(); out != 0 {
        r = out
    }
    entry := sessions.StageEntry{
        Name:   st.Name(),
        Kind:   "chunk",
        WavRel: st.Name() + ".wav",
        RateHz: r,
    }
    // For TSE, attach the most recent cosine similarity if available.
    if st.Name() == "tse" {
        if g, ok := st.(interface{ LastSimilarity() float32 }); ok {
            s := g.LastSimilarity()
            entry.TSESimilarity = &s
        }
    }
    stages = append(stages, entry)
    if out := st.OutputRate(); out != 0 {
        rate = out
    }
}
```

- [ ] **Step 5: Build + tests**

Run: `cd core && make build-dylib && go test -tags=whispercpp ./cmd/libvkb/... -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add core/internal/pipeline/event.go core/internal/pipeline/pipeline.go core/cmd/libvkb/exports.go
git commit -m "feat(pipeline): emit TSE cosine similarity in events + manifest"
```

---

## Phase E — Slice 2 Mac UI

### Task 13: PresetsClient + bridge methods

**Files:**
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/Preset.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/PresetsClient.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/PresetsClientTests.swift`
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift` (add 4 async methods)
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/LibvkbEngine.swift` (impl)
- Modify: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CoreEngineTests.swift` (extend SpyCoreEngine)

- [ ] **Step 1: Create Preset.swift**

```swift
// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/Preset.swift
import Foundation

/// Mirrors core/internal/presets.Preset. Decoded from JSON returned by
/// vkb_list_presets / vkb_get_preset.
public struct Preset: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String
    public let frameStages: [StageSpec]
    public let chunkStages: [StageSpec]
    public let transcribe: TranscribeSpec
    public let llm: LLMSpec

    public var id: String { name }

    public struct StageSpec: Codable, Equatable, Sendable {
        public let name: String
        public let enabled: Bool
        public let backend: String?
        public let threshold: Float?
    }

    public struct TranscribeSpec: Codable, Equatable, Sendable {
        public let modelSize: String
        enum CodingKeys: String, CodingKey { case modelSize = "model_size" }
    }

    public struct LLMSpec: Codable, Equatable, Sendable {
        public let provider: String
    }

    enum CodingKeys: String, CodingKey {
        case name, description, transcribe, llm
        case frameStages = "frame_stages"
        case chunkStages = "chunk_stages"
    }
}
```

- [ ] **Step 2: Create PresetsClient.swift**

```swift
// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/PresetsClient.swift
import Foundation

public enum PresetsClientError: Error {
    case engineUnavailable
    case decode(String)
    case backend(String)
}

public protocol PresetsClient: Sendable {
    func list() async throws -> [Preset]
    func get(_ name: String) async throws -> Preset
    func save(_ preset: Preset) async throws
    func delete(_ name: String) async throws
}

public final class LibVKBPresetsClient: PresetsClient {
    private let engine: any CoreEngine

    public init(engine: any CoreEngine) {
        self.engine = engine
    }

    public func list() async throws -> [Preset] {
        guard let json = await engine.presetsListJSON() else {
            throw PresetsClientError.engineUnavailable
        }
        do {
            return try JSONDecoder().decode([Preset].self, from: Data(json.utf8))
        } catch {
            throw PresetsClientError.decode(String(describing: error))
        }
    }

    public func get(_ name: String) async throws -> Preset {
        guard let json = await engine.presetGetJSON(name) else {
            throw PresetsClientError.backend(await engine.lastError() ?? "preset not found")
        }
        do {
            return try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        } catch {
            throw PresetsClientError.decode(String(describing: error))
        }
    }

    public func save(_ preset: Preset) async throws {
        let body = try JSONEncoder().encode(preset)
        let bodyStr = String(decoding: body, as: UTF8.self)
        let rc = await engine.presetSaveJSON(name: preset.name, description: preset.description, body: bodyStr)
        guard rc == 0 else {
            throw PresetsClientError.backend(await engine.lastError() ?? "save rc=\(rc)")
        }
    }

    public func delete(_ name: String) async throws {
        let rc = await engine.presetDelete(name)
        guard rc == 0 else {
            throw PresetsClientError.backend(await engine.lastError() ?? "delete rc=\(rc)")
        }
    }
}
```

- [ ] **Step 3: Add bridge methods to CoreEngine + LibvkbEngine + SpyCoreEngine**

In `CoreEngine.swift`, add to the protocol:

```swift
func presetsListJSON() async -> String?
func presetGetJSON(_ name: String) async -> String?
func presetSaveJSON(name: String, description: String, body: String) async -> Int32
func presetDelete(_ name: String) async -> Int32
```

In `LibvkbEngine.swift`, implement them mirroring the Sessions impls:

```swift
public func presetsListJSON() -> String? {
    guard let cstr = vkb_list_presets() else { return nil }
    defer { vkb_free_string(cstr) }
    return String(cString: cstr)
}

public func presetGetJSON(_ name: String) -> String? {
    return name.withCString { cn -> String? in
        guard let cstr = vkb_get_preset(cn) else { return nil }
        defer { vkb_free_string(cstr) }
        return String(cString: cstr)
    }
}

public func presetSaveJSON(name: String, description: String, body: String) -> Int32 {
    return name.withCString { cn in
        description.withCString { cd in
            body.withCString { cb in
                vkb_save_preset(cn, cd, cb)
            }
        }
    }
}

public func presetDelete(_ name: String) -> Int32 {
    return name.withCString { cn in vkb_delete_preset(cn) }
}
```

In `CoreEngineTests.swift`, extend `SpyCoreEngine`:

```swift
var stubPresetsListJSON: String? = "[]"
var stubPresetGetJSON: [String: String] = [:]
var stubPresetSaveRC: Int32 = 0
var stubPresetDeleteRC: Int32 = 0

func presetsListJSON() -> String? { stubPresetsListJSON }
func presetGetJSON(_ name: String) -> String? { stubPresetGetJSON[name] }
func presetSaveJSON(name: String, description: String, body: String) -> Int32 { stubPresetSaveRC }
func presetDelete(_ name: String) -> Int32 { stubPresetDeleteRC }
```

- [ ] **Step 4: Write PresetsClientTests**

```swift
// mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/PresetsClientTests.swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("PresetsClient", .serialized)
struct PresetsClientTests {
    @Test func list_decodesEmptyArray() async throws {
        let engine = SpyCoreEngine()
        engine.stubPresetsListJSON = "[]"
        let c = LibVKBPresetsClient(engine: engine)
        #expect(try await c.list().isEmpty)
    }

    @Test func list_decodesPresets() async throws {
        let json = """
        [
          {"name":"default","description":"x","frame_stages":[],"chunk_stages":[],
           "transcribe":{"model_size":"small"},"llm":{"provider":"anthropic"}}
        ]
        """
        let engine = SpyCoreEngine()
        engine.stubPresetsListJSON = json
        let c = LibVKBPresetsClient(engine: engine)
        let got = try await c.list()
        #expect(got.count == 1)
        #expect(got[0].name == "default")
    }

    @Test func get_returnsPreset() async throws {
        let engine = SpyCoreEngine()
        engine.stubPresetGetJSON["default"] = """
        {"name":"default","description":"x","frame_stages":[],"chunk_stages":[],
         "transcribe":{"model_size":"small"},"llm":{"provider":"anthropic"}}
        """
        let c = LibVKBPresetsClient(engine: engine)
        let got = try await c.get("default")
        #expect(got.name == "default")
    }

    @Test func save_roundTrips() async throws {
        let engine = SpyCoreEngine()
        engine.stubPresetSaveRC = 0
        let c = LibVKBPresetsClient(engine: engine)
        let p = Preset(name: "x", description: "y",
                       frameStages: [], chunkStages: [],
                       transcribe: .init(modelSize: "small"),
                       llm: .init(provider: "anthropic"))
        try await c.save(p)
    }

    @Test func save_invalidNameThrows() async {
        let engine = SpyCoreEngine()
        engine.stubPresetSaveRC = 5
        let c = LibVKBPresetsClient(engine: engine)
        let p = Preset(name: "../bad", description: "",
                       frameStages: [], chunkStages: [],
                       transcribe: .init(modelSize: "small"),
                       llm: .init(provider: "anthropic"))
        await #expect(throws: PresetsClientError.self) { try await c.save(p) }
    }

    @Test func delete_succeeds() async throws {
        let engine = SpyCoreEngine()
        engine.stubPresetDeleteRC = 0
        let c = LibVKBPresetsClient(engine: engine)
        try await c.delete("custom")
    }

    @Test func delete_reservedNameThrows() async {
        let engine = SpyCoreEngine()
        engine.stubPresetDeleteRC = 5
        let c = LibVKBPresetsClient(engine: engine)
        await #expect(throws: PresetsClientError.self) { try await c.delete("default") }
    }
}
```

- [ ] **Step 5: Run tests + build**

Run: `cd mac && make test`
Expected: PASS — including 7 new PresetsClient tests.

Run: `cd mac && make build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/Preset.swift \
        mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/PresetsClient.swift \
        mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/CoreEngine.swift \
        mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/LibvkbEngine.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/CoreEngineTests.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/PresetsClientTests.swift
git commit -m "feat(mac): PresetsClient + CoreEngine bridge for libvkb preset ABI"
```

---

### Task 14: PipelineTab segmented control + EditorView with preset picker

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift` (add segmented control)
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift`
- Modify: `mac/VoiceKeyboard/UI/Settings/SettingsView.swift` (pass PresetsClient into PipelineTab)

- [ ] **Step 1: Update PipelineTab to host both Inspector + Editor**

Replace `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift` with:

```swift
import SwiftUI
import VoiceKeyboardCore

struct PipelineTab: View {
    let engine: any CoreEngine
    let sessions: any SessionsClient
    let presets: any PresetsClient

    @State private var selectedView: View_ = .inspector

    enum View_: String, CaseIterable, Identifiable {
        case inspector = "Inspector"
        case editor = "Editor"
        var id: String { rawValue }
    }

    var body: some View {
        SettingsPane {
            Picker("", selection: $selectedView) {
                ForEach(View_.allCases) { v in
                    Text(v.rawValue).tag(v)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.bottom, 8)

            Divider()

            switch selectedView {
            case .inspector:
                InspectorView(sessions: sessions)
            case .editor:
                EditorView(presets: presets)
            }
        }
    }
}
```

- [ ] **Step 2: Create EditorView with the preset picker**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift
import SwiftUI
import VoiceKeyboardCore

/// Slice 2 Editor: preset dropdown + Save/Reset + per-stage detail
/// panel showing TSE threshold + recent similarity. The drag-and-drop
/// stage graph is Slice 3.
struct EditorView: View {
    let presets: any PresetsClient

    @State private var presetList: [Preset] = []
    @State private var selectedName: String = ""
    @State private var loadError: String? = nil
    @State private var saveSheetVisible = false

    private var selectedPreset: Preset? {
        presetList.first(where: { $0.name == selectedName })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            Divider()
            if let p = selectedPreset {
                presetDetail(p)
            } else if let err = loadError {
                Text(err).foregroundStyle(.red).font(.callout)
            } else {
                Text("Loading presets…").foregroundStyle(.secondary).font(.callout)
            }
        }
        .task { await refresh() }
        .sheet(isPresented: $saveSheetVisible) {
            // SaveAsPresetSheet lands in Task 15 (kept simple here).
            Text("Save preset (Slice 2.5)")
                .padding()
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("Preset:").foregroundStyle(.secondary).font(.callout)
            Picker("Preset", selection: $selectedName) {
                if presetList.isEmpty {
                    Text("(none)").tag("")
                } else {
                    ForEach(presetList) { p in
                        Text(p.name).tag(p.name)
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)

            Button {
                saveSheetVisible = true
            } label: { Label("Save as…", systemImage: "square.and.arrow.down") }
            .controlSize(.small)
            .disabled(selectedName.isEmpty)

            Button {
                Task { await selectPreset("default") }
            } label: { Label("Reset", systemImage: "arrow.uturn.backward") }
            .controlSize(.small)

            Spacer()
        }
    }

    @ViewBuilder
    private func presetDetail(_ p: Preset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.description).font(.callout).foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Text("STAGES").font(.caption).foregroundStyle(.secondary).bold()
            ForEach(p.frameStages, id: \.name) { st in
                stageRow(st, kind: "frame")
            }
            ForEach(p.chunkStages, id: \.name) { st in
                stageRow(st, kind: "chunk")
            }

            Divider().padding(.vertical, 4)

            Text("TRANSCRIBE").font(.caption).foregroundStyle(.secondary).bold()
            HStack {
                Text("Whisper model").font(.callout)
                Spacer()
                Text(p.transcribe.modelSize).font(.callout.monospaced()).foregroundStyle(.secondary)
            }

            Text("LLM").font(.caption).foregroundStyle(.secondary).bold()
            HStack {
                Text("Provider").font(.callout)
                Spacer()
                Text(p.llm.provider).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func stageRow(_ st: Preset.StageSpec, kind: String) -> some View {
        HStack {
            Image(systemName: st.enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(st.enabled ? .green : .secondary)
            Text(st.name).font(.callout).bold()
            Text("(\(kind))").foregroundStyle(.secondary).font(.caption)
            Spacer()
            if st.name == "tse", let t = st.threshold {
                Text("threshold: \(String(format: "%.2f", t))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let backend = st.backend, !backend.isEmpty {
                Text(backend).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() async {
        do {
            let list = try await presets.list()
            await MainActor.run {
                self.presetList = list
                if self.selectedName.isEmpty, let first = list.first {
                    self.selectedName = first.name
                }
            }
        } catch {
            await MainActor.run {
                self.loadError = "Failed to load presets: \(error)"
            }
        }
    }

    private func selectPreset(_ name: String) async {
        await MainActor.run { self.selectedName = name }
    }
}
```

- [ ] **Step 3: Wire PresetsClient into SettingsView**

In `mac/VoiceKeyboard/UI/Settings/SettingsView.swift`, find the `PipelineTab(...)` instantiation and add a `presets:` argument:

```swift
case .pipeline:
    PipelineTab(
        engine: composition.engine,
        sessions: LibVKBSessionsClient(engine: composition.engine),
        presets: LibVKBPresetsClient(engine: composition.engine)
    )
```

- [ ] **Step 4: Build the Mac app**

Run: `cd mac && make build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual smoke test**

Launch the app. With Developer mode on:
- Click Pipeline tab → segmented control shows Inspector + Editor.
- Click Editor → preset picker shows default/minimal/aggressive/paranoid.
- Pick paranoid → detail shows the threshold 0.70 on the TSE row.
- Click Reset → snaps back to default.
- Click "Save as…" → currently shows the placeholder sheet (Task 15 will make it real).

- [ ] **Step 6: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift \
        mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift \
        mac/VoiceKeyboard/UI/Settings/SettingsView.swift
git commit -m "feat(mac): PipelineTab segmented control + EditorView with preset picker"
```

---

### Task 15: Save-as preset sheet

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/SaveAsPresetSheet.swift`
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift` (replace placeholder sheet)

- [ ] **Step 1: Create the sheet**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/SaveAsPresetSheet.swift
import SwiftUI
import VoiceKeyboardCore

/// Modal naming sheet for saving the current pipeline configuration as
/// a user preset. Validates the name client-side; the C ABI rejects
/// invalid/reserved names with rc=5 if validation slips through.
struct SaveAsPresetSheet: View {
    let basePreset: Preset
    let presets: any PresetsClient
    let onSaved: () -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var saveError: String? = nil
    @State private var saving = false

    private var nameValid: Bool {
        let pattern = "^[a-z0-9_-]{1,40}$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    private var nameAvailable: Bool {
        let reserved: Set<String> = ["default", "minimal", "aggressive", "paranoid"]
        return !reserved.contains(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save current pipeline as preset")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Name (lowercase letters, digits, dash, underscore)", text: $name)
                    .textFieldStyle(.roundedBorder)
                if !name.isEmpty && !nameValid {
                    Text("Name must be 1–40 chars: a-z, 0-9, dash, underscore")
                        .font(.caption).foregroundStyle(.red)
                } else if !nameAvailable {
                    Text("\(name) is a reserved bundled preset name")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Description", text: $description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...3)
            }

            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("Save") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!nameValid || !nameAvailable || saving)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var p = basePreset
        // Build a new Preset reusing basePreset's stage shape but with the new name + desc.
        p = Preset(name: name, description: description.isEmpty ? "User preset" : description,
                   frameStages: basePreset.frameStages, chunkStages: basePreset.chunkStages,
                   transcribe: basePreset.transcribe, llm: basePreset.llm)
        do {
            try await presets.save(p)
            await MainActor.run { onSaved() }
        } catch {
            await MainActor.run { saveError = "Save failed: \(error)" }
        }
    }
}
```

- [ ] **Step 2: Wire the sheet into EditorView**

In `EditorView.swift`, replace the placeholder `Text("Save preset (Slice 2.5)")` with:

```swift
.sheet(isPresented: $saveSheetVisible) {
    if let p = selectedPreset {
        SaveAsPresetSheet(
            basePreset: p,
            presets: presets,
            onSaved: {
                saveSheetVisible = false
                Task { await refresh() }
            },
            onCancel: { saveSheetVisible = false }
        )
    }
}
```

- [ ] **Step 3: Build + smoke test**

Run: `cd mac && make build`
Expected: BUILD SUCCEEDED.

Launch: open Pipeline → Editor → pick a preset → "Save as…" → name `my-test`, save. Re-open Editor; `my-test` appears in the picker.

- [ ] **Step 4: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/SaveAsPresetSheet.swift \
        mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift
git commit -m "feat(mac): SaveAsPresetSheet for naming + persisting user presets"
```

---

## Phase F — Final integration

### Task 16: Final integration check + PR

- [ ] **Step 1: Run the full Go test suite**

```bash
cd core && go test ./... && go test -tags=whispercpp ./cmd/libvkb/...
```
Expected: PASS across all packages.

- [ ] **Step 2: Run the full Mac test suite**

```bash
cd mac && make test
```
Expected: PASS — including new PresetsClient tests (~74 tests total).

- [ ] **Step 3: Make a clean Debug build**

```bash
cd mac && make clean && make build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual smoke test against a real dictation**

- Toggle Developer mode on.
- Open Pipeline tab → segmented control shows Inspector + Editor.
- **Editor**: pick "paranoid" preset → confirm threshold 0.70 visible on TSE row. Click "Save as…" → name `office`, save. Confirm `office` appears in dropdown next reopen.
- **Inspector**: dictate something → confirm a new session shows up, with TSE row showing the latest similarity if available (formatted "tse_similarity": 0.62 in the manifest).
- Reset to default in Editor; dictate again with a normal voice; confirm a new session appears with similarity ≈ 1.0 (no gating).

- [ ] **Step 5: Push branch and open PR**

```bash
git push -u origin feat/pipeline-orchestration-slice-2
gh pr create --base main --title "feat: pipeline orchestration UI — slice 2 (presets)" \
  --body "Second slice of the Pipeline Orchestration UI per the design spec.

## Summary

- New \`presets\` Go package: schema + bundled JSON (default/minimal/aggressive/paranoid) + Resolve/Match + user save/load/delete with name validation
- TSE threshold gating: SpeakerGate loads encoder ONNX at construction, computes cosine similarity post-extract, gates output to zeros below threshold; threshold and similarity exposed in events + session manifest
- New C ABI exports: vkb_list_presets, vkb_get_preset, vkb_save_preset, vkb_delete_preset
- Mac: PresetsClient bridge + Pipeline tab segmented control (Inspector + Editor) + EditorView with preset picker + SaveAsPresetSheet

## Pre-Slice-2 hygiene (carryovers from Slice 1 PR)

- Recorder construction moved per-dictation (was per-configure) — each capture gets its own session folder
- Manifest stage list now built from pipe.FrameStages/ChunkStages walk (no more hardcoded names; non-default presets work)
- /tmp path duplications hoisted to SessionPaths helper
- Recorder.Close() after each capture so WAV data_bytes headers are patched
- Spec errata: SessionsClient documented as async

## Test plan

- [x] cd core && go test ./...
- [x] cd core && go test -tags=whispercpp ./cmd/libvkb/...
- [x] cd mac && make test
- [x] cd mac && make build
- [ ] Manual: toggle dev mode, dictate, switch presets, save user preset, verify TSE threshold gate behavior

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Self-Review

### Spec coverage check

| Spec section / requirement | Implementing task |
|---|---|
| Bundled preset JSON with default/minimal/aggressive/paranoid | Task 6 |
| `presets.Load()` (bundled + user merge) | Tasks 6, 9 |
| `Resolve` + `Match` | Tasks 7, 8 |
| User preset save/load/delete with name validation + reserved names | Task 9 |
| C ABI: vkb_list_presets / vkb_get_preset / vkb_save_preset / vkb_delete_preset | Task 10 |
| TSE threshold gating + similarity computation | Task 11 |
| TSE similarity in events + session manifest | Task 12 |
| Mac PresetsClient bridge | Task 13 |
| PipelineTab segmented control (Inspector + Editor) | Task 14 |
| Editor view with preset picker, Save/Reset/Save-as | Tasks 14, 15 |
| Per-preset detail showing TSE threshold | Task 14 |
| Pre-Slice-2 hygiene: per-dictation recorder | Task 4 |
| Pre-Slice-2 hygiene: manifest from pipe walk | Task 3 |
| Pre-Slice-2 hygiene: SessionPaths helper | Task 2 |
| Pre-Slice-2 hygiene: Recorder.Close() after capture | Task 5 |
| Pre-Slice-2 hygiene: spec errata | Task 1 |

All spec requirements for Slice 2 + carryovers from Slice 1 mapped to tasks. Drag-and-drop pipeline editor (Slice 3), A/B compare (Slice 4), CLI parity (Slice 5) all deliberately deferred.

### Placeholder scan

Reviewed plan. No "TBD" / "TODO" steps. Two TODO comments in code (TSE recent-similarity readout simplified to manifest-driven; full live dial deferred to Slice 3) are documented as Slice 3 follow-ups.

### Type consistency

- Go `Preset` / `StageSpec` / `TranscribeSpec` / `LLMSpec` defined in Task 6, used consistently in 7/8/9/10.
- Swift `Preset` / `StageSpec` / `LLMSpec` mirror Go via snake_case CodingKeys.
- `PresetsClient` protocol async signatures match `LibVKBPresetsClient` impl (consistent with Slice 1's SessionsClient pattern).
- `EngineSecrets` struct in Task 7 used by Resolve; not exposed across the C ABI (caller passes individual fields via existing EngineConfig).

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-02-pipeline-orchestration-slice-2-presets.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

Which approach?
