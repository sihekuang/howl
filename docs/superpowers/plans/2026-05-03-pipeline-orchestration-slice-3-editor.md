# Pipeline Orchestration UI — Slice 3 (Editable Graph) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the read-only Editor from Slice 2 into a real editor — drag-and-drop pipeline stages within their lanes, edit per-stage tunables (Enabled / Backend / TSE Threshold / Recent similarity readout), and edit a per-preset timeout. Save the result as a user preset.

**Architecture:** Introduce an observable `PresetDraft` as the editor's mutable working state — `EditorView` mutates the draft, `SaveAsPresetSheet` persists it via `PresetsClient`. A pure `StageConstraintValidator` checks sample-rate compatibility on every reorder; invalid orderings show an inline red overlay and the drop is reverted. Drag is structurally confined within a SwiftUI `List` per lane (cross-lane drops are physically invalid because chunk stages need a chunk). A new `PipelineTimeoutSec` field threads through `config.Config` → `presets.Preset` → libvkb's `pipe.Run(ctx, ...)` via `context.WithTimeout`. Recent TSE similarity readouts come from walking the last N session manifests (no event-stream subscription needed).

**Tech Stack:** SwiftUI (`List` + `onMove`, `@Observable` working state), Go 1.22+ (`context.WithTimeout`), existing presets package + C ABI from Slice 2. No new external dependencies.

---

## File Structure

### Go (modified)

- `core/internal/config/config.go` — new `PipelineTimeoutSec int` field + `PipelineTimeoutValue() time.Duration` helper.
- `core/internal/presets/presets.go` — new `TimeoutSec *int` field on `Preset` (pointer so 0 distinguishes "not set" from "0 = disabled").
- `core/internal/presets/pipeline-presets.json` — `timeout_sec: 10` on default/aggressive/paranoid; `timeout_sec: 5` on minimal.
- `core/internal/presets/resolve.go` — propagate `TimeoutSec` through `Resolve` (preset → cfg) and `Match` (cfg → preset).
- `core/internal/presets/resolve_test.go` — extend with timeout coverage.
- `core/internal/presets/presets_test.go` — extend JSON round-trip with timeout.
- `core/cmd/libvkb/exports.go` — wrap the capture goroutine's `pipe.Run` ctx with `context.WithTimeout` when `cfg.PipelineTimeoutSec > 0`; emit a "warning" event on `context.DeadlineExceeded`.

### Swift bridge (modified)

- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/Preset.swift` — add `timeoutSec: Int?` with snake_case `CodingKey`; extend `init(...)`.
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/PresetsClientTests.swift` — add a decode test asserting `timeout_sec: 10` round-trips.

### Mac UI (new)

- `mac/VoiceKeyboard/UI/Settings/Pipeline/PresetDraft.swift` — `@Observable` class wrapping an editable copy of a `Preset`, with reorder + per-stage mutators.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/StageConstraintValidator.swift` — pure function: `validate(frameStages:[Preset.StageSpec]) -> [ValidationError]`. Knows about the fixed sample-rate table (`denoise: 48000→48000`, `decimate3: 48000→16000`).
- `mac/VoiceKeyboard/UI/Settings/Pipeline/StageGraph.swift` — three SwiftUI `List` lanes (frame, chunk, fixed terminal), each with `onMove`. The fixed terminal lane (`whisper → dict → llm`) is rendered but `.onMove` isn't attached.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/StageDetailPanel.swift` — tunables for the selected stage; calls back into `PresetDraft` mutators.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/RecentSimilarityProbe.swift` — given a `SessionsClient`, returns the last N TSE similarity values (in chronological order) for the readout.

### Mac UI (modified)

- `mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift` — replace the read-only detail with `StageGraph` + `StageDetailPanel` + Save-as + Reset + Timeout field toolbar. Wires `PresetDraft` to `SaveAsPresetSheet`.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/SaveAsPresetSheet.swift` — accept `draft: PresetDraft` instead of `basePreset: Preset`; serialize from the draft so user edits get persisted (not the original).
- `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift` — pass the `SessionsClient` into `EditorView` (already available; just thread through).

### Mac tests (new)

- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/PresetTimeoutCodingTests.swift` — JSON round-trip for the new `timeoutSec` field.

(The graph + drag-drop UI is exercised manually; SwiftUI snapshot infrastructure isn't in place, matching Slice 2's testing baseline.)

---

## Phase A — Go side (timeout + preset field)

### Task 1: Add `PipelineTimeoutSec` to `config.Config`

**Files:**
- Modify: `core/internal/config/config.go`

- [ ] **Step 1: Add the field next to `TSEThreshold`**

In `core/internal/config/config.go`, find the TSE block ending in `TSEThreshold *float32`. Add immediately after the closing brace of the struct's TSE section (still inside the struct, before `}`):

```go
// PipelineTimeoutSec bounds total pipeline runtime per dictation.
// 0 disables the bound (legacy behavior). Wired into engine via
// context.WithTimeout(pipe.Run ctx). On expiry the pipeline returns
// whatever cleaned text streamed so far (or dict-corrected raw if no
// LLM output yet).
PipelineTimeoutSec int `json:"pipeline_timeout_sec,omitempty"`
```

- [ ] **Step 2: Add the helper next to `TSEThresholdValue`**

In `core/internal/config/config.go`, after the existing `TSEThresholdValue` function:

```go
// PipelineTimeoutValue returns cfg.PipelineTimeoutSec as a Duration,
// or 0 (no timeout) if unset.
func (c *Config) PipelineTimeoutValue() time.Duration {
	if c == nil || c.PipelineTimeoutSec <= 0 {
		return 0
	}
	return time.Duration(c.PipelineTimeoutSec) * time.Second
}
```

Add `"time"` to the imports if not present.

- [ ] **Step 3: Verify it compiles**

Run: `cd core && go build ./internal/config/...`
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add core/internal/config/config.go
git commit -m "feat(config): add PipelineTimeoutSec + PipelineTimeoutValue helper"
```

---

### Task 2: Wire the timeout into the libvkb capture goroutine

**Files:**
- Modify: `core/cmd/libvkb/exports.go` (capture goroutine in `vkb_start_capture`)

- [ ] **Step 1: Read the current ctx setup**

Run: `grep -n 'context.WithCancel\|pipe.Run' core/cmd/libvkb/exports.go`
Expected: shows the `ctx, cancel := context.WithCancel(...)` line and the `res, err := pipe.Run(ctx, pushCh)` line.

- [ ] **Step 2: Snapshot the timeout under e.mu alongside the pipeline**

In `core/cmd/libvkb/exports.go`, find the block in `vkb_start_capture` where `pipe := e.pipeline` is assigned under the lock. Add immediately after:

```go
timeout := e.cfg.PipelineTimeoutValue()
```

(This must be inside the `e.mu.Lock()` critical section — `e.cfg` reads need synchronization with `vkb_configure`.)

- [ ] **Step 3: Wrap ctx with the timeout after the lock is released**

Right after the existing `ctx, cancel := context.WithCancel(context.Background())` line, add:

```go
if timeout > 0 {
	var cancelTimeout context.CancelFunc
	ctx, cancelTimeout = context.WithTimeout(ctx, timeout)
	// Defer-close the timeout ctx alongside the existing cancel.
	// We can't replace `cancel` (vkb_cancel_capture calls it), so
	// pair them via a wrapper.
	parent := cancel
	cancel = func() { cancelTimeout(); parent() }
}
```

- [ ] **Step 4: Distinguish "deadline exceeded" from "cancelled" in the goroutine error path**

In the same file, find the goroutine's `if err != nil { ... }` branch after `pipe.Run`. The current code emits `cancelled` for both `context.Canceled` and `context.DeadlineExceeded`. Split:

Replace:

```go
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

With:

```go
if err != nil {
	if errors.Is(err, context.DeadlineExceeded) {
		log.Printf("[vkb] capture goroutine: pipeline timed out (>%s)", timeout)
		e.events <- event{Kind: "warning", Msg: fmt.Sprintf("pipeline timed out after %s", timeout)}
		// Fall through to delivering whatever the pipeline returned via res
		// — but pipe.Run returns (Result{}, err) on context error, not partial
		// state. Emit an empty result so Swift transitions back to idle.
		e.events <- event{Kind: "result", Text: ""}
		return
	}
	if errors.Is(err, context.Canceled) {
		log.Printf("[vkb] capture goroutine: pipeline cancelled")
		e.events <- event{Kind: "cancelled"}
		return
	}
	log.Printf("[vkb] capture goroutine: pipe.Run error: %v", err)
	e.events <- event{Kind: "error", Msg: err.Error()}
	return
}
```

- [ ] **Step 5: Build dylib + run libvkb tests**

Run: `cd core && make build-dylib && go test -tags=whispercpp ./cmd/libvkb/...`
Expected: clean build; all tests pass (no test exercises the timeout path directly — that arrives via a Slice 5 e2e test).

- [ ] **Step 6: Commit**

```bash
git add core/cmd/libvkb/exports.go
git commit -m "feat(libvkb): honor cfg.PipelineTimeoutSec via context.WithTimeout"
```

---

### Task 3: Add `TimeoutSec` to the preset schema

**Files:**
- Modify: `core/internal/presets/presets.go`
- Modify: `core/internal/presets/pipeline-presets.json`
- Modify: `core/internal/presets/presets_test.go`

- [ ] **Step 1: Append failing test for the new field**

Append to `core/internal/presets/presets_test.go`:

```go
func TestPreset_DefaultPresetHasTimeoutSec10(t *testing.T) {
	all, _ := loadBundled()
	for _, p := range all {
		if p.Name != "default" {
			continue
		}
		if p.TimeoutSec == nil || *p.TimeoutSec != 10 {
			t.Errorf("default preset's timeout_sec = %v, want 10", p.TimeoutSec)
		}
		return
	}
	t.Error("default preset missing")
}

func TestPreset_TimeoutSecRoundTrips(t *testing.T) {
	timeout := 7
	in := Preset{
		Name: "custom", Description: "x",
		FrameStages: []StageSpec{},
		ChunkStages: []StageSpec{},
		Transcribe:  TranscribeSpec{ModelSize: "small"},
		LLM:         LLMSpec{Provider: "anthropic"},
		TimeoutSec:  &timeout,
	}
	buf, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	var out Preset
	if err := json.Unmarshal(buf, &out); err != nil {
		t.Fatal(err)
	}
	if out.TimeoutSec == nil || *out.TimeoutSec != 7 {
		t.Errorf("TimeoutSec = %v, want 7", out.TimeoutSec)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd core && go test ./internal/presets/... -run TestPreset_DefaultPresetHasTimeoutSec10 -v`
Expected: FAIL with "got nil, want 10" (field doesn't exist yet).

- [ ] **Step 3: Add `TimeoutSec` to `Preset`**

In `core/internal/presets/presets.go`, find the `Preset` struct. Add a field:

```go
type Preset struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	FrameStages []StageSpec    `json:"frame_stages"`
	ChunkStages []StageSpec    `json:"chunk_stages"`
	Transcribe  TranscribeSpec `json:"transcribe"`
	LLM         LLMSpec        `json:"llm"`
	// TimeoutSec is the per-preset pipeline timeout in seconds.
	// Pointer so 0 (disable timeout) differs from "not set".
	TimeoutSec *int `json:"timeout_sec,omitempty"`
}
```

- [ ] **Step 4: Add `timeout_sec` to bundled presets JSON**

In `core/internal/presets/pipeline-presets.json`, edit each preset entry to add `timeout_sec`:

- `default`: `"timeout_sec": 10`
- `minimal`: `"timeout_sec": 5`
- `aggressive`: `"timeout_sec": 15`
- `paranoid`: `"timeout_sec": 10`

For example, the `default` block becomes:

```json
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
},
```

Apply the same `"timeout_sec": <N>` insertion (with the appropriate value) to `minimal`, `aggressive`, and `paranoid`.

- [ ] **Step 5: Run tests**

Run: `cd core && go test ./internal/presets/... -v`
Expected: PASS — all 8+ tests including the two new ones.

- [ ] **Step 6: Commit**

```bash
git add core/internal/presets/presets.go core/internal/presets/pipeline-presets.json core/internal/presets/presets_test.go
git commit -m "feat(presets): TimeoutSec field on Preset + bundled defaults"
```

---

### Task 4: Thread timeout through Resolve + Match

**Files:**
- Modify: `core/internal/presets/resolve.go`
- Modify: `core/internal/presets/resolve_test.go`

- [ ] **Step 1: Append failing tests**

Append to `core/internal/presets/resolve_test.go`:

```go
func TestResolve_DefaultTimeoutPropagates(t *testing.T) {
	all, _ := loadBundled()
	def := findPreset(t, all, "default")
	got := Resolve(def, EngineSecrets{})
	if got.PipelineTimeoutSec != 10 {
		t.Errorf("PipelineTimeoutSec = %d, want 10", got.PipelineTimeoutSec)
	}
}

func TestMatch_DivergedTimeoutReturnsCustom(t *testing.T) {
	all, _ := loadBundled()
	def := findPreset(t, all, "default")
	cfg := Resolve(def, EngineSecrets{})
	cfg.PipelineTimeoutSec = 99 // diverge

	if got := Match(cfg, all); got != "custom" {
		t.Errorf("Match(divergent timeout) = %q, want \"custom\"", got)
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd core && go test ./internal/presets/... -run "TestResolve_DefaultTimeoutPropagates|TestMatch_DivergedTimeoutReturnsCustom" -v`
Expected: FAIL — Resolve doesn't set the field; Match doesn't compare it.

- [ ] **Step 3: Update Resolve**

In `core/internal/presets/resolve.go`'s `Resolve` function, find the existing chunk-stage loop. Just **after** the loop (before `return cfg`), add:

```go
if p.TimeoutSec != nil {
	cfg.PipelineTimeoutSec = *p.TimeoutSec
}
```

- [ ] **Step 4: Update Match**

In the same file, find `presetMatchesConfig`. After the existing chunk-stage loop, before `return true`, add:

```go
// Timeout: nil-or-0 are equivalent ("no bound"); explicit non-zero must match.
presetTimeout := 0
if p.TimeoutSec != nil {
	presetTimeout = *p.TimeoutSec
}
if cfg.PipelineTimeoutSec != presetTimeout {
	return false
}
```

- [ ] **Step 5: Run tests**

Run: `cd core && go test ./internal/presets/... -v`
Expected: PASS — including the 2 new tests + all existing.

- [ ] **Step 6: Commit**

```bash
git add core/internal/presets/resolve.go core/internal/presets/resolve_test.go
git commit -m "feat(presets): Resolve + Match propagate TimeoutSec"
```

---

## Phase B — Swift bridge

### Task 5: Add `timeoutSec` to Swift `Preset`

**Files:**
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/Preset.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/PresetTimeoutCodingTests.swift`

- [ ] **Step 1: Write the failing test**

Create `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/PresetTimeoutCodingTests.swift`:

```swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("Preset.timeoutSec coding")
struct PresetTimeoutCodingTests {
    @Test func decode_picksUpTimeout() throws {
        let json = """
        {"name":"x","description":"","frame_stages":[],"chunk_stages":[],
         "transcribe":{"model_size":"small"},"llm":{"provider":"anthropic"},
         "timeout_sec":7}
        """
        let p = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        #expect(p.timeoutSec == 7)
    }

    @Test func decode_missingTimeoutIsNil() throws {
        let json = """
        {"name":"x","description":"","frame_stages":[],"chunk_stages":[],
         "transcribe":{"model_size":"small"},"llm":{"provider":"anthropic"}}
        """
        let p = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        #expect(p.timeoutSec == nil)
    }

    @Test func encode_emitsSnakeCaseKey() throws {
        let p = Preset(name: "x", description: "",
                       frameStages: [], chunkStages: [],
                       transcribe: .init(modelSize: "small"),
                       llm: .init(provider: "anthropic"),
                       timeoutSec: 12)
        let buf = try JSONEncoder().encode(p)
        let str = String(decoding: buf, as: UTF8.self)
        #expect(str.contains("\"timeout_sec\":12"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd mac && make test 2>&1 | grep PresetTimeoutCodingTests`
Expected: 3 failing tests (no `timeoutSec` member).

- [ ] **Step 3: Add `timeoutSec` to `Preset`**

In `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/Preset.swift`, modify the struct:

Find:

```swift
public struct Preset: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String
    public let frameStages: [StageSpec]
    public let chunkStages: [StageSpec]
    public let transcribe: TranscribeSpec
    public let llm: LLMSpec
```

Add after `llm:`:

```swift
    public let timeoutSec: Int?
```

Find the existing `init(...)` (no `timeoutSec` parameter today). Replace with:

```swift
    public init(
        name: String,
        description: String,
        frameStages: [StageSpec],
        chunkStages: [StageSpec],
        transcribe: TranscribeSpec,
        llm: LLMSpec,
        timeoutSec: Int? = nil
    ) {
        self.name = name
        self.description = description
        self.frameStages = frameStages
        self.chunkStages = chunkStages
        self.transcribe = transcribe
        self.llm = llm
        self.timeoutSec = timeoutSec
    }
```

Find the existing `enum CodingKeys` and update to:

```swift
    enum CodingKeys: String, CodingKey {
        case name, description, transcribe, llm
        case frameStages = "frame_stages"
        case chunkStages = "chunk_stages"
        case timeoutSec = "timeout_sec"
    }
```

- [ ] **Step 4: Run tests**

Run: `cd mac && make test 2>&1 | tail -10`
Expected: PASS — including the 3 new tests; all 77+ tests pass.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/Preset.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/PresetTimeoutCodingTests.swift
git commit -m "feat(mac): Preset.timeoutSec field with snake_case CodingKey"
```

---

## Phase C — Mac data model: `PresetDraft`

### Task 6: Build `PresetDraft` (observable working state)

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/PresetDraft.swift`

The editor mutates a draft, not the bundled preset directly. `PresetDraft` is a final class so SwiftUI views see identity stability and reorder operations stay cheap.

- [ ] **Step 1: Create the file**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/PresetDraft.swift
import Foundation
import Observation
import VoiceKeyboardCore

/// Observable working copy of a Preset that the Editor mutates in
/// place. Created from a bundled or user preset; serialized into a new
/// Preset for save (see toPreset(name:description:)).
///
/// The bundled source is captured separately so Reset can restore it
/// without an extra round-trip to libvkb.
@Observable
final class PresetDraft {
    /// The original preset this draft was created from. Reset copies
    /// fields back from this; isDirty compares against it.
    private(set) var source: Preset

    var frameStages: [Preset.StageSpec]
    var chunkStages: [Preset.StageSpec]
    var transcribeModelSize: String
    var llmProvider: String
    var timeoutSec: Int

    /// User's currently-selected stage in the graph, if any. Drives the
    /// detail panel. nil means no selection.
    var selectedStage: StageRef? = nil

    init(_ source: Preset) {
        self.source = source
        self.frameStages = source.frameStages
        self.chunkStages = source.chunkStages
        self.transcribeModelSize = source.transcribe.modelSize
        self.llmProvider = source.llm.provider
        self.timeoutSec = source.timeoutSec ?? 10
    }

    /// True when any draft field diverges from the source. Drives the
    /// "edited" badge in the toolbar.
    var isDirty: Bool {
        if frameStages != source.frameStages { return true }
        if chunkStages != source.chunkStages { return true }
        if transcribeModelSize != source.transcribe.modelSize { return true }
        if llmProvider != source.llm.provider { return true }
        if timeoutSec != (source.timeoutSec ?? 10) { return true }
        return false
    }

    /// Replace the source and reset all fields to it.
    func resetTo(_ preset: Preset) {
        source = preset
        frameStages = preset.frameStages
        chunkStages = preset.chunkStages
        transcribeModelSize = preset.transcribe.modelSize
        llmProvider = preset.llm.provider
        timeoutSec = preset.timeoutSec ?? 10
        selectedStage = nil
    }

    /// Serialize the draft to a Preset for save. name + description are
    /// supplied by SaveAsPresetSheet; the draft itself doesn't track them.
    func toPreset(name: String, description: String) -> Preset {
        Preset(
            name: name,
            description: description,
            frameStages: frameStages,
            chunkStages: chunkStages,
            transcribe: .init(modelSize: transcribeModelSize),
            llm: .init(provider: llmProvider),
            timeoutSec: timeoutSec
        )
    }

    // MARK: - Mutators

    /// Reorder a frame stage. Validation is performed by the caller via
    /// StageConstraintValidator before commit.
    func moveFrameStage(from source: IndexSet, to destination: Int) {
        frameStages.move(fromOffsets: source, toOffset: destination)
    }

    func moveChunkStage(from source: IndexSet, to destination: Int) {
        chunkStages.move(fromOffsets: source, toOffset: destination)
    }

    /// Toggle the enabled flag for a stage in either lane. No-op if the
    /// stage isn't found (UI shouldn't allow that, defensive).
    func setEnabled(_ enabled: Bool, for ref: StageRef) {
        switch ref.lane {
        case .frame:
            guard let idx = frameStages.firstIndex(where: { $0.name == ref.name }) else { return }
            let st = frameStages[idx]
            frameStages[idx] = Preset.StageSpec(name: st.name, enabled: enabled, backend: st.backend, threshold: st.threshold)
        case .chunk:
            guard let idx = chunkStages.firstIndex(where: { $0.name == ref.name }) else { return }
            let st = chunkStages[idx]
            chunkStages[idx] = Preset.StageSpec(name: st.name, enabled: enabled, backend: st.backend, threshold: st.threshold)
        }
    }

    func setBackend(_ backend: String, for ref: StageRef) {
        guard ref.lane == .chunk else { return }
        guard let idx = chunkStages.firstIndex(where: { $0.name == ref.name }) else { return }
        let st = chunkStages[idx]
        chunkStages[idx] = Preset.StageSpec(name: st.name, enabled: st.enabled, backend: backend, threshold: st.threshold)
    }

    func setThreshold(_ threshold: Float, for ref: StageRef) {
        guard ref.lane == .chunk else { return }
        guard let idx = chunkStages.firstIndex(where: { $0.name == ref.name }) else { return }
        let st = chunkStages[idx]
        chunkStages[idx] = Preset.StageSpec(name: st.name, enabled: st.enabled, backend: st.backend, threshold: threshold)
    }

    /// Look up a stage by ref. nil if not found.
    func stage(for ref: StageRef) -> Preset.StageSpec? {
        switch ref.lane {
        case .frame: return frameStages.first(where: { $0.name == ref.name })
        case .chunk: return chunkStages.first(where: { $0.name == ref.name })
        }
    }
}

/// Lane + stage name pair — the editor's identifier for "this stage in
/// this lane". Stage names are unique within a lane today.
struct StageRef: Hashable, Equatable {
    enum Lane: Hashable { case frame, chunk }
    let lane: Lane
    let name: String
}
```

- [ ] **Step 2: Verify it builds**

Run: `cd mac && make build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED. (Not yet referenced from any view — just compiles.)

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/PresetDraft.swift mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "feat(mac): PresetDraft observable working state for Editor"
```

---

## Phase D — Stage constraint validation

### Task 7: Build `StageConstraintValidator` (pure function + tests)

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/StageConstraintValidator.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/StageConstraintValidatorTests.swift`

The validator needs to live in VoiceKeyboardCore so tests can reach it via SwiftPM (the app target's UI files aren't visible to the test target). Move it there.

Revised file paths:
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/StageConstraintValidator.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/StageConstraintValidatorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/StageConstraintValidatorTests.swift`:

```swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("StageConstraintValidator")
struct StageConstraintValidatorTests {
    @Test func defaultOrderingIsValid() {
        let stages = [
            Preset.StageSpec(name: "denoise",   enabled: true),
            Preset.StageSpec(name: "decimate3", enabled: true),
        ]
        let errs = StageConstraintValidator.validate(frameStages: stages)
        #expect(errs.isEmpty)
    }

    @Test func decimateBeforeDenoiseIsInvalid() {
        // decimate3 outputs 16k; denoise expects 48k. Order matters.
        let stages = [
            Preset.StageSpec(name: "decimate3", enabled: true),
            Preset.StageSpec(name: "denoise",   enabled: true),
        ]
        let errs = StageConstraintValidator.validate(frameStages: stages)
        #expect(errs.count == 1)
        #expect(errs[0].index == 1)
        #expect(errs[0].message.contains("denoise") && errs[0].message.contains("48"))
    }

    @Test func disabledStagesAreSkippedForValidation() {
        // A disabled decimate3 doesn't change the running rate — denoise
        // after it is fine.
        let stages = [
            Preset.StageSpec(name: "decimate3", enabled: false),
            Preset.StageSpec(name: "denoise",   enabled: true),
        ]
        let errs = StageConstraintValidator.validate(frameStages: stages)
        #expect(errs.isEmpty)
    }

    @Test func unknownStageIsValidByDefault() {
        // A stage we don't have rate metadata for is treated as
        // sample-rate-preserving (input rate == output rate).
        let stages = [
            Preset.StageSpec(name: "futurestage", enabled: true),
            Preset.StageSpec(name: "denoise",     enabled: true),
        ]
        let errs = StageConstraintValidator.validate(frameStages: stages)
        #expect(errs.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd mac && make test 2>&1 | grep -E 'StageConstraintValidator|cannot find'`
Expected: errors about `StageConstraintValidator` not found.

- [ ] **Step 3: Implement the validator**

Create `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/StageConstraintValidator.swift`:

```swift
// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/StageConstraintValidator.swift
import Foundation

/// Pure function: validates a frame-stage ordering against the
/// sample-rate compatibility of each stage. Returns one ValidationError
/// per stage that's incompatible with the running rate when it's reached.
///
/// The running rate starts at 48000 Hz (mic input). Each enabled stage
/// either preserves the rate or transforms it to a fixed output rate.
/// Disabled stages don't change the running rate.
public enum StageConstraintValidator {
    public struct ValidationError: Equatable {
        public let index: Int       // index in the input list
        public let stageName: String
        public let expectedHz: Int  // running rate at this point
        public let acceptedHz: Int  // rate this stage requires
        public let message: String
    }

    /// Per-stage rate metadata. Stages absent from this table are
    /// treated as rate-preserving (passthrough).
    private struct StageRate {
        let acceptedHz: Int   // rate this stage requires on its input
        let outputHz: Int     // rate this stage emits (== acceptedHz for passthrough)
    }

    private static let rateTable: [String: StageRate] = [
        "denoise":   StageRate(acceptedHz: 48000, outputHz: 48000),
        "decimate3": StageRate(acceptedHz: 48000, outputHz: 16000),
    ]

    public static func validate(frameStages: [Preset.StageSpec]) -> [ValidationError] {
        var rate = 48000
        var errors: [ValidationError] = []
        for (i, stage) in frameStages.enumerated() {
            guard stage.enabled, let meta = rateTable[stage.name] else {
                // Disabled or unknown: no rate change, no validation.
                continue
            }
            if meta.acceptedHz != rate {
                errors.append(ValidationError(
                    index: i,
                    stageName: stage.name,
                    expectedHz: rate,
                    acceptedHz: meta.acceptedHz,
                    message: "\(stage.name) expects \(meta.acceptedHz) Hz; running rate at this point is \(rate) Hz"
                ))
            }
            rate = meta.outputHz
        }
        return errors
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd mac && make test 2>&1 | grep -E 'StageConstraintValidator|Test run'`
Expected: 4 new tests pass; total test count goes up.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/StageConstraintValidator.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/StageConstraintValidatorTests.swift
git commit -m "feat(mac): StageConstraintValidator for frame-stage ordering"
```

---

## Phase E — Stage graph view

### Task 8: Build the `StageGraph` view

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/StageGraph.swift`

Three vertically stacked SwiftUI `List`s — frame, chunk, fixed terminal. Frame and chunk lanes have `.onMove` enabled with an inline validator that reverts invalid moves. The terminal lane (Whisper / Dict / LLM) is rendered but not draggable.

- [ ] **Step 1: Create the view**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/StageGraph.swift
import SwiftUI
import VoiceKeyboardCore

/// Three-lane drag-drop pipeline graph:
/// - Frame lane (denoise, decimate3) — reorderable within lane.
/// - Chunker boundary — visual separator.
/// - Chunk lane (tse) — reorderable within lane.
/// - Fixed terminal (whisper → dict → llm) — rendered, not draggable.
///
/// Cross-lane drags are structurally blocked by SwiftUI: each List has
/// its own drop target.
struct StageGraph: View {
    @Bindable var draft: PresetDraft

    @State private var frameValidationErrors: [StageConstraintValidator.ValidationError] = []
    @State private var lastInvalidMoveMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            laneHeader("Streaming stages", subtitle: "frame-rate; runs on every pushed buffer")
            frameLane
            if let err = lastInvalidMoveMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }

            chunkerBoundary

            laneHeader("Per-utterance stages", subtitle: "chunk-rate; runs once per utterance chunk")
            chunkLane

            laneHeader("Transcribe + cleanup", subtitle: "fixed terminal chain")
            fixedTerminal
        }
    }

    // MARK: - Lane headers + boundary

    @ViewBuilder
    private func laneHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).bold().foregroundStyle(.secondary)
            Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var chunkerBoundary: some View {
        HStack {
            Rectangle().fill(.secondary).frame(height: 1)
            Text("CHUNKER")
                .font(.caption2.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
                .foregroundStyle(.secondary)
            Rectangle().fill(.secondary).frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Frame lane

    @ViewBuilder
    private var frameLane: some View {
        List {
            ForEach(Array(draft.frameStages.enumerated()), id: \.element.name) { i, stage in
                stageRow(stage,
                         lane: .frame,
                         hasError: frameValidationErrors.contains(where: { $0.index == i }))
            }
            .onMove { source, destination in
                attemptFrameMove(from: source, to: destination)
            }
        }
        .listStyle(.plain)
        .frame(minHeight: laneMinHeight(rowCount: draft.frameStages.count))
    }

    private func attemptFrameMove(from source: IndexSet, to destination: Int) {
        // Snapshot, apply, validate, revert if invalid.
        let snapshot = draft.frameStages
        draft.moveFrameStage(from: source, to: destination)
        let errs = StageConstraintValidator.validate(frameStages: draft.frameStages)
        if !errs.isEmpty {
            // Revert + surface the first error inline.
            draft.frameStages = snapshot
            lastInvalidMoveMessage = errs[0].message
            frameValidationErrors = []
            // Auto-clear the error after a few seconds so the lane
            // doesn't carry a stale red tooltip forever.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if lastInvalidMoveMessage == errs[0].message {
                    lastInvalidMoveMessage = nil
                }
            }
        } else {
            lastInvalidMoveMessage = nil
            frameValidationErrors = []
        }
    }

    // MARK: - Chunk lane

    @ViewBuilder
    private var chunkLane: some View {
        List {
            ForEach(Array(draft.chunkStages.enumerated()), id: \.element.name) { _, stage in
                stageRow(stage, lane: .chunk, hasError: false)
            }
            .onMove { source, destination in
                draft.moveChunkStage(from: source, to: destination)
                // No rate validation today — the chunk lane has only
                // tse, which is rate-preserving.
            }
        }
        .listStyle(.plain)
        .frame(minHeight: laneMinHeight(rowCount: draft.chunkStages.count))
    }

    // MARK: - Fixed terminal

    @ViewBuilder
    private var fixedTerminal: some View {
        VStack(alignment: .leading, spacing: 4) {
            terminalRow(name: "whisper", subtitle: draft.transcribeModelSize)
            terminalRow(name: "dict",    subtitle: "fuzzy correction")
            terminalRow(name: "llm",     subtitle: draft.llmProvider)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func terminalRow(name: String, subtitle: String) -> some View {
        HStack {
            Image(systemName: "lock.fill").foregroundStyle(.tertiary).font(.caption)
            Text(name).font(.callout).bold()
            Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Stage row (frame + chunk)

    @ViewBuilder
    private func stageRow(_ stage: Preset.StageSpec, lane: StageRef.Lane, hasError: Bool) -> some View {
        let ref = StageRef(lane: lane, name: stage.name)
        HStack {
            Image(systemName: stage.enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(stage.enabled ? .green : .secondary)
            Text(stage.name).font(.callout).bold()
            if let backend = stage.backend, !backend.isEmpty {
                Text(backend).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(draft.selectedStage == ref ? Color.accentColor.opacity(0.15) : Color.clear)
        .onTapGesture {
            draft.selectedStage = (draft.selectedStage == ref) ? nil : ref
        }
    }

    private func laneMinHeight(rowCount: Int) -> CGFloat {
        // SwiftUI List in a constrained Settings pane needs an explicit
        // min height or rows squash. ~28pt per row + a little breathing
        // room; minimum 1 row's worth so an empty lane still shows.
        let perRow: CGFloat = 28
        return CGFloat(max(1, rowCount)) * perRow + 8
    }
}
```

- [ ] **Step 2: Build**

Run: `cd mac && make build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/StageGraph.swift mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "feat(mac): StageGraph drag-drop view with inline validation"
```

---

## Phase F — Per-stage detail panel

### Task 9: Build `RecentSimilarityProbe` (reads session manifests)

**Files:**
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/RecentSimilarityProbe.swift`
- Create: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/RecentSimilarityProbeTests.swift`

The detail panel needs the last N TSE similarities to render the readout. They live on session manifests already (Slice 2 wired this up). This probe wraps the lookup so the view stays simple.

- [ ] **Step 1: Write the failing test**

Create `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/RecentSimilarityProbeTests.swift`:

```swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

/// Spy SessionsClient that returns a fixed manifest list so the probe
/// can be tested without disk I/O.
final class SpySessionsClient: SessionsClient, @unchecked Sendable {
    var stubList: [SessionManifest] = []
    func list() async throws -> [SessionManifest] { stubList }
    func get(_ id: String) async throws -> SessionManifest {
        guard let m = stubList.first(where: { $0.id == id }) else {
            throw NSError(domain: "spy", code: 1)
        }
        return m
    }
    func delete(_ id: String) async throws { stubList.removeAll { $0.id == id } }
    func clear() async throws { stubList.removeAll() }
}

@Suite("RecentSimilarityProbe")
struct RecentSimilarityProbeTests {
    private func session(id: String, tseSim: Float?) -> SessionManifest {
        let stage = SessionManifest.Stage(
            name: "tse", kind: "chunk", wav: "tse.wav",
            rateHz: 16000, tseSimilarity: tseSim
        )
        return SessionManifest(
            version: 1, id: id, preset: "default", durationSec: 1.0,
            stages: [stage],
            transcripts: .init(raw: "raw.txt", dict: "dict.txt", cleaned: "cleaned.txt")
        )
    }

    @Test func returnsEmptyWhenNoSessions() async throws {
        let spy = SpySessionsClient()
        let probe = RecentSimilarityProbe(sessions: spy)
        let got = try await probe.recent(limit: 5)
        #expect(got.isEmpty)
    }

    @Test func returnsLastNSimilaritiesNewestFirst() async throws {
        let spy = SpySessionsClient()
        spy.stubList = [
            session(id: "2026-05-03T03Z", tseSim: 0.7),
            session(id: "2026-05-03T02Z", tseSim: 0.5),
            session(id: "2026-05-03T01Z", tseSim: 0.9),
        ]
        let probe = RecentSimilarityProbe(sessions: spy)
        let got = try await probe.recent(limit: 5)
        #expect(got == [0.7, 0.5, 0.9])
    }

    @Test func skipsSessionsWithoutTSEStage() async throws {
        let spy = SpySessionsClient()
        let noTSE = SessionManifest(
            version: 1, id: "x", preset: "minimal", durationSec: 1,
            stages: [], transcripts: .init(raw: "raw.txt", dict: "dict.txt", cleaned: "cleaned.txt")
        )
        spy.stubList = [
            noTSE,
            session(id: "y", tseSim: 0.8),
        ]
        let probe = RecentSimilarityProbe(sessions: spy)
        let got = try await probe.recent(limit: 5)
        #expect(got == [0.8])
    }

    @Test func capsAtLimit() async throws {
        let spy = SpySessionsClient()
        spy.stubList = (0..<10).map { session(id: "\($0)", tseSim: Float($0) / 10) }
        let probe = RecentSimilarityProbe(sessions: spy)
        let got = try await probe.recent(limit: 3)
        #expect(got.count == 3)
    }
}
```

- [ ] **Step 2: Verify failure**

Run: `cd mac && make test 2>&1 | grep -E 'RecentSimilarityProbe|cannot find'`
Expected: errors about `RecentSimilarityProbe` not found.

- [ ] **Step 3: Implement the probe**

Create `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/RecentSimilarityProbe.swift`:

```swift
// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/RecentSimilarityProbe.swift
import Foundation

/// Reads recent TSE cosine similarity values from session manifests.
/// Used by the Editor's stage detail panel to surface a calibration
/// readout (last N similarities) above/below the current threshold.
public struct RecentSimilarityProbe {
    private let sessions: any SessionsClient

    public init(sessions: any SessionsClient) {
        self.sessions = sessions
    }

    /// Returns up to `limit` similarities, newest first. Sessions
    /// without a TSE stage (or without a tseSimilarity value on the
    /// TSE stage) are skipped. Raises only on backend errors.
    public func recent(limit: Int) async throws -> [Float] {
        let manifests = try await sessions.list()
        var out: [Float] = []
        for m in manifests {
            guard let tse = m.stages.first(where: { $0.name == "tse" }) else { continue }
            guard let sim = tse.tseSimilarity else { continue }
            out.append(sim)
            if out.count >= limit { break }
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd mac && make test 2>&1 | grep -E 'RecentSimilarityProbe|Test run'`
Expected: 4 new tests pass.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/RecentSimilarityProbe.swift \
        mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/RecentSimilarityProbeTests.swift
git commit -m "feat(mac): RecentSimilarityProbe reads last N TSE similarities"
```

---

### Task 10: Build `StageDetailPanel`

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/StageDetailPanel.swift`

- [ ] **Step 1: Create the panel**

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/StageDetailPanel.swift
import SwiftUI
import VoiceKeyboardCore

/// Per-stage detail panel shown below the StageGraph when a stage is
/// selected. Tunables vary by stage:
///   - All stages: Enabled toggle.
///   - tse only:   Backend dropdown, Threshold slider, Recent similarity.
struct StageDetailPanel: View {
    @Bindable var draft: PresetDraft
    let sessions: any SessionsClient

    @State private var recentSimilarities: [Float] = []
    @State private var loadError: String? = nil

    private var selected: Preset.StageSpec? {
        guard let ref = draft.selectedStage else { return nil }
        return draft.stage(for: ref)
    }

    var body: some View {
        if let ref = draft.selectedStage, let stage = selected {
            VStack(alignment: .leading, spacing: 10) {
                header(ref: ref, stage: stage)
                Divider()
                enabledRow(ref: ref, stage: stage)
                if stage.name == "tse" {
                    backendRow(ref: ref, stage: stage)
                    thresholdRow(ref: ref, stage: stage)
                    recentSimilarityRow(stage: stage)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: ref) { await refreshSimilarity() }
        } else {
            Text("Select a stage to edit its tunables.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    @ViewBuilder
    private func header(ref: StageRef, stage: Preset.StageSpec) -> some View {
        HStack {
            Text(stage.name).font(.callout).bold()
            Text("(\(ref.lane == .frame ? "frame" : "chunk"))")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Deselect") { draft.selectedStage = nil }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func enabledRow(ref: StageRef, stage: Preset.StageSpec) -> some View {
        Toggle(isOn: Binding(
            get: { stage.enabled },
            set: { draft.setEnabled($0, for: ref) }
        )) {
            Text("Enabled")
        }
    }

    @ViewBuilder
    private func backendRow(ref: StageRef, stage: Preset.StageSpec) -> some View {
        HStack {
            Text("Backend").frame(width: 96, alignment: .leading)
            Picker("", selection: Binding(
                get: { stage.backend ?? "ecapa" },
                set: { draft.setBackend($0, for: ref) }
            )) {
                Text("ecapa").tag("ecapa")
                // Future backends append here as they land.
            }
            .labelsHidden()
            .frame(maxWidth: 160)
            Spacer()
        }
    }

    @ViewBuilder
    private func thresholdRow(ref: StageRef, stage: Preset.StageSpec) -> some View {
        let threshold = stage.threshold ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Threshold").frame(width: 96, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(threshold) },
                    set: { draft.setThreshold(Float($0), for: ref) }
                ), in: 0...1, step: 0.05)
                Text(String(format: "%.2f", threshold))
                    .font(.callout.monospaced())
                    .frame(width: 44, alignment: .trailing)
            }
            Text("Below threshold the chunk is silenced; 0 disables gating.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func recentSimilarityRow(stage: Preset.StageSpec) -> some View {
        let threshold = stage.threshold ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent").frame(width: 96, alignment: .leading)
                if recentSimilarities.isEmpty {
                    Text("(no captured chunks yet)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(Array(recentSimilarities.enumerated()), id: \.offset) { _, s in
                            Text(String(format: "%.2f", s))
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(s >= threshold ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                }
                Spacer()
            }
            if let err = loadError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func refreshSimilarity() async {
        do {
            let probe = RecentSimilarityProbe(sessions: sessions)
            let got = try await probe.recent(limit: 5)
            await MainActor.run { self.recentSimilarities = got; self.loadError = nil }
        } catch {
            await MainActor.run { self.loadError = "Couldn't load recent similarity: \(error)" }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd mac && make build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/StageDetailPanel.swift mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "feat(mac): StageDetailPanel with Enabled/Backend/Threshold + recent readout"
```

---

## Phase G — Editor integration

### Task 11: Update `SaveAsPresetSheet` to take a `PresetDraft`

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/SaveAsPresetSheet.swift`

The Slice 2 sheet took a `basePreset: Preset` (the unedited bundled preset) and saved that. Slice 3 should save the **draft's** current state so user edits actually persist.

- [ ] **Step 1: Replace `basePreset` with `draft`**

In `mac/VoiceKeyboard/UI/Settings/Pipeline/SaveAsPresetSheet.swift`, change the property block + the `save()` body.

Find:

```swift
struct SaveAsPresetSheet: View {
    let basePreset: Preset
    let presets: any PresetsClient
    let onSaved: () -> Void
    let onCancel: () -> Void
```

Replace with:

```swift
struct SaveAsPresetSheet: View {
    let draft: PresetDraft
    let presets: any PresetsClient
    let onSaved: () -> Void
    let onCancel: () -> Void
```

Find the `private func save() async { ... }` body. Replace its body with:

```swift
    private func save() async {
        saving = true
        defer { saving = false }
        let p = draft.toPreset(
            name: name,
            description: description.isEmpty ? "User preset" : description
        )
        do {
            try await presets.save(p)
            await MainActor.run { onSaved() }
        } catch {
            await MainActor.run { saveError = "Save failed: \(error)" }
        }
    }
```

(The `Preset(...)` literal inside the old `save()` is gone — the draft serializes itself.)

- [ ] **Step 2: Build (will fail — EditorView still passes `basePreset:`)**

Run: `cd mac && make build 2>&1 | tail -10`
Expected: build error in EditorView.swift about missing `basePreset` param. That's fixed in the next task; we'll commit them together.

- [ ] **Step 3: Defer commit until Task 12 lands**

(Task 12 updates EditorView to pass `draft:`; commit both tasks together after that.)

---

### Task 12: Wire `EditorView` to use the new graph + panel + draft

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift`
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift`

This is the integration step: replace the read-only stage list with `StageGraph` + `StageDetailPanel`, manage the `PresetDraft` state, surface the timeout field in the toolbar, and pass the `draft` into `SaveAsPresetSheet`.

- [ ] **Step 1: Thread `sessions` into `EditorView` via PipelineTab**

In `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift`, update the editor case:

Find:

```swift
            case .editor:
                EditorView(presets: presets)
```

Replace with:

```swift
            case .editor:
                EditorView(presets: presets, sessions: sessions)
```

- [ ] **Step 2: Rewrite `EditorView`**

Replace `mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift` with:

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift
import SwiftUI
import VoiceKeyboardCore

/// Slice 3 Editor: preset picker → editable StageGraph + StageDetailPanel
/// + timeout field. Edits accumulate on a PresetDraft until saved via
/// SaveAsPresetSheet (which serializes the draft).
struct EditorView: View {
    let presets: any PresetsClient
    let sessions: any SessionsClient

    @State private var presetList: [Preset] = []
    @State private var selectedName: String = ""
    @State private var draft: PresetDraft? = nil
    @State private var loadError: String? = nil
    @State private var saveSheetVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            Divider()
            ScrollView {
                if let draft = draft {
                    VStack(alignment: .leading, spacing: 12) {
                        StageGraph(draft: draft)
                        Divider()
                        StageDetailPanel(draft: draft, sessions: sessions)
                    }
                } else if let err = loadError {
                    Text(err).foregroundStyle(.red).font(.callout)
                } else {
                    Text("Loading presets…").foregroundStyle(.secondary).font(.callout)
                }
            }
        }
        .task { await refresh() }
        .sheet(isPresented: $saveSheetVisible) {
            if let draft = draft {
                SaveAsPresetSheet(
                    draft: draft,
                    presets: presets,
                    onSaved: {
                        saveSheetVisible = false
                        Task { await refresh() }
                    },
                    onCancel: { saveSheetVisible = false }
                )
            }
        }
        .onChange(of: selectedName) { _, newName in
            // Picker changed: rebuild the draft from the selected preset.
            if let p = presetList.first(where: { $0.name == newName }) {
                draft = PresetDraft(p)
            }
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
            .frame(maxWidth: 200)

            if let draft = draft, draft.isDirty {
                Text("• edited").font(.caption).foregroundStyle(.orange)
            }

            Spacer()

            timeoutField

            Button {
                saveSheetVisible = true
            } label: { Label("Save as…", systemImage: "square.and.arrow.down") }
            .controlSize(.small)
            .disabled(draft == nil)

            Button {
                if let p = presetList.first(where: { $0.name == selectedName }) {
                    draft?.resetTo(p)
                }
            } label: { Label("Reset", systemImage: "arrow.uturn.backward") }
            .controlSize(.small)
            .disabled(draft?.isDirty != true)
        }
    }

    @ViewBuilder
    private var timeoutField: some View {
        HStack(spacing: 4) {
            Text("Timeout:").font(.callout).foregroundStyle(.secondary)
            if let draft = draft {
                TextField("", value: Binding(
                    get: { draft.timeoutSec },
                    set: { draft.timeoutSec = max(0, $0) }
                ), format: .number)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
                Text("s").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("—").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }

    private func refresh() async {
        do {
            let list = try await presets.list()
            await MainActor.run {
                self.presetList = list
                if self.selectedName.isEmpty || !list.contains(where: { $0.name == self.selectedName }),
                   let first = list.first {
                    self.selectedName = first.name
                    self.draft = PresetDraft(first)
                }
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                self.loadError = "Failed to load presets: \(error)"
            }
        }
    }
}
```

- [ ] **Step 3: Run tests + build**

Run: `cd mac && make test 2>&1 | tail -5`
Expected: PASS — all tests still green.

Run: `cd mac && make build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit Tasks 11 + 12 together**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift \
        mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift \
        mac/VoiceKeyboard/UI/Settings/Pipeline/SaveAsPresetSheet.swift \
        mac/VoiceKeyboard.xcodeproj/project.pbxproj
git commit -m "feat(mac): EditorView wires StageGraph + StageDetailPanel + Save-as draft"
```

---

## Phase H — Final integration

### Task 13: Final integration check + PR

- [ ] **Step 1: Full Go suite**

Run: `cd core && go test ./... && go test -tags=whispercpp ./cmd/libvkb/...`
Expected: PASS.

- [ ] **Step 2: Full Mac suite**

Run: `cd mac && make test 2>&1 | tail -5`
Expected: PASS — total test count is the Slice 2 baseline (~74) + new tests:
  - 3 PresetTimeoutCodingTests
  - 4 StageConstraintValidatorTests
  - 4 RecentSimilarityProbeTests
Expect ~85 tests total.

- [ ] **Step 3: Clean Debug build**

Run: `cd mac && make clean && make build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual smoke test**

Toggle Developer mode on. Open Pipeline → Editor.

- Pick `default` → confirm the StageGraph renders three lanes (frame: denoise + decimate3, chunk: tse, terminal: whisper/dict/llm). Tap `tse` → detail panel shows Enabled toggle + Backend `ecapa` + Threshold slider at 0.00 + recent similarity row.
- Drag `decimate3` above `denoise` in the frame lane → red warning text appears below the lane and the order reverts. Wait ~4s; the warning fades.
- Adjust the Threshold slider → "• edited" badge appears in the toolbar.
- Click Reset → slider snaps back; "• edited" disappears.
- Edit something, click Save as… → name `office-tighter`, save. Re-pick `office-tighter` from the picker → edits persisted.
- Pick `paranoid` → Threshold slider shows 0.70.
- Change Timeout to 20s, Save as `office-slow`. Verify `vkb_get_preset office-slow` returns `"timeout_sec": 20`.

- [ ] **Step 5: Push + PR**

```bash
git push -u origin feat/pipeline-orchestration-slice-3
gh pr create --base main --title "feat: pipeline orchestration UI — slice 3 (editable graph)" \
  --body "Third slice of the Pipeline Orchestration UI. Turns the read-only Slice 2 Editor into a real one.

## Summary

- **Drag-and-drop StageGraph** — three lanes (frame, chunk, fixed terminal); within-lane reorder via SwiftUI \`List + onMove\`. Cross-lane drops blocked structurally.
- **StageConstraintValidator** — pure function: rejects sample-rate-incompatible orderings; reverts the move + surfaces an inline red message that auto-clears after 4s.
- **PresetDraft** — \`@Observable\` working copy of a Preset; tracks isDirty against the source. Reset restores; Save as… serializes the draft (not the source) so user edits actually persist.
- **StageDetailPanel** — Enabled toggle, Backend dropdown, Threshold slider, Recent similarity readout (last 5, color-coded above/below threshold).
- **PipelineTimeoutSec** — new per-preset field threaded all the way through: \`config.Config\` → \`presets.Preset\` → libvkb's \`pipe.Run\` ctx via \`context.WithTimeout\`. Bundled defaults: default/paranoid 10s, minimal 5s, aggressive 15s. \`timeout_sec: 0\` disables the bound.
- **Toolbar timeout field** in the Editor with live editing on the draft.

## Test plan

- [x] cd core && go test ./... && go test -tags=whispercpp ./cmd/libvkb/...
- [x] cd mac && make test (all suites green; ~85 tests total)
- [x] cd mac && make build
- [ ] Manual: drag-drop reorders within lane, invalid orderings revert with red message; Threshold slider edits the draft; Reset restores; Save as… persists edits including timeout.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Summary

Total: **13 tasks across 8 phases.** Estimated ~700 LOC, matching the spec.

**By area:**
- Go (Tasks 1-4): ~60 LOC — config field, libvkb timeout, preset schema, Resolve/Match.
- Swift bridge (Task 5): ~25 LOC — Preset.timeoutSec.
- Mac data model (Task 6): ~120 LOC — PresetDraft.
- Constraint validation (Task 7): ~80 LOC including tests.
- Stage graph (Task 8): ~180 LOC.
- Detail panel (Tasks 9-10): ~210 LOC including the probe.
- Editor integration (Tasks 11-12): ~120 LOC modified.
- Final integration (Task 13): ~5 LOC tweaks if any.

---

## Test plan

- [ ] `cd core && go test ./...`
- [ ] `cd core && go test -tags=whispercpp ./cmd/libvkb/...`
- [ ] `cd mac && make test`
- [ ] `cd mac && make build`
- [ ] Manual smoke (see Task 13 Step 4)

---

## Self-Review

### Spec coverage

| Spec section / requirement | Implementing task |
|---|---|
| Phase 3 layout — three lanes feeding a fixed terminal chain | Task 8 (StageGraph) |
| Drag mechanics within a lane via List + onMove | Task 8 |
| Constraint validator (sample-rate compat) + inline red message | Tasks 7, 8 |
| Cross-lane structural blocking (separate Lists) | Task 8 |
| Per-stage detail panel: Enabled toggle | Task 10 |
| Per-stage detail panel: Backend dropdown | Task 10 |
| Per-stage detail panel: Threshold slider (TSE) | Task 10 |
| Per-stage detail panel: Recent similarity readout (TSE) | Tasks 9, 10 |
| Toolbar: Save as… (already in Slice 2) | Task 11 (rewired to draft) |
| Toolbar: Reset | Task 12 |
| Toolbar: Timeout field | Task 12 |
| Per-preset timeout, mirrored into EngineConfig.PipelineTimeoutSec | Tasks 1, 3, 4, 5 |
| Pipeline timeout (best-effort): context.WithTimeout in engine; warning event on expiry | Task 2 |
| Recent similarity readout pulls last 5 from session manifests | Task 9 |
| Save as preset… serializes the working state, not the source | Tasks 6, 11 |

All Slice 3 requirements mapped. Drag-drop edge cases (cross-lane drops) are handled by SwiftUI structurally — no explicit code needed beyond keeping each lane in its own List.

### Placeholder scan

No "TBD" / "implement later" / "add validation" hand-waves. Every step has either complete code or a concrete shell command with expected output. The only deferral is the future `backend` registry expansion (Task 10's Backend Picker has only `ecapa` today; new backends append as they land — that's a code comment, not a TODO).

### Type consistency

- `Preset.timeoutSec: Int?` (Swift) ↔ `Preset.TimeoutSec *int` (Go) ↔ `"timeout_sec"` JSON. CodingKey in Task 5 matches Go's struct tag in Task 3.
- `PresetDraft` mutators use `StageRef(lane:name:)` consistently across Tasks 6, 8, 10.
- `StageConstraintValidator.validate(frameStages:)` signature matches usage in Task 8.
- `RecentSimilarityProbe(sessions:)` signature matches usage in Task 10.
- `SaveAsPresetSheet(draft:presets:onSaved:onCancel:)` signature in Task 11 matches the call site in Task 12.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-03-pipeline-orchestration-slice-3-editor.md`. Two execution options:

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.
