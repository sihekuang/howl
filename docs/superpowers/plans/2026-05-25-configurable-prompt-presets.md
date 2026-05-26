# Configurable Prompt Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the LLM cleanup prompt configurable per-preset, with a new Prompt tab in Settings for editing.

**Architecture:** Add a `prompt` field to the Go `Preset` struct and a `llm_prompt` field to `Config`. The prompt flows through the C ABI as part of the JSON config. Each LLM provider reads the prompt from its stored options instead of the hardcoded constant. A new Swift Prompt tab lets users view/edit the active preset's prompt text.

**Tech Stack:** Go (core), Swift/SwiftUI (Mac app), C ABI (bridge)

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `core/internal/llm/prompt.go` | Modify | Export `DefaultPrompt`, change `renderPrompt` signature to accept prompt template |
| `core/internal/llm/prompt_test.go` | Modify | Update tests for new `renderPrompt` signature |
| `core/internal/llm/provider.go` | Modify | Add `Prompt` field to `Options` struct |
| `core/internal/llm/anthropic.go` | Modify | Store prompt, pass to `renderPrompt` |
| `core/internal/llm/openai.go` | Modify | Store prompt, pass to `renderPrompt` |
| `core/internal/llm/ollama.go` | Modify | Store prompt, pass to `renderPrompt` |
| `core/internal/llm/lmstudio.go` | Modify | Pass prompt through to `newOpenAICompatible` |
| `core/internal/presets/presets.go` | Modify | Add `Prompt` field to `Preset` struct |
| `core/internal/presets/pipeline-presets.json` | Modify | Add `"prompt"` key to all four bundled presets |
| `core/internal/config/config.go` | Modify | Add `LLMPrompt` to `Config`, default in `WithDefaults` |
| `core/internal/pipeline/build/build.go` | Modify | Wire `cfg.LLMPrompt` into `llm.Options.Prompt` |
| `mac/Packages/HowlCore/.../Bridge/Preset.swift` | Modify | Add `prompt` field |
| `mac/Packages/HowlCore/.../Bridge/EngineConfig.swift` | Modify | Add `llmPrompt` field |
| `mac/Packages/HowlCore/.../Storage/SettingsStore.swift` | Modify | Add `llmPrompt` to `UserSettings`, stamp in `applying()` |
| `mac/Howl/UI/Settings/PromptTab.swift` | Create | New Prompt tab view |
| `mac/Howl/UI/Settings/SettingsView.swift` | Modify | Add `.prompt` case to sidebar |
| `mac/Howl/UI/Settings/Pipeline/PresetDraft.swift` | Modify | Add `prompt` field to draft |

---

### Task 1: Go — Export DefaultPrompt and change renderPrompt signature

**Files:**
- Modify: `core/internal/llm/prompt.go`
- Modify: `core/internal/llm/prompt_test.go`

- [ ] **Step 1: Update prompt.go**

Change the hardcoded constant to an exported `DefaultPrompt` and update `renderPrompt` to accept a prompt template parameter:

```go
// DefaultPrompt is the built-in cleanup instruction. Used when no
// custom prompt is configured.
const DefaultPrompt = `You are a transcription editor. Your job is to MINIMALLY edit the transcription below, not to rewrite it. Apply only these changes:
- Remove filler words: um, uh, er, ah, like, you know, basically, I mean, sort of, kind of (when used as fillers)
- Fix obvious grammar and punctuation
- Drop any bracketed sound/music annotations Whisper inserts: (music), (water splashing), [Applause], [Laughter], etc. — these are NOT what the speaker said
- Preserve technical terms verbatim: %s

Hard rules:
- Do NOT paraphrase or restructure sentences. Keep the speaker's exact phrasing.
- Do NOT add words, ideas, or context the speaker did not say.
- Do NOT turn fragments into complete sentences if the speaker spoke fragments.
- If the input is empty, dropped to nothing after cleanup, or only sound annotations, return an empty string.
- Return ONLY the cleaned text — no preamble, no explanation, no quotes around the output.

Raw transcription:
%s`

func renderPrompt(promptTemplate, raw string, preserveTerms []string) string {
	terms := "(none)"
	if len(preserveTerms) > 0 {
		terms = strings.Join(preserveTerms, ", ")
	}
	nVerbs := strings.Count(promptTemplate, "%s")
	switch nVerbs {
	case 0:
		return promptTemplate + "\n\nPreserve these terms verbatim: " + terms + "\n\nRaw transcription:\n" + raw
	case 1:
		return fmt.Sprintf(promptTemplate, terms) + "\n\nRaw transcription:\n" + raw
	default:
		return fmt.Sprintf(promptTemplate, terms, raw)
	}
}
```

- [ ] **Step 2: Update prompt_test.go**

```go
func TestRenderPrompt_BasicSubstitution(t *testing.T) {
	got := renderPrompt(DefaultPrompt, "hello world um yeah", []string{"MCP", "WebRTC"})
	if !strings.Contains(got, "hello world um yeah") {
		t.Errorf("prompt missing raw text:\n%s", got)
	}
	if !strings.Contains(got, "MCP, WebRTC") {
		t.Errorf("prompt missing preserve terms:\n%s", got)
	}
	if !strings.Contains(got, "Remove filler words") {
		t.Errorf("prompt missing instructions:\n%s", got)
	}
}

func TestRenderPrompt_NoTerms(t *testing.T) {
	got := renderPrompt(DefaultPrompt, "hello", nil)
	if !strings.Contains(got, "Preserve technical terms verbatim:") {
		t.Errorf("prompt missing terms section even when empty:\n%s", got)
	}
	if !strings.Contains(got, "(none)") {
		t.Errorf("expected (none) when no terms:\n%s", got)
	}
}

func TestRenderPrompt_CustomNoVerbs(t *testing.T) {
	got := renderPrompt("Fix grammar only.", "hello world", []string{"Go"})
	if !strings.Contains(got, "Fix grammar only.") {
		t.Errorf("prompt missing custom text:\n%s", got)
	}
	if !strings.Contains(got, "Preserve these terms verbatim: Go") {
		t.Errorf("prompt missing appended terms:\n%s", got)
	}
	if !strings.Contains(got, "Raw transcription:\nhello world") {
		t.Errorf("prompt missing appended raw text:\n%s", got)
	}
}

func TestRenderPrompt_CustomOneVerb(t *testing.T) {
	got := renderPrompt("Keep these words: %s\nClean it up.", "hello world", []string{"API"})
	if !strings.Contains(got, "Keep these words: API") {
		t.Errorf("prompt missing substituted terms:\n%s", got)
	}
	if !strings.Contains(got, "Raw transcription:\nhello world") {
		t.Errorf("prompt missing appended raw text:\n%s", got)
	}
}
```

- [ ] **Step 3: Run tests**

Run: `cd core && go test ./internal/llm/ -run TestRenderPrompt -v`
Expected: All four tests PASS.

- [ ] **Step 4: Commit**

```bash
git add core/internal/llm/prompt.go core/internal/llm/prompt_test.go
git commit -m "feat(core): export DefaultPrompt and parameterize renderPrompt"
```

---

### Task 2: Go — Add Prompt to Options, Config, Preset, and wire through providers

**Files:**
- Modify: `core/internal/llm/provider.go:18-23` — add `Prompt` to `Options`
- Modify: `core/internal/config/config.go:7-93` — add `LLMPrompt` to `Config` + `WithDefaults`
- Modify: `core/internal/presets/presets.go:31-41` — add `Prompt` to `Preset`
- Modify: `core/internal/presets/pipeline-presets.json` — add `"prompt"` to all four presets
- Modify: `core/internal/llm/anthropic.go` — store and use prompt
- Modify: `core/internal/llm/openai.go` — store and use prompt
- Modify: `core/internal/llm/ollama.go` — store and use prompt
- Modify: `core/internal/llm/lmstudio.go` — pass prompt through
- Modify: `core/internal/pipeline/build/build.go:71` — wire `cfg.LLMPrompt`

- [ ] **Step 1: Add `Prompt` to `Options` struct in provider.go**

At `core/internal/llm/provider.go:18-23`, add `Prompt` field:

```go
type Options struct {
	Model   string
	APIKey  string
	BaseURL string
	Timeout time.Duration
	Prompt  string
}
```

- [ ] **Step 2: Add `LLMPrompt` to Config and WithDefaults**

In `core/internal/config/config.go`, add after `LLMBaseURL` (line 24):

```go
LLMPrompt string `json:"llm_prompt,omitempty"`
```

In `WithDefaults` (line 80), add after the `LLMModel` default:

```go
if c.LLMPrompt == "" {
	c.LLMPrompt = llm.DefaultPrompt
}
```

Add the import `"github.com/voice-keyboard/core/internal/llm"` to config.go.

- [ ] **Step 3: Add `Prompt` to Preset struct**

In `core/internal/presets/presets.go:31`, add after `Description`:

```go
type Preset struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Prompt      string         `json:"prompt,omitempty"`
	FrameStages []StageSpec    `json:"frame_stages"`
	ChunkStages []StageSpec    `json:"chunk_stages"`
	Transcribe  TranscribeSpec `json:"transcribe"`
	LLM         LLMSpec        `json:"llm"`
	TimeoutSec  *int           `json:"timeout_sec,omitempty"`
}
```

- [ ] **Step 4: Add `"prompt"` to pipeline-presets.json**

Add the `"prompt"` key to all four presets in `core/internal/presets/pipeline-presets.json`. The value is the full `DefaultPrompt` text. Example for the first preset (repeat for all four — each gets the identical prompt):

```json
{
  "name": "default",
  "description": "Standard pipeline: denoise → TSE (soft gate) → decimate → Whisper → dict → LLM cleanup.",
  "prompt": "You are a transcription editor. Your job is to MINIMALLY edit the transcription below, not to rewrite it. Apply only these changes:\n- Remove filler words: um, uh, er, ah, like, you know, basically, I mean, sort of, kind of (when used as fillers)\n- Fix obvious grammar and punctuation\n- Drop any bracketed sound/music annotations Whisper inserts: (music), (water splashing), [Applause], [Laughter], etc. — these are NOT what the speaker said\n- Preserve technical terms verbatim: %s\n\nHard rules:\n- Do NOT paraphrase or restructure sentences. Keep the speaker's exact phrasing.\n- Do NOT add words, ideas, or context the speaker did not say.\n- Do NOT turn fragments into complete sentences if the speaker spoke fragments.\n- If the input is empty, dropped to nothing after cleanup, or only sound annotations, return an empty string.\n- Return ONLY the cleaned text — no preamble, no explanation, no quotes around the output.\n\nRaw transcription:\n%s",
  "frame_stages": [ ... ]
}
```

- [ ] **Step 5: Store prompt in Anthropic and use it**

In `core/internal/llm/anthropic.go`, add `prompt` field to the `Anthropic` struct (line 49-52):

```go
type Anthropic struct {
	client *anthropic.Client
	model  string
	prompt string
}
```

In `NewAnthropic` (line 59-78), accept and store it. Add a `Prompt` field to `AnthropicOptions`:

```go
type AnthropicOptions struct {
	APIKey  string
	Model   string
	BaseURL string
	Timeout time.Duration
	Prompt  string
}
```

Set it in the constructor: `return &Anthropic{client: &c, model: opts.Model, prompt: opts.Prompt}, nil`

Update the factory (lines 21-33) to pass `Prompt: opts.Prompt`:

```go
factory: func(opts Options) (Cleaner, error) {
	return NewAnthropic(AnthropicOptions{
		APIKey:  opts.APIKey,
		Model:   opts.Model,
		BaseURL: opts.BaseURL,
		Timeout: opts.Timeout,
		Prompt:  opts.Prompt,
	})
},
```

In `CleanStream` (line 95) and `Clean` (line 143), change:
```go
prompt := renderPrompt(raw, preserveTerms)
```
to:
```go
promptTpl := a.prompt
if promptTpl == "" {
	promptTpl = DefaultPrompt
}
prompt := renderPrompt(promptTpl, raw, preserveTerms)
```

- [ ] **Step 6: Store prompt in OpenAI and use it**

In `core/internal/llm/openai.go`, add `prompt` field to the `OpenAI` struct (line 56-61):

```go
type OpenAI struct {
	client  *http.Client
	apiKey  string
	model   string
	baseURL string
	prompt  string
}
```

Add `Prompt` to `OpenAIOptions` (line 48-53):

```go
type OpenAIOptions struct {
	APIKey  string
	Model   string
	BaseURL string
	Timeout time.Duration
	Prompt  string
}
```

In `newOpenAICompatible` (line 75-93), store it: add `prompt: opts.Prompt` to the return struct.

Update the factory (lines 29-41) to pass `Prompt: opts.Prompt`.

In `Clean` (line 147) and `CleanStream` (line 203), change `renderPrompt(raw, preserveTerms)` to:
```go
promptTpl := o.prompt
if promptTpl == "" {
	promptTpl = DefaultPrompt
}
prompt := renderPrompt(promptTpl, raw, preserveTerms)
```

- [ ] **Step 7: Store prompt in Ollama and use it**

In `core/internal/llm/ollama.go`, add `prompt` field to the `Ollama` struct (line 121-125):

```go
type Ollama struct {
	client  *http.Client
	model   string
	baseURL string
	prompt  string
}
```

Add `Prompt` to `OllamaOptions` (line 113-118):

```go
type OllamaOptions struct {
	Model   string
	BaseURL string
	Timeout time.Duration
	Prompt  string
}
```

In `NewOllama` (line 129-146), store it: add `prompt: opts.Prompt` to the return struct.

Update the factory (lines 33-58) to pass `Prompt: opts.Prompt`:
```go
return NewOllama(OllamaOptions{
	Model:   opts.Model,
	BaseURL: opts.BaseURL,
	Timeout: opts.Timeout,
	Prompt:  opts.Prompt,
})
```

In `Clean` (line 185) and `CleanStream` (line 238), change `renderPrompt(raw, preserveTerms)` to:
```go
promptTpl := o.prompt
if promptTpl == "" {
	promptTpl = DefaultPrompt
}
prompt := renderPrompt(promptTpl, raw, preserveTerms)
```

- [ ] **Step 8: Pass prompt through in LM Studio**

In `core/internal/llm/lmstudio.go`, update the factory (lines 38-63) to pass `Prompt` through the `OpenAIOptions`:

```go
return newOpenAICompatible(OpenAIOptions{
	APIKey:  opts.APIKey,
	Model:   opts.Model,
	BaseURL: baseURL,
	Timeout: timeout,
	Prompt:  opts.Prompt,
}, false)
```

- [ ] **Step 9: Wire cfg.LLMPrompt in build.go**

In `core/internal/pipeline/build/build.go:71`, add `Prompt` to `llmOpts`:

```go
llmOpts := llm.Options{Model: cfg.LLMModel, BaseURL: cfg.LLMBaseURL, Prompt: cfg.LLMPrompt}
```

- [ ] **Step 10: Run Go tests**

Run: `cd core && go test ./internal/llm/ -v`
Expected: All tests PASS (including the new `renderPrompt` tests from Task 1).

- [ ] **Step 11: Commit**

```bash
git add core/internal/llm/provider.go core/internal/llm/anthropic.go \
       core/internal/llm/openai.go core/internal/llm/ollama.go \
       core/internal/llm/lmstudio.go core/internal/config/config.go \
       core/internal/presets/presets.go core/internal/presets/pipeline-presets.json \
       core/internal/pipeline/build/build.go
git commit -m "feat(core): wire configurable prompt through presets, config, and providers"
```

---

### Task 3: Swift — Add prompt to Preset, EngineConfig, and UserSettings

**Files:**
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Bridge/Preset.swift`
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Bridge/EngineConfig.swift`
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Storage/SettingsStore.swift`

- [ ] **Step 1: Add `prompt` to Preset.swift**

Add `prompt` field after `description` (line 9). Update `init`, `CodingKeys`:

```swift
public struct Preset: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String
    public let prompt: String
    public let frameStages: [StageSpec]
    public let chunkStages: [StageSpec]
    public let transcribe: TranscribeSpec
    public let llm: LLMSpec
    public let timeoutSec: Int?

    public var id: String { name }

    public init(
        name: String,
        description: String,
        prompt: String = "",
        frameStages: [StageSpec],
        chunkStages: [StageSpec],
        transcribe: TranscribeSpec,
        llm: LLMSpec,
        timeoutSec: Int? = nil
    ) {
        self.name = name
        self.description = description
        self.prompt = prompt
        self.frameStages = frameStages
        self.chunkStages = chunkStages
        self.transcribe = transcribe
        self.llm = llm
        self.timeoutSec = timeoutSec
    }
```

Add to `CodingKeys` (line 84-89):

```swift
enum CodingKeys: String, CodingKey {
    case name, description, prompt, transcribe, llm
    case frameStages = "frame_stages"
    case chunkStages = "chunk_stages"
    case timeoutSec = "timeout_sec"
}
```

Since `prompt` may be absent from old preset JSON, add a custom `init(from:)`:

```swift
public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try c.decode(String.self, forKey: .name)
    self.description = try c.decode(String.self, forKey: .description)
    self.prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    self.frameStages = try c.decode([StageSpec].self, forKey: .frameStages)
    self.chunkStages = try c.decode([StageSpec].self, forKey: .chunkStages)
    self.transcribe = try c.decode(TranscribeSpec.self, forKey: .transcribe)
    self.llm = try c.decode(LLMSpec.self, forKey: .llm)
    self.timeoutSec = try c.decodeIfPresent(Int.self, forKey: .timeoutSec)
}
```

- [ ] **Step 2: Add `llmPrompt` to EngineConfig.swift**

Add property after `llmBaseURL` (line 14):

```swift
public var llmPrompt: String
```

Update `init` (line 42-84) — add parameter `llmPrompt: String = ""` and assign `self.llmPrompt = llmPrompt`.

Update `encode(to:)` (line 86-115) — add after `llmBaseURL`:

```swift
if !llmPrompt.isEmpty {
    try c.encode(llmPrompt, forKey: .llmPrompt)
}
```

Update `init(from:)` (line 117-139) — add:

```swift
self.llmPrompt = try c.decodeIfPresent(String.self, forKey: .llmPrompt) ?? ""
```

Update `CodingKeys` (line 141-162) — add:

```swift
case llmPrompt = "llm_prompt"
```

Update the `init(settings:apiKey:paths:)` factory (line 214-239) — add `llmPrompt: settings.llmPrompt` to the `self.init(...)` call.

- [ ] **Step 3: Add `llmPrompt` to UserSettings and `applying(_:)`**

In `SettingsStore.swift`, add `llmPrompt` property after `llmBaseURL` (line 9):

```swift
public var llmPrompt: String
```

Update `init` (line 38-68) — add parameter `llmPrompt: String = ""` and assign.

Update `init(from:)` (line 70-86) — add:

```swift
llmPrompt = try c.decodeIfPresent(String.self, forKey: .llmPrompt) ?? ""
```

Update `CodingKeys` (line 88-93) — add `llmPrompt`.

Update `applying(_ preset:)` (line 109-128) — stamp the prompt. Add after `s.selectedPresetName = preset.name` (line 111):

```swift
if !preset.prompt.isEmpty {
    s.llmPrompt = preset.prompt
}
```

- [ ] **Step 4: Build the Mac app**

Run: `cd mac && make build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run SwiftPM tests**

Run: `cd mac && make test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/Bridge/Preset.swift \
       mac/Packages/HowlCore/Sources/HowlCore/Bridge/EngineConfig.swift \
       mac/Packages/HowlCore/Sources/HowlCore/Storage/SettingsStore.swift
git commit -m "feat(mac): add llmPrompt to Preset, EngineConfig, and UserSettings"
```

---

### Task 4: Swift — Add prompt to PresetDraft

**Files:**
- Modify: `mac/Howl/UI/Settings/Pipeline/PresetDraft.swift`

- [ ] **Step 1: Add `prompt` field to PresetDraft**

Add `var prompt: String` after `timeoutSec` (line 27). Update `init`, `isDirty`, `resetTo`, `markSaved` is already fine (just updates `source`), and `toPreset`:

In `init(_ source:)` (line 33-41), add:
```swift
self.prompt = source.prompt
```

In `isDirty` (line 53-61), add before `return false`:
```swift
if prompt != source.prompt { return true }
```

In `resetTo(_ preset:)` (line 64-73), add:
```swift
prompt = preset.prompt
```

In `toPreset(name:description:)` (line 87-97), add `prompt:` to the `Preset(...)` call:
```swift
func toPreset(name: String, description: String) -> Preset {
    Preset(
        name: name,
        description: description,
        prompt: prompt,
        frameStages: frameStages,
        chunkStages: chunkStages,
        transcribe: .init(modelSize: transcribeModelSize),
        llm: .init(provider: llmProvider, model: llmModel),
        timeoutSec: timeoutSec
    )
}
```

- [ ] **Step 2: Build**

Run: `cd mac && make build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add mac/Howl/UI/Settings/Pipeline/PresetDraft.swift
git commit -m "feat(mac): add prompt field to PresetDraft"
```

---

### Task 5: Swift — Create PromptTab and add to SettingsView sidebar

**Files:**
- Create: `mac/Howl/UI/Settings/PromptTab.swift`
- Modify: `mac/Howl/UI/Settings/SettingsView.swift`

- [ ] **Step 1: Create PromptTab.swift**

```swift
import SwiftUI
import HowlCore

struct PromptTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let presets: any PresetsClient

    @State private var allPresets: [Preset] = []
    @State private var editablePrompt: String = ""
    @State private var showSaveAs = false

    private var activePreset: Preset? {
        allPresets.first(where: { $0.name == settings.selectedPresetName })
    }

    private var isBuiltIn: Bool {
        activePreset?.isBundled ?? true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            presetLabel
            editorSection
            previewSection
            actionButtons
        }
        .task { await loadPresets() }
        .onChange(of: settings.selectedPresetName) {
            syncPromptFromSettings()
        }
        .sheet(isPresented: $showSaveAs) {
            SaveAsPresetSheet(
                existingNames: Set(allPresets.map(\.name)),
                onSave: { name, description in
                    Task { await saveAsNewPreset(name: name, description: description) }
                }
            )
        }
    }

    // MARK: - Subviews

    private var presetLabel: some View {
        HStack {
            Text("Prompt for:")
                .foregroundStyle(.secondary)
            Text(activePreset?.displayName ?? settings.selectedPresetName ?? "default")
                .fontWeight(.medium)
        }
    }

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Instructions")
                .font(.headline)
            TextEditor(text: $editablePrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
                )
                .disabled(isBuiltIn)
                .opacity(isBuiltIn ? 0.7 : 1.0)
            if isBuiltIn {
                Text("Built-in presets are read-only. Duplicate to edit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview")
                .font(.headline)
            let rendered = renderPreview(editablePrompt)
            ScrollView {
                Text(rendered)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 120)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.controlBackgroundColor))
            )
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack {
            if isBuiltIn {
                Button("Duplicate to Edit") {
                    showSaveAs = true
                }
            } else {
                Button("Save") {
                    savePromptInPlace()
                }
                .disabled(editablePrompt == (activePreset?.prompt ?? ""))
                Button("Revert") {
                    syncPromptFromSettings()
                }
                .disabled(editablePrompt == (activePreset?.prompt ?? ""))
            }
        }
    }

    // MARK: - Logic

    private func loadPresets() async {
        allPresets = (try? await presets.list()) ?? []
        syncPromptFromSettings()
    }

    private func syncPromptFromSettings() {
        if let preset = activePreset, !preset.prompt.isEmpty {
            editablePrompt = preset.prompt
        } else if !settings.llmPrompt.isEmpty {
            editablePrompt = settings.llmPrompt
        } else {
            editablePrompt = defaultPromptText
        }
    }

    private func savePromptInPlace() {
        guard let preset = activePreset, !preset.isBundled else { return }
        let updated = Preset(
            name: preset.name,
            description: preset.description,
            prompt: editablePrompt,
            frameStages: preset.frameStages,
            chunkStages: preset.chunkStages,
            transcribe: preset.transcribe,
            llm: preset.llm,
            timeoutSec: preset.timeoutSec
        )
        Task {
            try? await presets.save(updated)
            var s = settings
            s.llmPrompt = editablePrompt
            onSave(s)
            await loadPresets()
        }
    }

    private func saveAsNewPreset(name: String, description: String) async {
        guard let source = activePreset ?? allPresets.first else { return }
        let newPreset = Preset(
            name: name,
            description: description,
            prompt: editablePrompt,
            frameStages: source.frameStages,
            chunkStages: source.chunkStages,
            transcribe: source.transcribe,
            llm: source.llm,
            timeoutSec: source.timeoutSec
        )
        try? await presets.save(newPreset)
        var s = settings.applying(newPreset)
        s.llmPrompt = editablePrompt
        onSave(s)
        await loadPresets()
    }

    private func renderPreview(_ prompt: String) -> String {
        let terms = settings.customDict.isEmpty ? "(none)" : settings.customDict.joined(separator: ", ")
        let sample = "Um, I think we should, you know, deploy to production."
        let count = prompt.components(separatedBy: "%s").count - 1
        switch count {
        case 0:
            return prompt + "\n\nPreserve these terms verbatim: " + terms + "\n\nRaw transcription:\n" + sample
        case 1:
            return prompt.replacingOccurrences(of: "%s", with: terms) + "\n\nRaw transcription:\n" + sample
        default:
            var result = prompt
            if let r = result.range(of: "%s") { result.replaceSubrange(r, with: terms) }
            if let r = result.range(of: "%s") { result.replaceSubrange(r, with: sample) }
            return result
        }
    }
}

private let defaultPromptText = """
You are a transcription editor. Your job is to MINIMALLY edit the transcription below, not to rewrite it. Apply only these changes:
- Remove filler words: um, uh, er, ah, like, you know, basically, I mean, sort of, kind of (when used as fillers)
- Fix obvious grammar and punctuation
- Drop any bracketed sound/music annotations Whisper inserts: (music), (water splashing), [Applause], [Laughter], etc. — these are NOT what the speaker said
- Preserve technical terms verbatim: %s

Hard rules:
- Do NOT paraphrase or restructure sentences. Keep the speaker's exact phrasing.
- Do NOT add words, ideas, or context the speaker did not say.
- Do NOT turn fragments into complete sentences if the speaker spoke fragments.
- If the input is empty, dropped to nothing after cleanup, or only sound annotations, return an empty string.
- Return ONLY the cleaned text — no preamble, no explanation, no quotes around the output.

Raw transcription:
%s
"""
```

- [ ] **Step 2: Add `.prompt` to SettingsView sidebar**

In `mac/Howl/UI/Settings/SettingsView.swift`, add `case prompt` to `SettingsPage` enum after `provider` (line 13):

```swift
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case voice
    case hotkey
    case provider
    case prompt      // NEW
    case dictionary
    case playground
    case pipeline
```

Add to `title` (after `.provider`):
```swift
case .prompt: return "Prompt"
```

Add to `icon`:
```swift
case .prompt: return "text.bubble"
```

Add to `iconColor`:
```swift
case .prompt: return .teal
```

Add the case to `pageBody` in `DetailView` (after `.provider`):
```swift
case .prompt:
    PromptTab(
        settings: $settings,
        onSave: save,
        presets: LibVKBPresetsClient(engine: composition.engine)
    )
```

- [ ] **Step 3: Build**

Run: `cd mac && make build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run the app and verify the Prompt tab appears**

Run: `cd mac && make run`
Verify: Settings window shows "Prompt" tab in sidebar between "LLM Provider" and "Dictionary". Clicking it shows the prompt editor with the default cleanup text. Preview section renders correctly.

- [ ] **Step 5: Commit**

```bash
git add mac/Howl/UI/Settings/PromptTab.swift mac/Howl/UI/Settings/SettingsView.swift
git commit -m "feat(mac): add Prompt tab to Settings for editing per-preset prompts"
```

---

### Task 6: End-to-end verification

- [ ] **Step 1: Build full app**

Run: `cd mac && make build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Run Go tests**

Run: `cd core && go test ./internal/llm/ ./internal/presets/ ./internal/config/ -v`
Expected: All tests PASS.

- [ ] **Step 3: Run Swift tests**

Run: `cd mac && make test`
Expected: All tests PASS.

- [ ] **Step 4: Manual smoke test**

Run: `cd mac && make run`

Verify:
1. Prompt tab shows current cleanup prompt for the active preset.
2. Built-in preset prompt is read-only with "Duplicate to edit" button.
3. Duplicating creates a new preset with the edited prompt.
4. Switching presets in General tab updates the Prompt tab.
5. Dictating with a user preset that has a custom prompt actually uses that prompt (check the LLM output reflects the new instructions).
6. Preview section updates live as you type.
