// mac/Howl/UI/Settings/Pipeline/TerminalStageBodies.swift
import SwiftUI
import HowlCore

// MARK: - Whisper

/// Whisper stage detail.
///
/// - Bundled (default) preset → read-only display of the user's global
///   Whisper model from General. The bundled preset deliberately does
///   not override that global; an info banner explains the rule and
///   nudges users to "Save as…" if they want a per-preset pin.
/// - User-created preset → editable model picker pinned to the preset.
///   Same labels as GeneralTab (✓ prefix for downloaded sizes); does
///   not start downloads — that flow lives in General.
struct WhisperStageBody: View {
    @Bindable var draft: PresetDraft
    @Binding var settings: UserSettings
    let isBundled: Bool
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
                if isBundled {
                    Text(displayLabel(for: settings.whisperModelSize))
                        .font(.callout)
                } else {
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
                }
                Spacer()
            }
            Text(footnote)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                ManageElsewhereButton(target: .general, label: "Manage in General →", navigateTo: navigateTo)
            }
        }
    }

    private var footnote: String {
        if isBundled {
            return "Default presets use your global Whisper model from General. Save as… to pin a different model to a copy of this preset."
        } else {
            return "Per-preset Whisper model. Manage which model files are downloaded in General → Whisper model."
        }
    }

    private func label(for m: (size: String, label: String, mb: String)) -> String {
        let path = ModelPaths.whisperModel(size: m.size).path
        let mark = FileManager.default.fileExists(atPath: path) ? "✓" : " "
        return "\(mark) \(m.label) (\(m.mb))"
    }

    private func displayLabel(for size: String) -> String {
        modelSizes.first(where: { $0.size == size }).map { "\($0.label) (\($0.mb))" } ?? size
    }
}

// MARK: - Dict (always global)

/// Read-only summary of the user's custom dictionary. Dictionary terms
/// are always global — every preset (bundled or user-created) uses the
/// same list, so this view doesn't branch on `isBundled`.
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

/// LLM stage detail.
///
/// - Bundled (default) preset → read-only display of the user's global
///   provider/model from LLM Provider. The bundled preset does not
///   override those globals; users wanting a pinned LLM choice should
///   "Save as…" first.
/// - User-created preset → editable provider + model controls. Provider
///   list and curated model list both come from LLMProviderCatalog so
///   this stays in sync with LLMProviderTab. For local providers
///   (ollama, lmstudio) where the curated list is empty, the model
///   field falls back to a TextField for free-form names.
struct LLMStageBody: View {
    @Bindable var draft: PresetDraft
    @Binding var settings: UserSettings
    let isBundled: Bool
    let navigateTo: (SettingsPage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Provider").frame(width: 96, alignment: .leading)
                if isBundled {
                    Text(providerLabel(for: settings.llmProvider))
                        .font(.callout)
                } else {
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
                }
                Spacer()
            }
            HStack {
                Text("Model").frame(width: 96, alignment: .leading)
                if isBundled {
                    Text(settings.llmModel.isEmpty ? "(provider default)" : settings.llmModel)
                        .font(.callout.monospaced())
                } else {
                    modelControl
                }
                Spacer()
            }
            Text(footnote)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                ManageElsewhereButton(target: .provider, label: "Manage in LLM Provider →", navigateTo: navigateTo)
            }
        }
    }

    private var footnote: String {
        if isBundled {
            return "Default presets use your global LLM provider/model from LLM Provider. Save as… to pin a different provider or model to a copy of this preset."
        } else {
            return "Pinned to this preset. API keys, base URLs, and the global default provider/model live in LLM Provider."
        }
    }

    private func providerLabel(for id: String) -> String {
        LLMProviderCatalog.providers.first(where: { $0.id == id })?.label ?? id
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
