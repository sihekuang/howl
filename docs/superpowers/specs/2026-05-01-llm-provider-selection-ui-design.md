# LLM Provider Selection UI — Design

**Status:** approved (verbal), pending written review
**Date:** 2026-05-01
**Owner:** Daniel
**Depends on:** PR #5 (Go-side `llm.Provider` registry; Anthropic + Ollama impls)

## Goal

Surface the multi-provider LLM cleanup support — already shipped on the Go side via PR #5 — to the macOS app's Settings → Provider tab. Users can switch between Anthropic (cloud) and Ollama (local), pick a model from each, and configure non-default Ollama endpoints when needed.

## Non-goals

- Adding a third LLM provider. The data model and UI are factored to make that trivial later, but no preemptive abstraction work.
- Per-provider advanced parameters (temperature, num_ctx, max_tokens). Defer until anyone asks.
- A separate "Test Connection" button for Ollama — the model-list fetch already serves as the connection probe.
- API-key entry for Ollama (it doesn't need one).
- Ollama model installation from inside the app (we point users at `ollama pull` in the empty-list message; we don't shell out).

## Current state

| Layer | Today |
|---|---|
| `UserSettings` (`mac/Packages/VoiceKeyboardCore/.../Storage/SettingsStore.swift`) | Has `llmProvider: String`, `llmModel: String`. **Missing `llmBaseURL`.** |
| `EngineConfig` (`mac/Packages/VoiceKeyboardCore/.../Bridge/EngineConfig.swift`) | Mirrors Go's config.Config; has `llmProvider`, `llmModel`, `llmAPIKey`. **Missing `llmBaseURL`** (Go's `llm_base_url` field, added in PR #5, has no Swift counterpart). |
| `ProviderTab` (`mac/VoiceKeyboard/UI/Settings/ProviderTab.swift`) | Hardcoded to Anthropic. Fixed `LabeledContent("Provider") { Text("Anthropic") }`. Anthropic-only model picker, API-key field, "Test Key" button hitting `api.anthropic.com/v1/models`. |
| Go core (already shipped) | Accepts `llm_provider`, `llm_model`, `llm_base_url`, `llm_api_key`. `llm.ProviderByName(name)` + `provider.New(opts)`. Ollama auto-detects model when none specified. |

## Design

### UI layout

Single `Form` in `ProviderTab`, top-down:

```
Provider:  [Anthropic ▾]   ← Picker; choices: Anthropic, Ollama

── Anthropic-only block (visible iff llmProvider == "anthropic") ──
Model:     [Sonnet 4.6 — balanced (default) ▾]
API Key:   [sk-ant-•••••••••••••••••]
           [Save]   [Test Key]
           ✓ Key works — 47 models available
Link:      Get one from console.anthropic.com

── Ollama-only block (visible iff llmProvider == "ollama") ──
Model:     [llama3.2:latest ▾] [↻]      (or inline error + Retry if offline)
▸ Advanced
  Base URL: [http://localhost:11434]
            [Reset to default]
```

**Show/hide rules:**
- Anthropic block visible iff `settings.llmProvider == "anthropic"`.
- Ollama block visible iff `settings.llmProvider == "ollama"`.
- Switching provider via picker swaps the lower section. Field values for the inactive provider stay in `UserSettings` (no surprise data loss when toggling back).
- The base URL is hidden behind a `▸ Advanced` disclosure. Empty string = "use provider default" (matches Go's `omitempty`).

### Data-model changes

`UserSettings` (persisted via `UserDefaultsSettingsStore` as JSON):

```swift
public struct UserSettings: Codable, Equatable, Sendable {
    // ... existing fields ...
    public var llmProvider: String
    public var llmModel: String
    public var llmBaseURL: String      // NEW — empty = provider default
    // ... existing fields ...
}
```

Backward-compat: `init(from decoder:)` decodes `llmBaseURL` with default `""`, so existing UserDefaults blobs migrate silently. (Pattern matches every other field in the struct.)

`EngineConfig` (mirrors Go's `config.Config`, sent as JSON over the C ABI):

```swift
public struct EngineConfig: Codable, Equatable, Sendable {
    // ... existing fields ...
    public var llmProvider: String
    public var llmModel: String
    public var llmAPIKey: String
    public var llmBaseURL: String       // NEW — JSON key "llm_base_url"
    // ... existing fields ...
}
```

`EngineCoordinator` (the place where `UserSettings` is mapped to `EngineConfig` before vkb_configure) reads `settings.llmBaseURL` and passes it through.

### Ollama model fetching

A new actor in `VoiceKeyboardCore`:

```swift
// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/LLM/OllamaClient.swift
public actor OllamaClient {
    public enum Error: Swift.Error, Equatable {
        case unreachable(URL)               // connection refused, DNS, etc.
        case http(status: Int, body: String) // non-2xx
        case decode(String)                 // unexpected JSON shape
    }

    public init(baseURL: URL = URL(string: "http://localhost:11434")!,
                session: URLSession = .shared)

    /// GET /api/tags. Returns the list of installed model names in
    /// the order Ollama returns them (typically newest first).
    public func listModels() async throws -> [String]
}
```

`ProviderTab` uses it from three places:

1. **On view appear**, when `settings.llmProvider == "ollama"`.
2. **On Refresh (↻) tap**.
3. **On Base URL change**, debounced 500 ms after the last keystroke.

Loading state machine:

```swift
enum OllamaModelState: Equatable {
    case idle
    case loading
    case loaded(models: [String])
    case empty                              // Ollama reachable, 0 models
    case failed(message: String)
}
```

Picker rendering:
- `.idle` / `.loading`: ProgressView spinner; picker disabled.
- `.loaded`: dropdown of model names; current `settings.llmModel` selected (or `(not installed)` annotation if it isn't in the list).
- `.empty`: replace picker with a help block:
  > **No models installed.** Run `ollama pull llama3.2` in your terminal, then click ↻.
  > [Copy command]   [Refresh]
- `.failed`: replace picker with an error block:
  > **Couldn't reach Ollama at \<base URL\>.**
  > Make sure Ollama is running, or change the base URL under Advanced.
  > [Retry]

### Edge cases

| Case | Behavior |
|---|---|
| User switches to Ollama, list empty | `.empty` state with the `ollama pull` hint above. |
| User switches to Ollama, can't reach service | `.failed` state with Retry. Provider can still be switched back to Anthropic. |
| Selected `llmModel` no longer in the refreshed list | Dropdown shows it labelled `(not installed)`; the field is highlighted with a subtle warning color and a tooltip "This model is no longer installed locally — pick another or `ollama pull`". `EngineCoordinator` still passes it through to Go (the Go-side Cleaner will surface the runtime 404 in its `vkb_last_error` channel as today). |
| Switching providers | Each `onChange` of `settings` calls `onSave(new)` (existing pattern), so most fields auto-save. The Anthropic API key keeps its existing explicit `Save` button (it flows through `SecretStore` / Keychain, not `UserSettings`). |
| Anthropic Save still requires `sk-ant-` prefix | Unchanged; this Keychain-write validation stays. |
| Empty Base URL | Treated as "use provider default" (`http://localhost:11434` for the in-app fetch; empty string in `EngineConfig.llmBaseURL` so Go also falls through to its provider default). |

### Persistence flow

```
ProviderTab field change
    ↓ Binding mutation
@State var settings: UserSettings
    ↓ .onChange(settings)
onSave(new)                           ← passed in by SettingsView
    ↓
SettingsStore.set(new)                ← writes UserDefaults
    ↓
EngineCoordinator observes change
    ↓
Builds new EngineConfig (incl. llmBaseURL)
    ↓
vkb_configure(json) over the C ABI
    ↓
Go: llm.ProviderByName(...)+provider.New(...)
```

API keys continue to flow through `SecretStore` (Keychain), not `UserSettings`. `EngineCoordinator` reads the key on demand and includes it in `EngineConfig.llmAPIKey` only when `settings.llmProvider == "anthropic"` (i.e., the only provider that needs one today). When that list grows, this becomes a small switch — Provider abstraction lives on the Go side and Swift doesn't replicate it.

### Testing strategy

- **Unit (`OllamaClientTests`)**: `URLProtocol`-mock-backed. Covers:
  - 200 with non-empty `models`
  - 200 with empty `models` (verify maps to `.empty` rather than `.failed`)
  - 503
  - Connection refused (`URLError.cannotConnectToHost`)
  - Garbage JSON
- **Unit (`SettingsStoreTests`)**: round-trip a `UserSettings` with `llmBaseURL` set; verify back-compat — decode an old JSON blob with no `llmBaseURL` field and assert the field defaults to `""`.
- **Unit (`EngineConfigTests`)**: encode a config with `llmBaseURL = "http://10.0.0.5:11434"` and assert the JSON contains `"llm_base_url"`; round-trip; back-compat decode with no field.
- **UI (SwiftUI Preview)**: Three previews — `ProviderTab(settings: .anthropic)`, `ProviderTab(settings: .ollamaWithModels)`, `ProviderTab(settings: .ollamaOffline)`. Inject a fake `OllamaClient` for the preview cases. No XCUITest snapshot infra unless the project already has one.
- **Manual**: rerun PR #5's smoke checklist (`vkb-cli pipe --llm-provider ollama --llm-model llama3.2 ...` against a recorded WAV) after the Mac app build to make sure the new Swift plumbing produces the same JSON the Go core expects.

### File touch-list (estimated)

- **NEW**: `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/LLM/OllamaClient.swift`
- **NEW**: `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/OllamaClientTests.swift`
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/SettingsStore.swift` — add `llmBaseURL`
- `mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/EngineConfig.swift` — add `llmBaseURL`
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/SettingsStoreTests.swift` — back-compat test
- `mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/EngineConfigTests.swift` — round-trip test
- `mac/VoiceKeyboard/UI/Settings/ProviderTab.swift` — provider picker, conditional blocks, Ollama subview
- `mac/VoiceKeyboard/Engine/EngineCoordinator.swift` — pass `llmBaseURL` through; gate `llmAPIKey` write to anthropic only

## Open questions

None at design time. Implementation may surface SwiftUI-shape questions (e.g., whether `Form { }`'s `.formStyle(.grouped)` plays well with the inline error block) — those become micro-decisions during the implementation plan.

## What's NOT in this PR (deliberate YAGNI)

- A third LLM provider (OpenAI, Groq, Bedrock, etc.). When that lands, the picker grows by one item and a new conditional block is added — no spec rewrite needed.
- Per-provider advanced parameters (temperature, num_ctx, max_tokens, system prompt override).
- Streaming preview within the Settings tab.
- `ollama pull` from inside the app.
- Any change to the Go side. PR #5 already accepts every field this UI emits.
