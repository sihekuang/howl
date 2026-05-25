import SwiftUI
import HowlCore

struct PromptTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let presets: any PresetsClient

    @State private var allPresets: [Preset] = []
    @State private var editablePrompt: String = ""
    @State private var showSaveAs = false
    @State private var draftForSaveAs: PresetDraft? = nil

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
            if let draft = draftForSaveAs {
                SaveAsPresetSheet(
                    draft: draft,
                    presets: presets,
                    onSaved: {
                        showSaveAs = false
                        Task { await loadPresets() }
                    },
                    onCancel: { showSaveAs = false }
                )
            }
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
                    guard let source = activePreset ?? allPresets.first else { return }
                    let draft = PresetDraft(source)
                    draft.prompt = editablePrompt
                    draftForSaveAs = draft
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
