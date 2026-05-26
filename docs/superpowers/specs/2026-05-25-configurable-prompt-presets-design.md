# Configurable Prompt Presets

**Date:** 2026-05-25
**Status:** Approved

## Problem

The LLM cleanup prompt is hardcoded in `core/internal/llm/prompt.go`. Users cannot change the instructions sent to the LLM, even though every other part of the pipeline (audio stages, Whisper model, LLM provider/model) is configurable per-preset.

## Decision

Add the prompt as a field on the existing `Preset` struct. No new entity types. Prompts are edited and stored as part of presets, following the same patterns as pipeline stages.

## Data Model Changes

### Go: `Preset` struct (`core/internal/presets/presets.go`)

Add a `Prompt` string field:

```go
type Preset struct {
    Name        string         `json:"name"`
    Description string         `json:"description"`
    Prompt      string         `json:"prompt"`
    FrameStages []StageSpec    `json:"frame_stages"`
    ChunkStages []StageSpec    `json:"chunk_stages"`
    Transcribe  TranscribeSpec `json:"transcribe"`
    LLM         LLMSpec        `json:"llm"`
    TimeoutSec  *int           `json:"timeout_sec,omitempty"`
}
```

### Go: `Config` struct (`core/internal/config/config.go`)

Add `LLMPrompt` so the prompt flows through the C ABI:

```go
LLMPrompt string `json:"llm_prompt,omitempty"`
```

`WithDefaults` fills `LLMPrompt` with the current hardcoded cleanup text when empty, so existing configs that don't specify a prompt continue to work.

### Go: `renderPrompt()` (`core/internal/llm/prompt.go`)

Changes from reading a hardcoded constant to accepting the prompt template as a parameter. The function still appends custom dictionary terms and raw transcription at runtime. The caller passes `cfg.LLMPrompt`. The current cleanup text becomes `DefaultPrompt` (exported constant) used by `WithDefaults`.

### Bundled presets (`core/internal/presets/pipeline-presets.json`)

All four bundled presets get a `"prompt"` key containing the current cleanup prompt text. Bundle version stays at 1 since this is an additive optional field.

### Swift: `Preset.swift`

Add `prompt: String` field to the `Preset` struct (Decodable, mirrors Go).

### Swift: `EngineConfig.swift`

Add `llmPrompt: String` field. Serialized as `llm_prompt` in the JSON sent to `howl_configure`.

### Swift: `UserSettings` / `SettingsStore.swift`

Add `llmPrompt: String` field. `applying(_ preset:)` stamps the preset's prompt into settings.

## Prompt Rendering

The user writes only the instruction portion of the prompt. At runtime, Go appends two things:

1. **Custom dictionary terms** — from `Config.CustomDict`. If the prompt contains `%s`, the first `%s` is replaced with the comma-joined terms (backward-compatible with the current prompt). If the prompt has no `%s`, terms are appended as a line: `Preserve these terms verbatim: X, Y, Z`.
2. **Raw transcription** — the Whisper output. If the prompt contains a second `%s`, it's replaced with the raw text. Otherwise the raw text is appended after a blank line with the label `Raw transcription:`.

This separation means users don't need to worry about where the transcription goes. They write instructions; Go assembles the final message.

## UI: New Prompt Tab

A new **Prompt** tab in the Settings sidebar (between General and the LLM Provider tab).

### Components

1. **Active prompt label** — displays which preset's prompt is loaded (e.g., "default (built-in)").

2. **Text editor** — multi-line `TextEditor` showing the prompt text.
   - Built-in presets: read-only, with a "Duplicate to edit" button that opens `SaveAsPresetSheet` pre-filled with the current preset's values.
   - User presets: directly editable.

3. **Preview section** — read-only area below the editor showing the fully rendered prompt with placeholder dictionary terms and sample transcription text. Updates live as the user types.

4. **Save button** — for user presets, saves the prompt in place (updates the preset file on disk via the existing `howl_save_preset` C ABI). For built-in presets after editing, opens `SaveAsPresetSheet` to create a new user preset.

### Interactions

- Switching presets in the General tab's preset picker updates the Prompt tab's content.
- No separate prompt picker — the prompt is always part of the active preset.
- Creating a new "prompt style" = creating a new preset (which can share the same pipeline stages as the source).
- Reuses `SaveAsPresetSheet` from the Pipeline Editor (no new save UI).

## Backward Compatibility

- Existing user presets on disk without a `"prompt"` field decode with an empty string. `WithDefaults` fills in the default cleanup prompt. No migration needed.
- Existing `EngineConfig` JSON without `"llm_prompt"` gets the default via `WithDefaults`. No C ABI contract break.
- Bundle version stays at 1 (additive field).

## Files Modified

| File | Change |
|------|--------|
| `core/internal/presets/presets.go` | Add `Prompt` field to `Preset` |
| `core/internal/presets/pipeline-presets.json` | Add `"prompt"` to all four bundled presets |
| `core/internal/config/config.go` | Add `LLMPrompt` to `Config`, default in `WithDefaults` |
| `core/internal/llm/prompt.go` | Export `DefaultPrompt`, make `renderPrompt` accept prompt template as param |
| `core/internal/llm/anthropic.go` | Pass `cfg.LLMPrompt` to `renderPrompt` |
| `core/internal/llm/openai.go` | Pass `cfg.LLMPrompt` to `renderPrompt` |
| `core/internal/llm/ollama.go` | Pass `cfg.LLMPrompt` to `renderPrompt` |
| `mac/Packages/HowlCore/.../Bridge/Preset.swift` | Add `prompt` field |
| `mac/Packages/HowlCore/.../Bridge/EngineConfig.swift` | Add `llmPrompt` field |
| `mac/Packages/HowlCore/.../Storage/SettingsStore.swift` | Add `llmPrompt` to `UserSettings`, stamp in `applying()` |
| `mac/Howl/UI/Settings/PromptTab.swift` | New file: Prompt tab view |
| `mac/Howl/UI/Settings/SettingsView.swift` | Add Prompt tab to sidebar |
| `mac/Howl/UI/Settings/Pipeline/PresetDraft.swift` | Add `prompt` to draft model |
