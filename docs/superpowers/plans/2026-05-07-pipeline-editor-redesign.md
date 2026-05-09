# Pipeline Editor redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the Settings → Pipeline → Editor pane into a list+details view, make whisper/dict/llm selectable terminal stages with per-preset overrides and deep-links, lock bundled presets against editing with a Save-as nudge, add a real Save button (with confirmation) for user presets, and rename the Provider tab to LLM Provider.

**Architecture:** Two-column layout inside `EditorView` — left column hosts the toolbar (preset picker + Save / Save as… / Reset) and a lane-grouped stage list; right pane shows tunables for the selected stage. The preset schema gains an optional `LLMSpec.model` so each preset pins both provider and model. Provider/model lists are centralized in a new `LLMProviderCatalog` consumed by both the renamed Provider tab and the new editor body. Bundled-preset names are exposed as `Preset.bundledNames` for one source of truth across the SaveAsPresetSheet and the editor's read-only mode.

**Tech Stack:** SwiftUI + AppKit (Mac app), SwiftPM library `VoiceKeyboardCore`, Go core (`core/internal/presets`).

**Reference:** `docs/superpowers/specs/2026-05-07-pipeline-editor-redesign-design.md`

---

## File Structure

**Create:**
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/LLM/LLMProviderCatalog.swift` — providers list, default-model-per-provider, model-belongs predicate, curated model lists for each provider.
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/DictStats.swift` — token/word counts of `customDict` (lifted from `DictionaryTab`).
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/BundledPresetNames.swift` — static `Set<String>` and `Preset.isBundled` extension.
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/PresetLLMModelCodingTests.swift`
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/LLMProviderCatalogTests.swift`
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/BundledPresetNamesTests.swift`
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/DictStatsTests.swift`
- `mac/VoiceKeyboard/UI/Settings/Pipeline/ManageElsewhereButton.swift` — deep-link button.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/StageList.swift` — left-column lane-grouped list (replaces `StageGraph.swift` after rename).
- `mac/VoiceKeyboard/UI/Settings/Pipeline/TerminalStageBodies.swift` — whisper/dict/llm right-pane bodies.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/OverwriteConfirmSheet.swift` — confirmation sheet for user-preset Save.

**Rename:**
- `mac/VoiceKeyboard/UI/Settings/ProviderTab.swift` → `LLMProviderTab.swift` (and `struct ProviderTab` → `struct LLMProviderTab`).
- `mac/VoiceKeyboard/UI/Settings/Pipeline/StageGraph.swift` → `StageList.swift`.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/StageDetailPanel.swift` → `StageDetailPane.swift`.

**Modify:**
- `core/internal/presets/presets.go` — `LLMSpec.Model` field.
- `core/internal/presets/resolve.go` — `Resolve` stamps `cfg.LLMModel` from preset when non-empty.
- `core/internal/presets/pipeline-presets.json` — bundled presets gain `"model": "claude-sonnet-4-6"`.
- `core/internal/presets/resolve_test.go` — assert model stamping.
- `core/internal/presets/presets_test.go` — assert each bundled preset has a non-empty model.
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/Preset.swift` — add `LLMSpec.model`.
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/SettingsStore.swift` — `applying(preset:)` stamps `llmModel` only when preset has one.
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/StageRef.swift` — add `.terminal` lane.
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/UserSettingsApplyPresetTests.swift` — extend.
- `mac/VoiceKeyboard/UI/Settings/SettingsView.swift` — Provider title → "LLM Provider"; plumb `settings` and `navigateTo` into PipelineTab.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift` — forward `settings` and `navigateTo` to EditorView.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift` — two-column layout, plumbing, Save flow, bundled-disable, pulse trigger.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/PresetDraft.swift` — `llmModel` field, `setLLMProvider` / `setLLMModel`, `isDirty`, `toPreset`, `resetTo`.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/SaveAsPresetSheet.swift` — read reserved set from `Preset.bundledNames`.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/StageList.swift` (renamed from StageGraph) — section grouping + terminal-stage rows + selection routing.
- `mac/VoiceKeyboard/UI/Settings/Pipeline/StageDetailPane.swift` (renamed from StageDetailPanel) — switch on `.terminal` lane to render new bodies.
- `mac/VoiceKeyboard/UI/Settings/{Anthropic,OpenAI}Section.swift` — pull provider list / default models from `LLMProviderCatalog` (no behavior change to dynamic model fetch).
- `mac/VoiceKeyboard/UI/Settings/{Ollama,LMStudio}Section.swift` — same.
- `mac/VoiceKeyboard/UI/Settings/DictionaryTab.swift` — use `DictStats.compute(_:)`.

---

## Phase A — Schema: per-preset LLM model

### Task A1: Go core — add `LLMSpec.Model` field

**Files:**
- Modify: `core/internal/presets/presets.go`
- Test: `core/internal/presets/presets_test.go`

- [ ] **Step 1: Write the failing test**

Add to `core/internal/presets/presets_test.go` after the existing `TestLoadBundled` style tests:

```go
func TestBundledPresetsHaveLLMModel(t *testing.T) {
	got, err := loadBundled()
	if err != nil {
		t.Fatalf("loadBundled: %v", err)
	}
	for _, p := range got {
		if p.LLM.Model == "" {
			t.Errorf("bundled preset %q has empty LLM.Model — bundled presets must pin a model", p.Name)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd core && go test ./internal/presets/ -run TestBundledPresetsHaveLLMModel -v`
Expected: FAIL with "p.LLM.Model" undefined (struct field doesn't exist yet).

- [ ] **Step 3: Add the `Model` field to `LLMSpec`**

Edit `core/internal/presets/presets.go`, replacing:

```go
// LLMSpec mirrors the LLM-related fields of EngineConfig.
type LLMSpec struct {
	Provider string `json:"provider"`
}
```

with:

```go
// LLMSpec mirrors the LLM-related fields of EngineConfig.
//
// Model is optional in user-preset JSON: an empty value means "fall
// back to the engine's current LLMModel" (set by the user globally
// in the LLM Provider tab). Bundled presets must always pin a model.
type LLMSpec struct {
	Provider string `json:"provider"`
	Model    string `json:"model,omitempty"`
}
```

- [ ] **Step 4: Update `pipeline-presets.json` to pin a model on every bundled preset**

Edit `core/internal/presets/pipeline-presets.json`, replacing each `"llm": {"provider": "anthropic"},` line with:

```json
      "llm":        {"provider": "anthropic", "model": "claude-sonnet-4-6"},
```

(All four bundled presets — `default`, `minimal`, `aggressive`, `paranoid`.)

- [ ] **Step 5: Run test to verify it passes**

Run: `cd core && go test ./internal/presets/ -run TestBundledPresetsHaveLLMModel -v`
Expected: PASS.

- [ ] **Step 6: Run the full presets test suite to confirm nothing else broke**

Run: `cd core && go test ./internal/presets/ -v`
Expected: PASS (all tests).

- [ ] **Step 7: Commit**

```bash
git add core/internal/presets/presets.go core/internal/presets/pipeline-presets.json core/internal/presets/presets_test.go
git commit -m "feat(presets): add optional LLMSpec.Model + pin model in bundled presets"
```

### Task A2: Go core — `Resolve` stamps `LLMModel` from preset

**Files:**
- Modify: `core/internal/presets/resolve.go`
- Test: `core/internal/presets/resolve_test.go`

- [ ] **Step 1: Write the failing test**

Add to `core/internal/presets/resolve_test.go`:

```go
func TestResolveStampsLLMModelFromPreset(t *testing.T) {
	p := Preset{
		Name:        "test",
		Transcribe:  TranscribeSpec{ModelSize: "small"},
		LLM:         LLMSpec{Provider: "anthropic", Model: "claude-haiku-4-5"},
	}
	cfg := Resolve(p, EngineSecrets{LLMModel: "ignored-from-secrets"})
	if cfg.LLMModel != "claude-haiku-4-5" {
		t.Errorf("LLMModel = %q, want %q", cfg.LLMModel, "claude-haiku-4-5")
	}
}

func TestResolveLeavesLLMModelWhenPresetEmpty(t *testing.T) {
	p := Preset{
		Name:       "test",
		Transcribe: TranscribeSpec{ModelSize: "small"},
		LLM:        LLMSpec{Provider: "anthropic"}, // no Model
	}
	cfg := Resolve(p, EngineSecrets{LLMModel: "from-secrets"})
	if cfg.LLMModel != "from-secrets" {
		t.Errorf("LLMModel = %q, want %q (preset-empty should preserve secrets)", cfg.LLMModel, "from-secrets")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd core && go test ./internal/presets/ -run TestResolveStampsLLMModelFromPreset -v`
Expected: FAIL — first test fails because `cfg.LLMModel` is currently always `secrets.LLMModel`.

- [ ] **Step 3: Update `Resolve` in `resolve.go`**

Find the `Resolve` function and change:

```go
		LLMModel:            secrets.LLMModel,
```

to:

```go
		LLMModel:            resolveLLMModel(p, secrets),
```

Add the helper just below `resolveLLMProvider`:

```go
// resolveLLMModel returns the preset's pinned model when set, otherwise
// the engine's current LLMModel (typically the user's global default
// from the LLM Provider tab). Mirrors resolveLLMProvider semantics.
func resolveLLMModel(p Preset, secrets EngineSecrets) string {
	if p.LLM.Model != "" {
		return p.LLM.Model
	}
	return secrets.LLMModel
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd core && go test ./internal/presets/ -v`
Expected: PASS (all tests, including the new ones).

- [ ] **Step 5: Commit**

```bash
git add core/internal/presets/resolve.go core/internal/presets/resolve_test.go
git commit -m "feat(presets): Resolve stamps LLMModel from preset when set"
```

### Task A3: Swift — add `Preset.LLMSpec.model`

**Files:**
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/Preset.swift`
- Test: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/PresetLLMModelCodingTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/PresetLLMModelCodingTests.swift`:

```swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("Preset.LLMSpec.model coding")
struct PresetLLMModelCodingTests {

    @Test func decodes_model_when_present() throws {
        let json = #"""
        {"provider": "anthropic", "model": "claude-haiku-4-5"}
        """#
        let spec = try JSONDecoder().decode(Preset.LLMSpec.self, from: Data(json.utf8))
        #expect(spec.provider == "anthropic")
        #expect(spec.model == "claude-haiku-4-5")
    }

    @Test func decodes_nil_model_when_absent() throws {
        let json = #"""
        {"provider": "anthropic"}
        """#
        let spec = try JSONDecoder().decode(Preset.LLMSpec.self, from: Data(json.utf8))
        #expect(spec.provider == "anthropic")
        #expect(spec.model == nil)
    }

    @Test func encodes_without_model_key_when_nil() throws {
        let spec = Preset.LLMSpec(provider: "ollama", model: nil)
        let data = try JSONEncoder().encode(spec)
        let str = String(decoding: data, as: UTF8.self)
        #expect(!str.contains("\"model\""))
        #expect(str.contains("\"provider\":\"ollama\""))
    }

    @Test func encodes_model_when_set() throws {
        let spec = Preset.LLMSpec(provider: "anthropic", model: "claude-sonnet-4-6")
        let data = try JSONEncoder().encode(spec)
        let str = String(decoding: data, as: UTF8.self)
        #expect(str.contains("\"model\":\"claude-sonnet-4-6\""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mac && swift test --filter "Preset.LLMSpec.model coding"`
Expected: FAIL — `Preset.LLMSpec.init(provider:model:)` doesn't exist.

- [ ] **Step 3: Add `model` to `LLMSpec`**

In `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/Preset.swift`, replace the `LLMSpec` block:

```swift
    public struct LLMSpec: Codable, Equatable, Sendable {
        public let provider: String
        public let model: String?

        public init(provider: String, model: String? = nil) {
            self.provider = provider
            self.model = model
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(provider, forKey: .provider)
            if let model { try c.encode(model, forKey: .model) }
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.provider = try c.decode(String.self, forKey: .provider)
            self.model = try c.decodeIfPresent(String.self, forKey: .model)
        }

        enum CodingKeys: String, CodingKey { case provider, model }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mac && swift test --filter "Preset.LLMSpec.model coding"`
Expected: PASS (all four tests).

- [ ] **Step 5: Run the full SwiftPM test suite to catch ripple effects**

Run: `cd mac && swift test`
Expected: PASS — `UserSettingsApplyPresetTests` constructs `Preset` with `.init(provider:)` (single arg); the Swift default-arg `model: nil` keeps that compiling.

- [ ] **Step 6: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/Preset.swift mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/PresetLLMModelCodingTests.swift
git commit -m "feat(core): Preset.LLMSpec gains optional model (omit-when-nil)"
```

### Task A4: Swift — `applying(preset:)` stamps `llmModel` when preset has one

**Files:**
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/SettingsStore.swift`
- Test: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/UserSettingsApplyPresetTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `UserSettingsApplyPresetTests.swift` inside the existing `@Suite` struct:

```swift
    // MARK: - LLM model stamping (per-preset override)

    @Test func applying_preset_with_llmModel_stampsModel() {
        let preset = Preset(
            name: "test",
            description: "",
            frameStages: [.init(name: "denoise", enabled: true), .init(name: "decimate3", enabled: true)],
            chunkStages: [.init(name: "tse", enabled: true, backend: "ecapa", threshold: 0.0)],
            transcribe: .init(modelSize: "small"),
            llm: .init(provider: "anthropic", model: "claude-haiku-4-5"),
            timeoutSec: 10
        )
        var base = UserSettings()
        base.llmModel = "claude-sonnet-4-6"  // user's previous global default
        let result = base.applying(preset)
        #expect(result.llmModel == "claude-haiku-4-5")
    }

    @Test func applying_preset_without_llmModel_preservesGlobalModel() {
        let preset = Preset(
            name: "test",
            description: "",
            frameStages: [.init(name: "denoise", enabled: true), .init(name: "decimate3", enabled: true)],
            chunkStages: [.init(name: "tse", enabled: true, backend: "ecapa", threshold: 0.0)],
            transcribe: .init(modelSize: "small"),
            llm: .init(provider: "anthropic", model: nil),  // explicit nil
            timeoutSec: 10
        )
        var base = UserSettings()
        base.llmModel = "claude-sonnet-4-6"
        let result = base.applying(preset)
        #expect(result.llmModel == "claude-sonnet-4-6")  // preserved
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac && swift test --filter UserSettingsApplyPresetTests`
Expected: FAIL — `applying_preset_with_llmModel_stampsModel` fails (`result.llmModel` stays at `claude-sonnet-4-6` because the existing implementation doesn't read `preset.llm.model`).

- [ ] **Step 3: Update `applying(_:)` in `SettingsStore.swift`**

Find the line `s.llmProvider = preset.llm.provider` (around line 124) and add immediately after it:

```swift
        if let m = preset.llm.model {
            s.llmModel = m
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mac && swift test --filter UserSettingsApplyPresetTests`
Expected: PASS — both new tests + all existing ones.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/SettingsStore.swift mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/UserSettingsApplyPresetTests.swift
git commit -m "feat(settings): applying(preset:) stamps llmModel when preset pins one"
```

---

## Phase B — Shared catalogs

### Task B1: Create `LLMProviderCatalog`

**Files:**
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/LLM/LLMProviderCatalog.swift`
- Test: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/LLMProviderCatalogTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `LLMProviderCatalogTests.swift`:

```swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("LLMProviderCatalog")
struct LLMProviderCatalogTests {

    @Test func providers_listed_in_canonical_order() {
        let ids = LLMProviderCatalog.providers.map { $0.id }
        #expect(ids == ["anthropic", "openai", "ollama", "lmstudio"])
    }

    @Test func defaultModel_returns_a_curated_model_for_cloud_providers() {
        for id in ["anthropic", "openai"] {
            let dflt = LLMProviderCatalog.defaultModel(for: id)
            #expect(!dflt.isEmpty, "expected non-empty default for \(id)")
            #expect(LLMProviderCatalog.curatedModels(for: id).contains(dflt),
                    "default \(dflt) for \(id) should be in curated list")
        }
    }

    @Test func defaultModel_is_empty_for_local_providers() {
        #expect(LLMProviderCatalog.defaultModel(for: "ollama") == "")
        #expect(LLMProviderCatalog.defaultModel(for: "lmstudio") == "")
    }

    @Test func modelBelongs_matches_provider_prefix_rules() {
        #expect(LLMProviderCatalog.modelBelongs("claude-sonnet-4-6", to: "anthropic"))
        #expect(LLMProviderCatalog.modelBelongs("gpt-4o-mini", to: "openai"))
        #expect(LLMProviderCatalog.modelBelongs("o1-preview", to: "openai"))
        #expect(!LLMProviderCatalog.modelBelongs("claude-sonnet-4-6", to: "openai"))
        #expect(!LLMProviderCatalog.modelBelongs("anything", to: "ollama"))
        #expect(!LLMProviderCatalog.modelBelongs("anything", to: "lmstudio"))
    }

    @Test func curatedModels_nonempty_for_cloud_providers() {
        #expect(!LLMProviderCatalog.curatedModels(for: "anthropic").isEmpty)
        #expect(!LLMProviderCatalog.curatedModels(for: "openai").isEmpty)
    }

    @Test func curatedModels_empty_for_local_providers() {
        #expect(LLMProviderCatalog.curatedModels(for: "ollama").isEmpty)
        #expect(LLMProviderCatalog.curatedModels(for: "lmstudio").isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mac && swift test --filter LLMProviderCatalog`
Expected: FAIL — `LLMProviderCatalog` doesn't exist.

- [ ] **Step 3: Create the catalog**

Create `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/LLM/LLMProviderCatalog.swift`:

```swift
// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/LLM/LLMProviderCatalog.swift
import Foundation

/// Single source of truth for the LLM provider list, the default
/// model per provider, the model→provider belonging predicate, and a
/// curated fallback model list for each cloud provider.
///
/// Consumed by both Settings → LLM Provider (full UI with API-key auth +
/// dynamic API-side model fetch) and Settings → Pipeline → Editor (per-
/// preset model override, no auth, picks from the curated list).
///
/// For local providers (ollama, lmstudio) the curated list is empty —
/// model lists are device-local and fetched at runtime by their
/// respective Section views; the per-preset editor binds to a free-
/// form text model name in those cases.
public enum LLMProviderCatalog {

    public static let providers: [(id: String, label: String)] = [
        ("anthropic", "Anthropic — cloud"),
        ("openai",    "OpenAI — cloud"),
        ("ollama",    "Ollama — local"),
        ("lmstudio",  "LM Studio — local"),
    ]

    /// Default model id for the named provider. Empty for local
    /// providers (the per-section auto-detect picks one).
    public static func defaultModel(for provider: String) -> String {
        switch provider {
        case "anthropic": return "claude-sonnet-4-6"
        case "openai":    return "gpt-4o-mini"
        case "ollama":    return ""
        case "lmstudio":  return ""
        default:          return ""
        }
    }

    /// Whether `model` is plausibly served by `provider`. Used to decide
    /// whether a provider switch should reset the model field. Local
    /// providers always return false: their model identifiers are
    /// device-local and not interchangeable with cloud providers.
    public static func modelBelongs(_ model: String, to provider: String) -> Bool {
        switch provider {
        case "anthropic":          return model.hasPrefix("claude-")
        case "openai":             return model.hasPrefix("gpt-") || model.hasPrefix("o1")
        case "ollama", "lmstudio": return false
        default:                   return false
        }
    }

    /// Static curated list of common models for the named provider.
    /// Used as the dropdown options in the Pipeline editor's per-preset
    /// llm body, where there is no API key to drive a dynamic fetch.
    /// Empty for local providers.
    public static func curatedModels(for provider: String) -> [String] {
        switch provider {
        case "anthropic":
            return [
                "claude-opus-4-7",
                "claude-sonnet-4-6",
                "claude-haiku-4-5",
            ]
        case "openai":
            return [
                "gpt-4o",
                "gpt-4o-mini",
                "gpt-4-turbo",
                "o1-preview",
                "o1-mini",
            ]
        case "ollama", "lmstudio":
            return []
        default:
            return []
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mac && swift test --filter LLMProviderCatalog`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/LLM/LLMProviderCatalog.swift mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/LLMProviderCatalogTests.swift
git commit -m "feat(llm): add LLMProviderCatalog as single source of truth"
```

### Task B2: Refactor `ProviderTab` to use the catalog (provider list + defaults + modelBelongs)

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/ProviderTab.swift`

- [ ] **Step 1: Replace the in-file static tables with catalog calls**

In `mac/VoiceKeyboard/UI/Settings/ProviderTab.swift`, delete:

```swift
    private static let providers: [(id: String, label: String)] = [
        ("anthropic", "Anthropic — cloud"),
        ("openai",    "OpenAI — cloud"),
        ("ollama",    "Ollama — local"),
        ("lmstudio",  "LM Studio — local"),
    ]

    private static let defaultModels: [String: String] = [
        "anthropic": "claude-sonnet-4-6",
        "openai":    "gpt-4o-mini",
        "ollama":    "",
        "lmstudio":  "",
    ]

    private static func modelBelongs(_ model: String, to provider: String) -> Bool {
        switch provider {
        case "anthropic":          return model.hasPrefix("claude-")
        case "openai":             return model.hasPrefix("gpt-") || model.hasPrefix("o1")
        case "ollama", "lmstudio": return false
        default:                   return false
        }
    }
```

Then update the `Picker` block to read from the catalog:

```swift
            Picker("Provider", selection: Binding(
                get: { settings.llmProvider },
                set: { newProvider in
                    var next = settings
                    next.llmProvider = newProvider
                    if !LLMProviderCatalog.modelBelongs(next.llmModel, to: newProvider) {
                        next.llmModel = LLMProviderCatalog.defaultModel(for: newProvider)
                    }
                    settings = next
                }
            )) {
                ForEach(LLMProviderCatalog.providers, id: \.id) { p in
                    Text(p.label).tag(p.id)
                }
            }
```

- [ ] **Step 2: Build the Mac app to verify no regressions**

Run: `cd mac && make build`
Expected: PASS — Debug build succeeds.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/ProviderTab.swift
git commit -m "refactor(provider): consume LLMProviderCatalog instead of inline tables"
```

### Task B3: Create `DictStats` helper

**Files:**
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/DictStats.swift`
- Test: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/DictStatsTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/DictStatsTests.swift`:

```swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("DictStats")
struct DictStatsTests {

    @Test func empty_dict_is_zero() {
        let s = DictStats.compute(from: [])
        #expect(s.words == 0)
        #expect(s.chars == 0)
        #expect(s.tokens == 0)
    }

    @Test func single_term_counts_as_one_word() {
        let s = DictStats.compute(from: ["MCP"])
        #expect(s.words == 1)
        #expect(s.chars == 3)             // "MCP"
        #expect(s.tokens == 1)            // ceil(3/4)
    }

    @Test func multiple_terms_joined_with_comma_space() {
        // payload = "MCP, WebRTC" -> 11 chars -> ceil(11/4) = 3 tokens
        let s = DictStats.compute(from: ["MCP", "WebRTC"])
        #expect(s.words == 2)
        #expect(s.chars == 11)
        #expect(s.tokens == 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mac && swift test --filter DictStats`
Expected: FAIL — `DictStats` doesn't exist.

- [ ] **Step 3: Create the helper**

Create `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/DictStats.swift`:

```swift
// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/DictStats.swift
import Foundation

/// Token/word counts for the custom-dictionary cleanup-prompt
/// substitution. Mirrors the Go side's `strings.Join(terms, ", ")` so
/// the chars and rough-token count match what the LLM actually sees.
///
/// Token estimate is char-count / 4 rounded up — biased a touch
/// conservative (overcount > undercount). The cleanup prompt template
/// itself adds another ~60 tokens regardless of the dictionary.
public enum DictStats {
    public struct Snapshot: Equatable, Sendable {
        public let words: Int
        public let chars: Int
        public let tokens: Int
    }

    public static func compute(from terms: [String]) -> Snapshot {
        guard !terms.isEmpty else { return .init(words: 0, chars: 0, tokens: 0) }
        let payload = terms.joined(separator: ", ")
        let chars = payload.count
        let tokens = Int((Double(chars) / 4.0).rounded(.up))
        return .init(words: terms.count, chars: chars, tokens: tokens)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mac && swift test --filter DictStats`
Expected: PASS.

- [ ] **Step 5: Refactor `DictionaryTab.swift` to use the shared helper**

In `mac/VoiceKeyboard/UI/Settings/DictionaryTab.swift`, replace:

```swift
    private func dictStats() -> (words: Int, chars: Int, tokens: Int) {
        let terms = settings.customDict
        guard !terms.isEmpty else { return (0, 0, 0) }
        let payload = terms.joined(separator: ", ")
        let chars = payload.count
        let tokens = Int((Double(chars) / 4.0).rounded(.up))
        return (terms.count, chars, tokens)
    }
```

with:

```swift
    private func dictStats() -> DictStats.Snapshot {
        DictStats.compute(from: settings.customDict)
    }
```

The `statsView` body already destructures via `let s = dictStats()` followed by `s.words` / `s.tokens`; since `DictStats.Snapshot` exposes those names, no further edit is required.

- [ ] **Step 6: Build to verify**

Run: `cd mac && make build`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/DictStats.swift mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/DictStatsTests.swift mac/VoiceKeyboard/UI/Settings/DictionaryTab.swift
git commit -m "refactor(dict): extract DictStats helper to VoiceKeyboardCore"
```

---

## Phase C — Bundled-name source of truth

### Task C1: Create `Preset.bundledNames` + `isBundled`

**Files:**
- Create: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/BundledPresetNames.swift`
- Test: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/BundledPresetNamesTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `BundledPresetNamesTests.swift`:

```swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("Preset.bundledNames")
struct BundledPresetNamesTests {

    @Test func bundledNames_matches_known_set() {
        // Mirrors core/internal/presets/pipeline-presets.json. If a
        // bundled preset is added/removed there, update both the JSON
        // and this set together.
        #expect(Preset.bundledNames == ["default", "minimal", "aggressive", "paranoid"])
    }

    @Test func isBundled_true_for_bundled_names() {
        let p = Preset(
            name: "paranoid",
            description: "",
            frameStages: [], chunkStages: [],
            transcribe: .init(modelSize: "small"),
            llm: .init(provider: "anthropic")
        )
        #expect(p.isBundled == true)
    }

    @Test func isBundled_false_for_user_names() {
        let p = Preset(
            name: "my-custom",
            description: "",
            frameStages: [], chunkStages: [],
            transcribe: .init(modelSize: "small"),
            llm: .init(provider: "anthropic")
        )
        #expect(p.isBundled == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mac && swift test --filter "Preset.bundledNames"`
Expected: FAIL — symbol doesn't exist.

- [ ] **Step 3: Create the source file**

Create `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/BundledPresetNames.swift`:

```swift
// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/BundledPresetNames.swift
import Foundation

extension Preset {
    /// Names of the bundled (built-in, non-deletable) presets shipped
    /// with the engine. Mirrors the names declared in
    /// `core/internal/presets/pipeline-presets.json`.
    ///
    /// The Go core enforces immutability of these names via
    /// `presets.ErrReservedName` — Save/Delete on a bundled name fails
    /// with rc != 0 from the C ABI. This Swift constant is a cosmetic
    /// mirror used by the UI to disable in-place editing and label the
    /// picker rows. If a bundled preset is added or removed in the
    /// JSON, update this set in the same commit.
    public static let bundledNames: Set<String> = [
        "default",
        "minimal",
        "aggressive",
        "paranoid",
    ]

    /// Whether this preset is one of the bundled built-ins (read-only).
    public var isBundled: Bool { Self.bundledNames.contains(name) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mac && swift test --filter "Preset.bundledNames"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/BundledPresetNames.swift mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/BundledPresetNamesTests.swift
git commit -m "feat(presets): expose Preset.bundledNames + isBundled"
```

### Task C2: Refactor `SaveAsPresetSheet` to consume the shared set

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/SaveAsPresetSheet.swift`

- [ ] **Step 1: Replace the inline reserved set**

In `mac/VoiceKeyboard/UI/Settings/Pipeline/SaveAsPresetSheet.swift`, replace:

```swift
    private var nameAvailable: Bool {
        let reserved: Set<String> = ["default", "minimal", "aggressive", "paranoid"]
        return !reserved.contains(name)
    }
```

with:

```swift
    private var nameAvailable: Bool {
        !Preset.bundledNames.contains(name)
    }
```

- [ ] **Step 2: Build to verify**

Run: `cd mac && make build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/SaveAsPresetSheet.swift
git commit -m "refactor(save-as): read reserved set from Preset.bundledNames"
```

---

## Phase D — `PresetDraft` extension for per-preset model

### Task D1: Add `llmModel` to `PresetDraft` + dirty / save / reset wiring

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/PresetDraft.swift`

- [ ] **Step 1: Replace the file with the updated implementation**

In `mac/VoiceKeyboard/UI/Settings/Pipeline/PresetDraft.swift`:

Add the new property right under `var llmProvider: String`:

```swift
    /// Per-preset LLM model. When the preset's source had `llm.model = nil`,
    /// the draft initializes this from the global default for the
    /// provider via LLMProviderCatalog.defaultModel(for:); save will
    /// then emit a non-nil model in the JSON.
    var llmModel: String
```

In `init(_ source: Preset)`, replace:

```swift
        self.llmProvider = source.llm.provider
        self.timeoutSec = source.timeoutSec ?? 10
```

with:

```swift
        self.llmProvider = source.llm.provider
        self.llmModel = source.llm.model ?? LLMProviderCatalog.defaultModel(for: source.llm.provider)
        self.timeoutSec = source.timeoutSec ?? 10
```

In `isDirty`, add (right before `return false`):

```swift
        if llmModel != (source.llm.model ?? LLMProviderCatalog.defaultModel(for: source.llm.provider)) { return true }
```

In `resetTo(_:)`, add (right after `llmProvider = preset.llm.provider`):

```swift
        llmModel = preset.llm.model ?? LLMProviderCatalog.defaultModel(for: preset.llm.provider)
```

In `toPreset(name:description:)`, replace the `llm: .init(provider: llmProvider)` line with:

```swift
            llm: .init(provider: llmProvider, model: llmModel),
```

Add the two new mutators near the end of the class, above `func stage(for ref: StageRef)`:

```swift
    /// Set the LLM provider. If the current model doesn't belong to the
    /// new provider (per LLMProviderCatalog.modelBelongs) the model is
    /// reset to that provider's default. Mirrors LLMProviderTab's
    /// provider-switch behavior so editor and tab agree.
    func setLLMProvider(_ provider: String) {
        llmProvider = provider
        if !LLMProviderCatalog.modelBelongs(llmModel, to: provider) {
            llmModel = LLMProviderCatalog.defaultModel(for: provider)
        }
    }

    func setLLMModel(_ model: String) {
        llmModel = model
    }
```

- [ ] **Step 2: Build to verify all references compile**

Run: `cd mac && make build`
Expected: PASS.

- [ ] **Step 3: Run SwiftPM tests (existing tests use `Preset.LLMSpec(provider:)` — should still compile via the default model: nil arg)**

Run: `cd mac && swift test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/PresetDraft.swift
git commit -m "feat(preset-draft): track llmModel and reset on provider switch"
```

---

## Phase E — Tab rename: Provider → LLM Provider

### Task E1: Rename file + struct

**Files:**
- Rename: `mac/VoiceKeyboard/UI/Settings/ProviderTab.swift` → `LLMProviderTab.swift`

- [ ] **Step 1: Use git to rename the file**

Run: `git mv mac/VoiceKeyboard/UI/Settings/ProviderTab.swift mac/VoiceKeyboard/UI/Settings/LLMProviderTab.swift`

- [ ] **Step 2: Rename the struct**

In the renamed file, replace `struct ProviderTab` with `struct LLMProviderTab`. Update the leading file path comment if present.

- [ ] **Step 3: Update the call site in `SettingsView.swift`**

In `mac/VoiceKeyboard/UI/Settings/SettingsView.swift`:

Find the `.provider` case in the `pageBody` switch:

```swift
        case .provider:
            ProviderTab(settings: $settings, onSave: save, secrets: composition.secrets)
```

Replace with:

```swift
        case .provider:
            LLMProviderTab(settings: $settings, onSave: save, secrets: composition.secrets)
```

Also update the `title` property of `SettingsPage`:

```swift
        case .provider:   return "Provider"
```

becomes:

```swift
        case .provider:   return "LLM Provider"
```

- [ ] **Step 4: Regenerate the Xcode project (the new file needs to be picked up)**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project`
Expected: PASS — fresh project.pbxproj generated.

- [ ] **Step 5: Build to verify**

Run: `cd mac && make build`
Expected: PASS.

- [ ] **Step 6: Search for any stale "Provider" references in user-visible copy**

Run: `grep -rn "Provider tab\|the Provider\|in Provider" mac/VoiceKeyboard/ docs/ 2>/dev/null | grep -vE "(LLMProvider|llm[-_]provider|provider:|Provider — cloud|Provider — local|Provider == |\.provider)"`

If any user-visible copy turns up (e.g. onboarding, README), update it to "LLM Provider".

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(settings): rename Provider tab to LLM Provider"
```

---

## Phase F — `StageRef` + `ManageElsewhereButton` + plumbing

### Task F1: Add `.terminal` lane to `StageRef`

**Files:**
- Modify: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/StageRef.swift`

- [ ] **Step 1: Add the new lane case**

Replace the enum line in `StageRef.swift`:

```swift
    public enum Lane: String, Hashable, Codable, Sendable { case frame, chunk }
```

with:

```swift
    public enum Lane: String, Hashable, Codable, Sendable { case frame, chunk, terminal }
```

- [ ] **Step 2: Build SwiftPM to confirm no immediate compile breaks**

Run: `cd mac && swift build`
Expected: PASS — switch statements over `Lane` in tests/source must remain exhaustive. (`PresetDraft` reads `ref.lane` only via `switch` over frame/chunk in `setEnabled`, `setBackend`, `setThreshold`, `stage(for:)`. These need a `default: return` clause — see next step.)

- [ ] **Step 3: Update `PresetDraft.swift` switches to handle `.terminal`**

In `mac/VoiceKeyboard/UI/Settings/Pipeline/PresetDraft.swift`, each of `setEnabled`, `setBackend`, `setThreshold`, `stage(for:)` switches over `ref.lane`. Add a `case .terminal: return` (or `case .terminal: return nil` for `stage(for:)`) to each. Final shape of `setEnabled`:

```swift
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
        case .terminal:
            return  // terminal stages don't have toggles
        }
    }
```

`setBackend` and `setThreshold` similarly add `case .terminal: return`. `stage(for:)` adds `case .terminal: return nil`.

- [ ] **Step 4: Run tests to confirm**

Run: `cd mac && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/StageRef.swift mac/VoiceKeyboard/UI/Settings/Pipeline/PresetDraft.swift
git commit -m "feat(stage-ref): add .terminal lane"
```

### Task F2: Create `ManageElsewhereButton`

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/ManageElsewhereButton.swift`

- [ ] **Step 1: Write the file**

Create `mac/VoiceKeyboard/UI/Settings/Pipeline/ManageElsewhereButton.swift`:

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/ManageElsewhereButton.swift
import SwiftUI

/// Small chevron button used in the Pipeline editor's terminal-stage
/// bodies to deep-link the user to the source-of-truth Settings page
/// (General for whisper, Dictionary for dict, LLM Provider for llm).
///
/// Mirrors the visual style of PresetBanner's "Configure…" button:
/// `Label + systemImage` at small control size.
struct ManageElsewhereButton: View {
    let target: SettingsPage
    let label: String
    let navigateTo: (SettingsPage) -> Void

    var body: some View {
        Button {
            navigateTo(target)
        } label: {
            Label(label, systemImage: "arrow.up.right.square")
        }
        .controlSize(.small)
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project to pick up the new source**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project`

- [ ] **Step 3: Build to confirm**

Run: `cd mac && make build`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/ManageElsewhereButton.swift
git commit -m "feat(pipeline-ui): add ManageElsewhereButton for deep-link rows"
```

### Task F3: Plumb `settings` and `navigateTo` into `EditorView`

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift`
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift`
- Modify: `mac/VoiceKeyboard/UI/Settings/SettingsView.swift`

- [ ] **Step 1: Update `PipelineTab` to accept and forward the new params**

In `mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift`, replace the struct properties:

```swift
struct PipelineTab: View {
    let engine: any CoreEngine
    let sessions: any SessionsClient
    let presets: any PresetsClient
    let replay: any ReplayClient
```

with:

```swift
struct PipelineTab: View {
    let engine: any CoreEngine
    let sessions: any SessionsClient
    let presets: any PresetsClient
    let replay: any ReplayClient
    @Binding var settings: UserSettings
    let navigateTo: (SettingsPage) -> Void
```

In `body`, update the editor case:

```swift
            case .editor:
                EditorView(presets: presets, sessions: sessions)
```

becomes:

```swift
            case .editor:
                EditorView(
                    presets: presets,
                    sessions: sessions,
                    settings: $settings,
                    navigateTo: navigateTo
                )
```

- [ ] **Step 2: Update `EditorView` signature**

In `mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift`, add to the struct properties (right after `let sessions: any SessionsClient`):

```swift
    @Binding var settings: UserSettings
    let navigateTo: (SettingsPage) -> Void
```

Don't yet wire them into the body — the layout overhaul in Phase G/H consumes them.

- [ ] **Step 3: Update the `.pipeline` case in `SettingsView.swift`**

In `mac/VoiceKeyboard/UI/Settings/SettingsView.swift`, replace:

```swift
        case .pipeline:
            PipelineTab(
                engine: composition.engine,
                sessions: LibVKBSessionsClient(engine: composition.engine),
                presets: LibVKBPresetsClient(engine: composition.engine),
                replay: LibVKBReplayClient(engine: composition.engine)
            )
```

with:

```swift
        case .pipeline:
            PipelineTab(
                engine: composition.engine,
                sessions: LibVKBSessionsClient(engine: composition.engine),
                presets: LibVKBPresetsClient(engine: composition.engine),
                replay: LibVKBReplayClient(engine: composition.engine),
                settings: $settings,
                navigateTo: navigateTo
            )
```

- [ ] **Step 4: Build to verify**

Run: `cd mac && make build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/PipelineTab.swift mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift mac/VoiceKeyboard/UI/Settings/SettingsView.swift
git commit -m "feat(pipeline-ui): plumb settings + navigateTo into EditorView"
```

---

## Phase G — `StageList` + terminal-stage rows

### Task G1: Rename `StageGraph.swift` → `StageList.swift` and rename the struct

**Files:**
- Rename: `mac/VoiceKeyboard/UI/Settings/Pipeline/StageGraph.swift` → `StageList.swift`

- [ ] **Step 1: Use git to rename**

Run: `git mv mac/VoiceKeyboard/UI/Settings/Pipeline/StageGraph.swift mac/VoiceKeyboard/UI/Settings/Pipeline/StageList.swift`

- [ ] **Step 2: Rename `struct StageGraph` to `struct StageList`**

In the renamed file, replace `struct StageGraph` with `struct StageList`. Update the file-path comment at the top.

- [ ] **Step 3: Update the call site in `EditorView.swift`**

Find `StageGraph(draft: draft)` in `EditorView.swift` and change to `StageList(draft: draft, ...)` — but the additional bindings come in Task G2. For now, just `StageList(draft: draft)`.

- [ ] **Step 4: Regenerate Xcode project + build**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project && make build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(pipeline-ui): rename StageGraph -> StageList"
```

### Task G2: Make terminal-stage rows selectable + restructure layout

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/StageList.swift`

- [ ] **Step 1: Replace the file body**

Replace the entire contents of `mac/VoiceKeyboard/UI/Settings/Pipeline/StageList.swift` with:

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/StageList.swift
import SwiftUI
import VoiceKeyboardCore

/// Left-column stage list for the Pipeline editor. Three sections:
///
/// - Streaming      (frame stages: denoise, decimate3)
/// - Per-utterance  (chunk stages: tse) — separated above by a CHUNKER divider
/// - Transcribe + cleanup (terminal stages: whisper, dict, llm) — selectable rows
///                  whose right-pane bodies live in StageDetailPane.
///
/// Toggle checkboxes on frame/chunk rows mutate `draft.setEnabled(...)` —
/// terminal rows have no toggle (they're always part of the pipeline)
/// and a chevron indicator instead.
///
/// All rows respect `editingDisabled` so bundled-preset selection
/// renders the controls dimmed; tapping a disabled control fires
/// `nudgeSaveAs` so EditorView can pulse the Save as… button.
struct StageList: View {
    @Bindable var draft: PresetDraft
    let editingDisabled: Bool
    let nudgeSaveAs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            laneHeader("Streaming", subtitle: "frame-rate; runs on every pushed buffer")
            frameLane

            chunkerBoundary

            laneHeader("Per-utterance", subtitle: "chunk-rate; runs once per utterance chunk")
            chunkLane

            laneHeader("Transcribe + cleanup", subtitle: "fixed terminal chain")
            terminalLane
        }
    }

    // MARK: - Headers + boundary

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

    // MARK: - Frame + chunk lanes

    @ViewBuilder
    private var frameLane: some View {
        VStack(spacing: 4) {
            ForEach(draft.frameStages, id: \.name) { stage in
                stageRow(stage, lane: .frame)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var chunkLane: some View {
        VStack(spacing: 4) {
            ForEach(draft.chunkStages, id: \.name) { stage in
                stageRow(stage, lane: .chunk)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Terminal lane (whisper / dict / llm)

    @ViewBuilder
    private var terminalLane: some View {
        VStack(alignment: .leading, spacing: 4) {
            terminalRow(name: "whisper", subtitle: draft.transcribeModelSize)
            terminalRow(name: "dict",    subtitle: "fuzzy correction")
            terminalRow(name: "llm",     subtitle: llmSubtitle)
        }
        .padding(.vertical, 4)
    }

    private var llmSubtitle: String {
        if draft.llmModel.isEmpty {
            return draft.llmProvider
        }
        return "\(draft.llmProvider) · \(draft.llmModel)"
    }

    // MARK: - Rows

    @ViewBuilder
    private func stageRow(_ stage: Preset.StageSpec, lane: StageRef.Lane) -> some View {
        let ref = StageRef(lane: lane, name: stage.name)
        let isSelected = draft.selectedStage == ref
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { stage.enabled },
                set: { draft.setEnabled($0, for: ref) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(editingDisabled)
            // Disabled-tap handler: nudges the Save as… button.
            .background(
                editingDisabled
                    ? Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { nudgeSaveAs() }
                    : nil
            )

            Text(stage.name).font(.callout).bold()
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            if let backend = stage.backend, !backend.isEmpty {
                Text(backend)
                    .font(.caption.monospaced())
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
            Spacer()
            Text(lane == .frame ? "frame" : "chunk")
                .font(.caption2)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture {
            draft.selectedStage = (draft.selectedStage == ref) ? nil : ref
        }
    }

    @ViewBuilder
    private func terminalRow(name: String, subtitle: String) -> some View {
        let ref = StageRef(lane: .terminal, name: name)
        let isSelected = draft.selectedStage == ref
        HStack {
            Image(systemName: "chevron.right")
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                .font(.caption)
                .frame(width: 14)
            Text(name).font(.callout).bold()
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Text(subtitle).font(.caption.monospaced())
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture {
            draft.selectedStage = (draft.selectedStage == ref) ? nil : ref
        }
    }
}
```

- [ ] **Step 2: Build to verify (EditorView's old call signature breaks intentionally)**

Run: `cd mac && make build`
Expected: FAIL — `EditorView.swift` calls `StageList(draft: draft)` without the new args.

- [ ] **Step 3: Update EditorView's StageList call temporarily so the build compiles**

In `mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift`, replace:

```swift
                        StageList(draft: draft)
```

with:

```swift
                        StageList(draft: draft, editingDisabled: false, nudgeSaveAs: {})
```

(This is interim — Task H1 wires the real values.)

- [ ] **Step 4: Build again**

Run: `cd mac && make build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/StageList.swift mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift
git commit -m "feat(pipeline-ui): selectable terminal-stage rows + bundled-disable nudge hook"
```

---

## Phase H — `StageDetailPane` + terminal-stage bodies

### Task H1: Rename `StageDetailPanel.swift` → `StageDetailPane.swift`

**Files:**
- Rename: `mac/VoiceKeyboard/UI/Settings/Pipeline/StageDetailPanel.swift` → `StageDetailPane.swift`

- [ ] **Step 1: git mv + struct rename**

Run: `git mv mac/VoiceKeyboard/UI/Settings/Pipeline/StageDetailPanel.swift mac/VoiceKeyboard/UI/Settings/Pipeline/StageDetailPane.swift`

In the renamed file, change `struct StageDetailPanel` to `struct StageDetailPane`. Update the file-path comment.

- [ ] **Step 2: Update the call site in `EditorView.swift`**

Replace `StageDetailPanel(draft: draft, sessions: sessions)` with `StageDetailPane(draft: draft, sessions: sessions, settings: $settings, editingDisabled: false, navigateTo: navigateTo)`. (The new params are added in Task H2; Step 2 sets the call site so we don't have to edit it again.)

- [ ] **Step 3: Regenerate project + build (will fail on the new args until H2)**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project`

(Skip `make build` — Task H2 finishes the pane signature.)

### Task H2: Extend `StageDetailPane` to handle the `.terminal` lane + new params

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/StageDetailPane.swift`

- [ ] **Step 1: Replace the entire file**

Replace `mac/VoiceKeyboard/UI/Settings/Pipeline/StageDetailPane.swift` with:

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/StageDetailPane.swift
import SwiftUI
import VoiceKeyboardCore

/// Right-pane detail view. Switches on the selected stage:
///   - nil:                   placeholder
///   - .frame:                "no tunables" hint + Enabled is on the row
///   - .chunk(tse):           backend / threshold / recent similarity
///   - .terminal(whisper):    model-size picker + "Manage in General →"
///   - .terminal(dict):       N-terms + "Edit in Dictionary →"
///   - .terminal(llm):        provider + model + "Manage in LLM Provider →"
///
/// All editable controls dim when `editingDisabled` is true. Bodies for
/// the three terminal stages live in TerminalStageBodies.swift.
struct StageDetailPane: View {
    @Bindable var draft: PresetDraft
    let sessions: any SessionsClient
    @Binding var settings: UserSettings
    let editingDisabled: Bool
    let navigateTo: (SettingsPage) -> Void

    @State private var recentSimilarities: [Float] = []
    @State private var loadError: String? = nil

    var body: some View {
        if let ref = draft.selectedStage {
            VStack(alignment: .leading, spacing: 10) {
                header(ref: ref)
                Divider()
                content(for: ref)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: ref) {
                if ref.lane == .chunk && ref.name == "tse" {
                    await refreshSimilarity()
                }
            }
            .disabled(editingDisabled)
        } else {
            Text("Select a stage to edit its tunables.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    @ViewBuilder
    private func header(ref: StageRef) -> some View {
        HStack {
            Text(ref.name).font(.callout).bold()
            Text("(\(laneLabel(ref.lane)))").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Deselect") { draft.selectedStage = nil }
                .controlSize(.small)
        }
    }

    private func laneLabel(_ lane: StageRef.Lane) -> String {
        switch lane {
        case .frame:    return "frame"
        case .chunk:    return "chunk"
        case .terminal: return "terminal"
        }
    }

    @ViewBuilder
    private func content(for ref: StageRef) -> some View {
        switch ref.lane {
        case .frame:
            Text("No tunables — toggle this stage on or off via the checkbox in the row.")
                .font(.caption).foregroundStyle(.secondary)
        case .chunk:
            if ref.name == "tse", let stage = draft.stage(for: ref) {
                tseBody(ref: ref, stage: stage)
            } else {
                Text("No tunables.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .terminal:
            switch ref.name {
            case "whisper":
                WhisperStageBody(draft: draft, navigateTo: navigateTo)
            case "dict":
                DictStageBody(settings: $settings, navigateTo: navigateTo)
            case "llm":
                LLMStageBody(draft: draft, navigateTo: navigateTo)
            default:
                Text("Unknown terminal stage \(ref.name)")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Existing tse body (unchanged from StageDetailPanel)

    @ViewBuilder
    private func tseBody(ref: StageRef, stage: Preset.StageSpec) -> some View {
        backendRow(ref: ref, stage: stage)
        thresholdRow(ref: ref, stage: stage)
        recentSimilarityRow(stage: stage)
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

- [ ] **Step 2: Don't build yet — terminal bodies are stubbed**

The file references `WhisperStageBody`, `DictStageBody`, `LLMStageBody` which don't exist yet. Move to H3.

### Task H3: Create `TerminalStageBodies.swift`

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/TerminalStageBodies.swift`

- [ ] **Step 1: Write the file**

Create `mac/VoiceKeyboard/UI/Settings/Pipeline/TerminalStageBodies.swift`:

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/TerminalStageBodies.swift
import SwiftUI
import VoiceKeyboardCore

// MARK: - Whisper

/// Per-preset whisper model picker. Shows the same labels as
/// GeneralTab (✓ prefix for downloaded sizes), but does not start
/// downloads — the user follows the deep-link to General for that.
struct WhisperStageBody: View {
    @Bindable var draft: PresetDraft
    let navigateTo: (SettingsPage) -> Void

    private let modelSizes: [(size: String, label: String, mb: String)] = [
        ("tiny",   "Tiny",   "75 MB"),
        ("base",   "Base",   "142 MB"),
        ("small",  "Small",  "466 MB"),
        ("medium", "Medium", "1.5 GB"),
        ("large",  "Large",  "2.9 GB"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Model size").frame(width: 96, alignment: .leading)
                Picker("", selection: Binding(
                    get: { draft.transcribeModelSize },
                    set: { draft.transcribeModelSize = $0 }
                )) {
                    ForEach(modelSizes, id: \.size) { m in
                        Text(label(for: m)).tag(m.size)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer()
            }
            Text("Per-preset whisper model. Manage which models are downloaded in General → Whisper model.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                ManageElsewhereButton(target: .general, label: "Manage in General →", navigateTo: navigateTo)
            }
        }
    }

    private func label(for m: (size: String, label: String, mb: String)) -> String {
        let path = ModelPaths.whisperModel(size: m.size).path
        let mark = FileManager.default.fileExists(atPath: path) ? "✓" : " "
        return "\(mark) \(m.label) (\(m.mb))"
    }
}

// MARK: - Dict (read-only)

/// Read-only summary of the global custom dictionary. Per-preset
/// override isn't supported — every preset uses the same terms.
struct DictStageBody: View {
    @Binding var settings: UserSettings
    let navigateTo: (SettingsPage) -> Void

    var body: some View {
        let s = DictStats.compute(from: settings.customDict)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(s.words) word\(s.words == 1 ? "" : "s") · ~\(s.tokens) token\(s.tokens == 1 ? "" : "s")")
                    .font(.callout.monospacedDigit())
                Spacer()
            }
            Text("Custom dictionary is global — every preset uses the same terms. Manage them in Dictionary.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                ManageElsewhereButton(target: .dictionary, label: "Edit in Dictionary →", navigateTo: navigateTo)
            }
        }
    }
}

// MARK: - LLM

/// Per-preset LLM provider + model. Provider list and curated model
/// list both come from LLMProviderCatalog so this stays in sync with
/// LLMProviderTab. For local providers (ollama, lmstudio) where the
/// curated list is empty, the model field falls back to a TextField
/// so users can name a locally-installed model that the LLM Provider
/// tab would auto-detect.
struct LLMStageBody: View {
    @Bindable var draft: PresetDraft
    let navigateTo: (SettingsPage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Provider").frame(width: 96, alignment: .leading)
                Picker("", selection: Binding(
                    get: { draft.llmProvider },
                    set: { draft.setLLMProvider($0) }
                )) {
                    ForEach(LLMProviderCatalog.providers, id: \.id) { p in
                        Text(p.label).tag(p.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer()
            }
            HStack {
                Text("Model").frame(width: 96, alignment: .leading)
                modelControl
                Spacer()
            }
            Text("Pinned to this preset. API keys, base URLs, and the default provider/model live in LLM Provider.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                ManageElsewhereButton(target: .provider, label: "Manage in LLM Provider →", navigateTo: navigateTo)
            }
        }
    }

    @ViewBuilder
    private var modelControl: some View {
        let curated = LLMProviderCatalog.curatedModels(for: draft.llmProvider)
        if curated.isEmpty {
            // Local provider — free-form model name (the LLM Provider
            // tab's per-section auto-detect populates this normally).
            TextField("e.g. llama3.2", text: Binding(
                get: { draft.llmModel },
                set: { draft.setLLMModel($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 220)
        } else {
            Picker("", selection: Binding(
                get: { draft.llmModel },
                set: { draft.setLLMModel($0) }
            )) {
                // Preserve a current value not in the curated list so
                // the binding stays valid (matches LLMProviderTab's
                // per-section "(not available)" fallback pattern).
                if !curated.contains(draft.llmModel), !draft.llmModel.isEmpty {
                    Text("\(draft.llmModel) (not in curated list)").tag(draft.llmModel)
                }
                ForEach(curated, id: \.self) { m in
                    Text(m).tag(m)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
        }
    }
}
```

- [ ] **Step 2: Regenerate Xcode project + build**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project && make build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/StageDetailPane.swift mac/VoiceKeyboard/UI/Settings/Pipeline/TerminalStageBodies.swift mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift
git commit -m "feat(pipeline-ui): StageDetailPane + WhisperStageBody/DictStageBody/LLMStageBody"
```

---

## Phase I — `EditorView` two-column layout, Save flow, bundled-disable

### Task I1: Restructure `EditorView` to two-column

**Files:**
- Modify: `mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift`

- [ ] **Step 1: Replace the file**

Replace the entire contents of `mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift` with:

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift
import SwiftUI
import VoiceKeyboardCore

/// Two-column Pipeline editor. Left column: toolbar (preset picker +
/// Save / Save as… / Reset) + lane-grouped stage list. Right pane:
/// per-stage tunables.
///
/// Bundled presets render in read-only mode: every editable control
/// dims, the Save button is hidden, and tapping a disabled control
/// pulses the Save as… button to nudge the user toward a copy.
struct EditorView: View {
    let presets: any PresetsClient
    let sessions: any SessionsClient
    @Binding var settings: UserSettings
    let navigateTo: (SettingsPage) -> Void

    @State private var presetList: [Preset] = []
    @State private var selectedName: String = ""
    @State private var draft: PresetDraft? = nil
    @State private var loadError: String? = nil
    @State private var saveSheetVisible = false
    @State private var overwriteConfirmVisible = false
    @State private var saveError: String? = nil
    @State private var saving = false
    /// Increments on every "click on a disabled control while a bundled
    /// preset is selected" — drives a transient pulse on the Save as…
    /// button so the user notices the alternative.
    @State private var saveAsPulseTrigger: Int = 0

    private var isBundled: Bool { draft?.source.isBundled ?? false }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leftColumn
                .frame(width: 280)
            Divider()
            rightPane
                .frame(maxWidth: .infinity, alignment: .topLeading)
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
        .sheet(isPresented: $overwriteConfirmVisible) {
            if let draft = draft {
                OverwriteConfirmSheet(
                    presetName: draft.source.name,
                    saving: saving,
                    onCancel: { overwriteConfirmVisible = false },
                    onConfirm: { Task { await performOverwrite() } }
                )
            }
        }
        .onChange(of: selectedName) { _, newName in
            if let p = presetList.first(where: { $0.name == newName }) {
                draft = PresetDraft(p)
                saveError = nil
            }
        }
    }

    // MARK: - Left column

    @ViewBuilder
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            if isBundled {
                Text("Bundled preset — *Save as…* to make an editable copy.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Divider()
            ScrollView {
                if let draft = draft {
                    StageList(
                        draft: draft,
                        editingDisabled: isBundled,
                        nudgeSaveAs: { saveAsPulseTrigger &+= 1 }
                    )
                } else if let err = loadError {
                    Text(err).foregroundStyle(.red).font(.callout)
                } else {
                    Text("Loading presets…").foregroundStyle(.secondary).font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Preset:").foregroundStyle(.secondary).font(.callout)
                Picker("Preset", selection: $selectedName) {
                    if presetList.isEmpty {
                        Text("(none)").tag("")
                    } else {
                        ForEach(presetList) { p in
                            Text(displayName(p)).tag(p.name)
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            if let draft = draft, draft.isDirty {
                Text("• edited").font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 6) {
                if !isBundled, let draft = draft, draft.isDirty {
                    Button {
                        overwriteConfirmVisible = true
                    } label: { Label("Save", systemImage: "square.and.arrow.down.fill") }
                    .controlSize(.small)
                }
                Button {
                    saveSheetVisible = true
                } label: { Label("Save as…", systemImage: "square.and.arrow.down") }
                .controlSize(.small)
                .disabled(draft == nil)
                .scaleEffect(saveAsPulseTrigger == 0 ? 1 : 1.08)
                .animation(.easeInOut(duration: 0.18).repeatCount(2, autoreverses: true), value: saveAsPulseTrigger)
                Button {
                    if let p = presetList.first(where: { $0.name == selectedName }) {
                        draft?.resetTo(p)
                    }
                } label: { Label("Reset", systemImage: "arrow.uturn.backward") }
                .controlSize(.small)
                .disabled(draft?.isDirty != true || isBundled)
            }
        }
    }

    private func displayName(_ p: Preset) -> String {
        p.isBundled ? "\(p.name) (default)" : p.name
    }

    // MARK: - Right pane

    @ViewBuilder
    private var rightPane: some View {
        if let draft = draft {
            ScrollView {
                StageDetailPane(
                    draft: draft,
                    sessions: sessions,
                    settings: $settings,
                    editingDisabled: isBundled,
                    navigateTo: navigateTo
                )
                .padding(.top, 4)
            }
        } else {
            Text("Select a stage to edit its tunables.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    // MARK: - Refresh + save

    private func refresh() async {
        do {
            let list = try await presets.list()
            await MainActor.run {
                self.presetList = list
                if self.selectedName.isEmpty || !list.contains(where: { $0.name == self.selectedName }),
                   let first = list.first {
                    self.selectedName = first.name
                    self.draft = PresetDraft(first)
                } else if let p = list.first(where: { $0.name == self.selectedName }) {
                    // Refreshed after a Save: re-anchor the draft so isDirty resets.
                    self.draft = PresetDraft(p)
                }
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                self.loadError = "Failed to load presets: \(error)"
            }
        }
    }

    private func performOverwrite() async {
        guard let draft = draft else { return }
        await MainActor.run { saving = true; saveError = nil }
        defer { Task { @MainActor in saving = false } }
        let p = draft.toPreset(name: draft.source.name, description: draft.source.description)
        do {
            try await presets.save(p)
            await MainActor.run {
                overwriteConfirmVisible = false
            }
            await refresh()
        } catch {
            await MainActor.run {
                saveError = "Save failed: \(error)"
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd mac && make build`
Expected: FAIL — `OverwriteConfirmSheet` doesn't exist yet.

### Task I2: Create `OverwriteConfirmSheet`

**Files:**
- Create: `mac/VoiceKeyboard/UI/Settings/Pipeline/OverwriteConfirmSheet.swift`

- [ ] **Step 1: Write the file**

Create `mac/VoiceKeyboard/UI/Settings/Pipeline/OverwriteConfirmSheet.swift`:

```swift
// mac/VoiceKeyboard/UI/Settings/Pipeline/OverwriteConfirmSheet.swift
import SwiftUI

/// Modal sheet shown before overwriting a user preset's saved JSON via
/// the Save button. The destructive action (Overwrite) is on the right
/// matching macOS convention for "this discards the saved version".
struct OverwriteConfirmSheet: View {
    let presetName: String
    let saving: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overwrite '\(presetName)'?").font(.headline)
            Text("This replaces the saved preset with your current edits.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button(role: .destructive) {
                    onConfirm()
                } label: {
                    Text(saving ? "Saving…" : "Overwrite")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
```

- [ ] **Step 2: Regenerate Xcode project + build**

Run: `cd mac && rm -rf VoiceKeyboard.xcodeproj && make project && make build`
Expected: PASS.

- [ ] **Step 3: Run SwiftPM tests once more to confirm nothing in the package broke**

Run: `cd mac && swift test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift mac/VoiceKeyboard/UI/Settings/Pipeline/OverwriteConfirmSheet.swift
git commit -m "feat(pipeline-ui): two-column EditorView with Save / Save as… / Reset and bundled lock"
```

---

## Phase J — Polish + verification

### Task J1: Search-and-replace any stale "graph" or "panel" references in comments

**Files:**
- Modify: any file in `mac/VoiceKeyboard/UI/Settings/Pipeline/` referencing the old type names.

- [ ] **Step 1: Grep for stale identifiers**

Run: `grep -rn "StageGraph\|StageDetailPanel" mac/VoiceKeyboard mac/Packages 2>/dev/null`

If any hits remain, update them to `StageList` / `StageDetailPane` respectively. Examples likely in doc-comments only.

- [ ] **Step 2: Build to confirm**

Run: `cd mac && make build`
Expected: PASS.

- [ ] **Step 3: Commit (skip if no changes)**

```bash
git add -A
git commit -m "chore: refresh comments referencing old StageGraph/StageDetailPanel names" || true
```

### Task J2: Manual UI smoke pass

**Files:**
- Run: `cd mac && make run`

This task has no automated assertions — it exists so the implementer manually verifies the interactive behavior the spec describes. Mark each item complete only after observing the behavior in the running app.

- [ ] **Step 1: Boot the app**

Run: `cd mac && make run`
Expected: app launches, status-bar icon appears, Settings opens.

- [ ] **Step 2: Open Settings → Pipeline → Editor (developer mode must be ON)**

If Pipeline isn't visible, open Settings → General → "Developer mode" toggle and re-open.

- [ ] **Step 3: Pick each bundled preset and verify read-only mode**

For each of `default (default)`, `minimal (default)`, `aggressive (default)`, `paranoid (default)`:
- Verify the suffix " (default)" is rendered in the picker label.
- Verify all `Toggle` checkboxes in the left list are dimmed and not interactive (clicking does not flip them).
- Verify the Save button is **not** visible, but Save as… and Reset are.
- Verify the inline hint "Bundled preset — Save as… to make an editable copy." sits above the list.
- Click a disabled checkbox; verify the Save as… button briefly pulses (scale up then back).

- [ ] **Step 4: Pick a user preset (or create one via Save as…) and verify edit mode**

If no user presets exist yet, click Save as… while a bundled preset is selected, name the new preset `smoke-test`, save.

Then with `smoke-test` selected:
- Toggle a frame stage off; verify "• edited" appears and a Save button appears.
- Click Save; verify the confirmation sheet appears.
- Click Overwrite; verify the sheet closes, the dirty indicator disappears, and the preset still shows the toggled-off state.
- Toggle the same stage on again; verify "• edited" returns; click Reset; verify it reverts.

- [ ] **Step 5: Test each terminal stage's right-pane body**

With `smoke-test` selected:
- Click `whisper` row → verify model-size picker is editable; pick a different size; verify the left-row subtitle updates. Click "Manage in General →" → verify Settings switches to General page.
- Return to Pipeline → click `dict` row → verify "{N} word{s} · ~{T} token{s}" matches whatever Dictionary tab shows. Click "Edit in Dictionary →" → verify Settings switches to Dictionary page.
- Return to Pipeline → click `llm` row → verify Provider picker has the four providers and Model picker has the curated list. Switch provider to OpenAI; verify model resets to `gpt-4o-mini`. Click "Manage in LLM Provider →" → verify Settings switches to LLM Provider page.

- [ ] **Step 6: Verify the renamed tab title in the sidebar**

Look at the Settings sidebar — the row that was "Provider" should now read "LLM Provider".

- [ ] **Step 7: Verify the persisted preset JSON includes the new model field**

Run: `ls ~/Library/Application\ Support/VoiceKeyboard/presets/`
Run: `cat ~/Library/Application\ Support/VoiceKeyboard/presets/smoke-test.json | python3 -m json.tool | grep -A1 '"llm"'`
Expected: shows `"provider": ...` and `"model": ...` (a real model id, not empty).

- [ ] **Step 8: Clean up the smoke-test preset**

Either delete the file via `rm ~/Library/Application\ Support/VoiceKeyboard/presets/smoke-test.json` or leave it for future testing (your call).

### Task J3: Final cross-test pass + commit any straggling fixes

- [ ] **Step 1: Run the full Mac test suite one more time**

Run: `cd mac && make test`
Expected: PASS.

- [ ] **Step 2: Run the Go core tests**

Run: `cd core && go test ./internal/presets/`
Expected: PASS.

- [ ] **Step 3: If any test failed, fix root cause + commit. If all green, this is the end of the plan.**

```bash
# only if any straggler fix:
git add -A
git commit -m "fix: address straggler from final cross-test pass"
```

---

## Deliberate scope choices

- **Local-provider model picker uses a TextField, not auto-detection.** The spec mentions `LLMProviderCatalog.models(for:)` returning auto-detected lists for ollama/lmstudio. To avoid extracting the existing `OllamaClient`/`LMStudioClient` model fetch into the catalog (separate refactor with its own surface area), Task H3's `LLMStageBody` falls back to a free-form `TextField` for local providers. The user can copy-paste the model name from the LLM Provider tab where auto-detection still runs. If a future iteration wants richer behavior, the catalog can grow an async `models(for:)` then.

## Self-review notes

The plan covers all spec sections:

- Layout (two-column, lane-grouped left, details right) — Phases F (rename + plumbing), G (StageList), H (StageDetailPane), I (EditorView restructure).
- Whisper / dict / llm right-pane bodies + deep-links — Phase H (TerminalStageBodies + ManageElsewhereButton).
- Per-preset LLM model — Phase A (Go schema + Resolve + Swift schema + applying), Phase B (catalog), Phase D (PresetDraft).
- Bundled-preset read-only with Save-as nudge — Phase C (bundledNames source of truth), Phase G (StageList disabled-tap → nudgeSaveAs), Phase I (EditorView Save hidden + pulse animation + hint).
- Save with confirmation for user presets — Phase I (EditorView Save button + OverwriteConfirmSheet + performOverwrite).
- Provider → LLM Provider rename — Phase E.
- Shared catalogs / consistency — Phase B (`LLMProviderCatalog`, `DictStats`), Phase C (`bundledNames`).

**Type-consistency check:** `setLLMProvider` / `setLLMModel` are referenced consistently. `nudgeSaveAs: () -> Void` is the closure type both in StageList and EditorView. `editingDisabled: Bool` is the same name in StageList and StageDetailPane. `navigateTo: (SettingsPage) -> Void` matches the existing PresetBanner / SettingsView signature. `Preset.bundledNames` and `Preset.isBundled` are referenced consistently in EditorView (`isBundled`), SaveAsPresetSheet (`bundledNames`), and BundledPresetNamesTests.

**Placeholder check:** every step contains exact code or exact commands. No "implement later" anywhere.
