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
