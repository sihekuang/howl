import SwiftUI
import HowlCore

struct PromptTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let presets: any PresetsClient

    @State private var allPresets: [Preset] = []
    @State private var editablePrompt: String = ""
    @State private var showSaveAs = false
    @State private var draftForSaveAs = PresetDraft(Preset(name: "", description: "", frameStages: [], chunkStages: [], transcribe: .init(modelSize: "small"), llm: .init(provider: "anthropic")))

    private var activePreset: Preset? {
        allPresets.first(where: { $0.name == settings.selectedPresetName })
    }

    private var isBuiltIn: Bool {
        activePreset?.isBundled ?? true
    }

    private var presetPickerBinding: Binding<String> {
        Binding(
            get: { settings.selectedPresetName ?? "" },
            set: { name in
                guard !name.isEmpty,
                      let preset = allPresets.first(where: { $0.name == name })
                else { return }
                settings = settings.applying(preset)
                if !preset.prompt.isEmpty { settings.llmPrompt = preset.prompt }
                onSave(settings)
                syncPromptFromSettings()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            presetLabel
            editorSection
            previewSection
        }
        .task { await loadPresets() }
        .onChange(of: settings.selectedPresetName) {
            syncPromptFromSettings()
        }
        .sheet(isPresented: $showSaveAs) {
            SaveAsPresetSheet(
                draft: draftForSaveAs,
                presets: presets,
                onSaved: {
                    showSaveAs = false
                    Task { await loadPresets() }
                },
                onCancel: { showSaveAs = false }
            )
        }
    }

    // MARK: - Subviews

    private var presetLabel: some View {
        HStack {
            Text("Prompt for:")
                .foregroundStyle(.secondary)
            Picker("", selection: presetPickerBinding) {
                ForEach(allPresets) { preset in
                    Text(preset.displayName).tag(preset.name)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            if isBuiltIn {
                Button("Duplicate to Edit") {
                    guard let source = activePreset ?? allPresets.first else { return }
                    let draft = PresetDraft(source)
                    draft.prompt = editablePrompt
                    draftForSaveAs = draft
                    showSaveAs = true
                }
                .controlSize(.small)
            } else {
                Button("Save") { savePromptInPlace() }
                    .controlSize(.small)
                    .disabled(editablePrompt == (activePreset?.prompt ?? ""))
                Button("Revert") { syncPromptFromSettings() }
                    .controlSize(.small)
                    .disabled(editablePrompt == (activePreset?.prompt ?? ""))
            }
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
            VStack(alignment: .leading, spacing: 2) {
                Label("{{dictionary}} is replaced with your dictionary terms", systemImage: "book")
                Label("{{transcription}} is replaced with the raw transcription", systemImage: "waveform")
                Label("If omitted, both are appended automatically", systemImage: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
        let hasDictionary = prompt.contains("{{dictionary}}")
        let hasTranscription = prompt.contains("{{transcription}}")
        var result = prompt
        if hasDictionary {
            result = result.replacingOccurrences(of: "{{dictionary}}", with: terms)
        }
        if hasTranscription {
            result = result.replacingOccurrences(of: "{{transcription}}", with: sample)
        }
        if !hasDictionary {
            result += "\n\nPreserve these terms verbatim: " + terms
        }
        if !hasTranscription {
            result += "\n\nRaw transcription:\n" + sample
        }
        return result
    }
}

private let defaultPromptText = """
You are a transcription editor. Your job is to MINIMALLY edit the transcription below, not to rewrite it. Apply only these changes:
- Remove filler words: um, uh, er, ah, like, you know, basically, I mean, sort of, kind of (when used as fillers)
- Fix obvious grammar and punctuation
- Drop any bracketed sound/music annotations Whisper inserts: (music), (water splashing), [Applause], [Laughter], etc. — these are NOT what the speaker said
- Preserve technical terms verbatim: {{dictionary}}

Hard rules:
- Do NOT paraphrase or restructure sentences. Keep the speaker's exact phrasing.
- Do NOT add words, ideas, or context the speaker did not say.
- Do NOT turn fragments into complete sentences if the speaker spoke fragments.
- If the input is empty, dropped to nothing after cleanup, or only sound annotations, return an empty string.
- Return ONLY the cleaned text — no preamble, no explanation, no quotes around the output.

Raw transcription:
{{transcription}}
"""
