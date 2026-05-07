// mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift
import SwiftUI
import VoiceKeyboardCore

/// Slice 3 Editor: preset picker → editable StageGraph + StageDetailPanel
/// + timeout field. Edits accumulate on a PresetDraft until saved via
/// SaveAsPresetSheet (which serializes the draft).
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
