# Pipeline Editor redesign — list+details, terminal-stage configurability, default-preset lock

**Status:** design
**Date:** 2026-05-07
**Owner:** Mac app — Settings → Pipeline

## Problem

The current Pipeline → Editor pane has three problems the user surfaced together:

1. **The "Transcribe + cleanup" section is dead UI.** whisper, dict, and llm render as locked rows with no interaction — no per-preset editing for whisper model or LLM, and no way to deep-link to the source-of-truth tab where these are configured globally.
2. **The "Provider" tab is mis-named.** It only configures the LLM provider; the name suggests something more generic. The pipeline UI also leans on this tab as the place to manage LLM secrets, base URLs, and the user's *default* provider/model — that role should be reflected in the tab title.
3. **The save model is incomplete.** Today the editor only offers "Save as…" — there is no way to overwrite an existing user preset in place. Combined with the fact that bundled presets are already write-protected by the Go core (via `presets.ErrReservedName`), the right UX is: bundled presets are read-only, user presets get a real Save with confirmation.

The user also asked for a layout change: the existing single-column StageGraph + StageDetailPanel becomes a list-on-left, details-on-right structure so editing one stage doesn't push the rest of the graph off-screen.

## Goals

- Make whisper, dict, and llm first-class stages in the editor — selectable rows with right-pane bodies, just like `tse`.
- Add a per-preset LLM override (provider + model). Global defaults still live in the renamed LLM Provider tab.
- Add deep-link buttons from the right pane to General (whisper), Dictionary (dict), and LLM Provider (llm) so users can jump to the source-of-truth tab.
- Lock bundled presets against editing, with a discoverable "Save as…" path. Add a real Save (with confirmation) for user presets.
- Rename the Provider tab to "LLM Provider".
- Reuse existing components — model tables, picker logic, dict stats, deep-link button style — so the new editor doesn't drift from the rest of Settings.

## Non-goals

- No changes to per-provider auth/secrets surfaces (Anthropic API key field, Ollama auto-detect, etc.) — those stay in the renamed LLM Provider tab as today.
- No drag-drop reorder. The editor remains read-only ordering, matching today's behavior; lanes are too short for reorder to be valuable.
- No baseURL per preset. Base URLs are a per-machine concern (different ollama hosts, etc.), not a per-pipeline concern.
- No changes to the Compare sub-view, Playground tab, captured-session inspector, or Go core preset persistence semantics other than the LLMSpec field addition.
- No `selectedPage` enum migration — the SettingsPage case stays `.provider`; only its display title changes.

## Architecture

### Layout

The Pipeline → Editor pane becomes a two-column split inside the existing `EditorView`:

```
┌─ Pipeline ────────────────────────────────────────────────────────┐
│ ▾ Editor | Compare                                                │
├─ Left column (≈ 280pt) ──────┬─ Right pane (flex) ───────────────┤
│  Preset: [paranoid (default)]│                                    │
│  • edited                     │   ┌─ stage details ─────────────┐ │
│  [Save] [Save as…] [Reset]    │   │                             │ │
│  ─────────────────────────    │   │  (selected stage's body)    │ │
│  Streaming                    │   │                             │ │
│   ☑ denoise        frame      │   │                             │ │
│   ☑ decimate3      frame      │   └─────────────────────────────┘ │
│  ── CHUNKER ──                │                                    │
│  Per-utterance                │   (or, if nothing selected:        │
│   ☑ tse  ecapa     chunk      │    "Select a stage to edit its    │
│  ─────────────────────────    │     tunables.")                    │
│  Transcribe + cleanup         │                                    │
│   ▸ whisper  small            │                                    │
│   ▸ dict     N terms          │                                    │
│   ▸ llm      anthropic · …    │                                    │
└────────────────────────────────┴────────────────────────────────────┘
```

- Left column hosts the toolbar (preset picker + dirty badge + Save / Save as… / Reset) and the stage list.
- Stage list is grouped by lane (Streaming → CHUNKER → Per-utterance → Transcribe + cleanup) — preserving today's audio-engineering ordering.
- Right pane shows details for the selected stage. When nothing is selected, it shows the same placeholder copy as today.
- Per-stage `Toggle` checkboxes stay on the left rows. The right pane is for tunables, not enable/disable.

### Stage list behavior

`StageGraph.swift` becomes `StageList.swift` — same component, restructured as a single vertical list with section headers per lane. The CHUNKER divider is preserved between Streaming and Per-utterance.

The three terminal-stage rows (`whisper`, `dict`, `llm`) lose their static lock icons and become selectable like the frame/chunk rows. They get a chevron indicator (`chevron.right`) on the right edge instead of the lock, signaling "click to edit".

Selection is still the existing `PresetDraft.selectedStage: StageRef?`. We extend `StageRef.Lane` with a third case: `.terminal` (`.frame`, `.chunk`, `.terminal`). The terminal lane has no `Preset.StageSpec` rows — its three "stages" (`whisper`, `dict`, `llm`) are pseudo-stages whose state lives directly on `PresetDraft` (`transcribeModelSize`, `llmProvider`, `llmModel`) and on `UserSettings` (`customDict`). The existing `draft.stage(for: ref)` returns nil for `.terminal` refs; the right-pane switch keys on `ref.lane == .terminal && ref.name == ...` instead of needing a `StageSpec`.

### Right-pane bodies

The right pane is a single view, `StageDetailPane`, that switches on the selected stage. Bodies:

- **frame stages** (today's `denoise`, `decimate3`): unchanged — "No tunables — toggle this stage on or off via the checkbox in the row."
- **chunk stages** (`tse`): unchanged — backend picker, threshold slider, recent similarity row.
- **whisper** (new): `Picker("Model size", selection: $draft.transcribeModelSize)` rendering the same labels as `GeneralTab` (with `✓` prefix for downloaded sizes, plain space for not-downloaded), followed by a `ManageElsewhereButton(target: .general)` labelled "Manage in General →". All sizes remain selectable (matches today's General picker) — the "✓"/" " prefix is the only visual distinction. Downloading is a General-only action, reachable via the deep-link.
- **dict** (new): read-only summary "{N} term{s} · ~{T} token{s}" computed via the new shared `DictStats.compute(from: settings.customDict)` helper (lifted out of `DictionaryTab.dictStats()`), followed by a one-line description "Custom dictionary is global — every preset uses the same terms.", followed by `ManageElsewhereButton(target: .dictionary)` labelled "Edit in Dictionary →".
- **llm** (new): `Picker("Provider", selection: provider-binding)` and `Picker("Model", selection: model-binding)`. Provider list and model lists pulled from the new `LLMProviderCatalog`. Provider-switch resets model to the default for that provider via `LLMProviderCatalog.defaultModel(for:)` — same behavior as today's `LLMProviderTab.modelBelongs` logic. For local providers (`ollama`, `lmstudio`) where the model list is auto-detected at runtime, the catalog's `models(for:)` returns the same auto-detected list the corresponding `OllamaSection` / `LMStudioSection` uses today (extracted into the catalog as a shared async fetch). The picker preserves whatever model string is in the preset even if that model isn't currently installed locally — same forgiveness as today's per-section pickers. Followed by `ManageElsewhereButton(target: .provider)` labelled "Manage in LLM Provider →".

### Bundled vs user presets

A new helper, `Preset.isBundled` (computed property: `Preset.bundledNames.contains(name)`), is the single source of truth. The bundled-name set is also exported as `Preset.bundledNames: Set<String>` so `SaveAsPresetSheet` and the picker label both read from one place. Implementation imports the set from a static literal that mirrors the Go core's reserved set; a unit test asserts the Swift set matches the names returned by `presets.list()` filtered against the bundled JSON.

**Picker label.** Bundled presets render with a faint " (default)" suffix in the toolbar picker:

```swift
Text(p.isBundled ? "\(p.name) (default)" : p.name).tag(p.name)
```

Selected-row label uses the same suffix.

**Bundled-preset behavior in the editor.**

- All editing controls in the right pane are `.disabled(!isEditable)` where `isEditable = !(draft?.source.isBundled ?? false)`.
- Per-stage `Toggle` checkboxes in the left list are also disabled.
- The toolbar's `Save` button is hidden (only `Save as…` and `Reset` show; `Reset` is a no-op for unedited bundled presets).
- A small inline hint sits above the left stage list: "Bundled preset — *Save as…* to make an editable copy."
- **Pulse-Save-as on disabled-control tap.** Disabled `Toggle`s and disabled `Picker`s in this mode are wrapped in a `.contentShape(Rectangle())` + `.onTapGesture { nudgeSaveAs() }` overlay that triggers a `pulseTrigger: Int` state on the toolbar. The `Save as…` button binds a `.scaleEffect` and `.shadow` modifier to that trigger via `.animation(.easeInOut(duration: 0.18).repeatCount(2, autoreverses: true), value: pulseTrigger)`. Re-tapping increments the trigger so the pulse re-fires instead of compounding.

### Save semantics

`PresetDraft.isDirty` already drives the "• edited" badge. The toolbar logic:

```
isBundled         → [ Save as… ] [ Reset ]
                    Reset is a no-op when nothing is dirty (existing behavior).
isUserPreset:
  isDirty == false  → [ Save as… ] [ Reset (disabled) ]
  isDirty == true   → [ Save ] [ Save as… ] [ Reset ]
```

**Save** (overwrite) flow:

1. Click `Save` on a dirty user preset.
2. Confirmation sheet: title "Overwrite '{preset.name}'?", body "This replaces the saved preset with your current edits.", buttons **Cancel** and **Overwrite** (destructive role).
3. On Overwrite: serialize via `draft.toPreset(name: source.name, description: source.description)`, call `presets.save(...)` (Go's `SaveUserAt` rewrites the JSON file). On success: refresh preset list, call `draft.resetTo(savedPreset)` so `isDirty` returns to false. On failure: surface the error inline below the toolbar (red caption), do not close the sheet.

`Save as…` and `Reset` keep their current behavior. `Save as…` keeps reusing `SaveAsPresetSheet` unchanged.

### Preset schema — LLM model

`Preset.LLMSpec` gains an optional `model: String?`:

```swift
public struct LLMSpec: Codable, Equatable, Sendable {
    public let provider: String
    public let model: String?  // nil = use global default for this provider
    public init(provider: String, model: String? = nil) { ... }
}
```

JSON: `{"provider": "anthropic", "model": "claude-sonnet-4-6"}`. Old presets without `model` decode with `model = nil`.

**Apply-time behavior** (`UserSettings.applying(_:)`):

```swift
s.llmProvider = preset.llm.provider
if let m = preset.llm.model { s.llmModel = m }   // only stamp when present
```

`nil` preserves whatever model the user has globally. New `Save as…` and `Save` writes always emit the current draft's model, so once a preset is saved by the new UI it carries `model`.

**Go core mirror.** `core/internal/presets.LLMSpec` adds:

```go
type LLMSpec struct {
    Provider string `json:"provider"`
    Model    string `json:"model,omitempty"`
}
```

`presets.Resolve` stamps `cfg.LLMModel = preset.LLM.Model` only when non-empty (matches the Swift fallback). Existing bundled JSON in `pipeline-presets.json` is updated to include `"model"` for each bundled preset (anthropic + claude-sonnet-4-6) so the four bundled presets carry the same model pin behavior as new user presets.

### LLMProviderCatalog — single source of truth for provider/model lists

A new file `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/LLM/LLMProviderCatalog.swift` (placed in the existing `LLM/` directory in `VoiceKeyboardCore`, alongside the rest of the LLM-related types) holds:

- `providers: [(id: String, label: String)]` — current `LLMProviderTab.providers` literal.
- `defaultModel(for: String) -> String` — current `LLMProviderTab.defaultModels`.
- `modelBelongs(_ model: String, to provider: String) -> Bool` — current `LLMProviderTab.modelBelongs`.
- `models(for provider: String) -> [String]` — the per-provider model lists currently embedded in `AnthropicSection`/`OpenAISection`/`OllamaSection`/`LMStudioSection`.

`LLMProviderTab` (renamed from `ProviderTab`) and the new `llm` right-pane body both consume this catalog. The per-provider sections (`AnthropicSection` etc.) lose their hard-coded model lists in favor of `LLMProviderCatalog.models(for: "anthropic")`.

The catalog is the only acceptable home for these lists going forward — adding a new provider or model means editing one file.

### Tab rename

- `mac/VoiceKeyboard/UI/Settings/ProviderTab.swift` → `LLMProviderTab.swift`. `struct ProviderTab` → `struct LLMProviderTab`.
- `SettingsView.swift`: the enum case stays `.provider` (no UserDefaults migration), but `case .provider: return "LLM Provider"` and `case .provider: return LLMProviderTab(...)`.
- `PresetBanner.swift` summary copy referencing the tab name (currently just shows the provider id, not the tab name) doesn't change.
- The new `ManageElsewhereButton(target: .provider)` button in the llm right-pane body uses the label "Manage in LLM Provider →".
- Any onboarding or first-run copy that names the tab gets updated as part of the rename pass — search `mac/VoiceKeyboard/UI/FirstRun/` and any test fixtures for "Provider" tab references.

### Plumbing

`EditorView` today receives only `presets` and `sessions`. It will additionally need:

- `@Binding var settings: UserSettings` — for the dict-stats summary (reads `settings.customDict`).
- `let navigateTo: (SettingsPage) -> Void` — for the deep-link buttons.

Both already exist on `SettingsView.DetailView`; `DetailView.case .pipeline` plumbs them through `PipelineTab` → `EditorView`. `PipelineTab.body` doesn't itself use either, so they're forwarded.

`ManageElsewhereButton` is a new small view in `mac/VoiceKeyboard/UI/Settings/Pipeline/ManageElsewhereButton.swift`:

```swift
struct ManageElsewhereButton: View {
    let target: SettingsPage
    let label: String
    let navigateTo: (SettingsPage) -> Void
    var body: some View {
        Button { navigateTo(target) } label: {
            Label(label, systemImage: "arrow.up.right.square")
        }
        .controlSize(.small)
    }
}
```

It mirrors the style of `PresetBanner`'s "Configure…" button (Label + systemImage + small control size). `navigateTo` is the same closure type already used by `PresetBanner`.

## Data flow

```
EditorView
├── PresetDraft (mutated in place; isDirty drives toolbar)
│     └── source: Preset (from presets.list())
├── @Binding settings: UserSettings (read-only here, used only for dict stats)
└── navigateTo: (SettingsPage) -> Void

Toolbar
├── Picker (selectedName) → onChange → draft = PresetDraft(p)
├── Save (only when !isBundled && isDirty) → confirm sheet → presets.save(draft.toPreset(name: source.name, ...)) → resetTo(saved)
├── Save as… → SaveAsPresetSheet (unchanged)
└── Reset → draft.resetTo(source)

StageList (left column)
├── Section "Streaming" (frameStages)
├── Divider "CHUNKER"
├── Section "Per-utterance" (chunkStages)
└── Section "Transcribe + cleanup" (terminal stages: whisper, dict, llm)
     • Selection writes to draft.selectedStage: StageRef?

StageDetailPane (right pane)
└── switch draft.selectedStage
     ├── nil          → "Select a stage to edit its tunables."
     ├── .frame       → existing body (no tunables hint)
     ├── .chunk(tse)  → existing body (backend / threshold / recent similarity)
     ├── .terminal(whisper) → ModelSizePicker bound to draft.transcribeModelSize + ManageElsewhereButton(.general)
     ├── .terminal(dict)    → DictStatsRow(settings.customDict) + description + ManageElsewhereButton(.dictionary)
     └── .terminal(llm)     → ProviderPicker + ModelPicker bound to draft.llmProvider/draft.llmModel + ManageElsewhereButton(.provider)
```

`PresetDraft` gains:

- `var llmModel: String` (mirrors `Preset.LLMSpec.model ?? UserSettings.default.llmModel`).
- The mutator `setLLMModel(_:)`. Provider changes via `setLLMProvider(_:)` reset `llmModel` to `LLMProviderCatalog.defaultModel(for: newProvider)` if the current model doesn't belong to the new provider — same logic as today's `LLMProviderTab` provider-switch handler.
- `isDirty` extends to compare `llmModel` against `source.llm.model ?? <effective default>`.
- `toPreset(name:description:)` emits `LLMSpec(provider: llmProvider, model: llmModel)`.
- `resetTo(_:)` resets `llmModel` from the new source.

## Error handling

- **Save (overwrite) failure.** If `presets.save(...)` throws (Go side returns rc != 0 — disk full, permission, malformed payload), the error message is shown inline below the toolbar in red caption text, the draft remains dirty, and `draft.source` is **not** advanced. The user can retry or pick Reset.
- **Bundled-preset list desync.** If the Go core ever adds a bundled preset name not in `Preset.bundledNames`, the picker still shows it (no suffix), and Save would attempt to overwrite — the Go core rejects with `ErrReservedName` and the error surfaces via the same Save-failure path. A unit test in `PresetsClientTests` (or new `BundledPresetNamesTests`) asserts the Swift set matches the bundled JSON to catch drift at compile-time-ish.
- **Old user preset without llm.model.** Decodes with `llm.model = nil`. The editor's llm body shows the global `settings.llmModel` as the picker selection on first load, then writes a non-nil model on save — naturally migrating the file.
- **Deep-link to a tab the user can't see.** Pipeline lives behind `developerMode == true`; the Settings sidebar always shows General/Dictionary/LLM Provider regardless. So `navigateTo(.general/.dictionary/.provider)` is always valid from inside Pipeline.
- **Whisper model not downloaded.** The picker shows it the same as General does — selectable with a "(not downloaded)" suffix. Selecting it via the editor doesn't trigger a download; the user follows the deep-link to General to download. Engine config behavior on a missing model is unchanged from today.

## Testing

**SwiftPM unit tests** (`mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/`):

- `PresetLLMModelCodingTests` — round-trip `Preset.LLMSpec` with and without `model`, asserting old JSON without `model` decodes to `nil`, and `nil` re-encodes without the key (`model,omitempty` semantics on the Swift side via custom encoder).
- `UserSettingsApplyPresetTests` — extend the existing suite to assert `applying(preset:)` with `llm.model = nil` preserves the receiver's `llmModel`, and with `llm.model = "X"` stamps `"X"`.
- `LLMProviderCatalogTests` — enumerate all providers, assert `defaultModel(for:)` returns a model from `models(for:)`, and `modelBelongs(defaultModel(for: p), to: p) == true`.
- `BundledPresetNamesTests` — assert `Preset.bundledNames` matches the names returned by a freshly-listed bundled-only preset list (test pumps an in-memory `PresetsClient` returning the bundled JSON only).
- `PresetsClientTests` — already covers save/list/get; add a test that saving a preset whose name is in `bundledNames` returns the backend error path.

**Go core tests** (`core/internal/presets/`):

- `resolve_test.go` — extend to assert `Resolve` stamps `cfg.LLMModel` when set, and leaves it untouched when empty.
- `presets_test.go` — assert each bundled preset's `LLM.Model` is non-empty after the JSON update.

**Manual UI smoke** (called out for the implementation plan, not automated):

- Pick each of the four bundled presets; verify all controls disabled, Save hidden, Save as… and Reset visible. Tap a disabled toggle; verify Save as… pulses.
- Pick a user preset; toggle a stage off; verify Save appears, dirty badge appears. Click Save → confirm → file rewritten. Click Reset → reverts.
- In each terminal stage, click "Manage in X →" and verify the Settings page switches.
- Open the LLM Provider tab; verify model lists match the editor's lists for the same provider.
- Old preset path: drop a JSON without `"model"` into `~/Library/Application Support/VoiceKeyboard/presets/`; load it; verify the editor shows the global default model and saving emits a `"model"` key.

## Open questions

None blocking implementation.

## Out of scope (future work)

- Per-preset baseURL or per-preset secrets — see Non-goals.
- A "Duplicate preset" action that pre-fills `SaveAsPresetSheet` from a bundled preset (currently the user clicks Save as… while the bundled preset's draft is loaded — same effect).
- Drag-drop reorder of frame/chunk stages — was tried in earlier slices, removed.
- Confirmation on Reset — today silently reverts; no user complaint.
