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
                } else if let p = list.first(where: { $0.name == self.selectedName }),
                          !(self.draft?.isDirty ?? false) {
                    // Refresh while clean: re-anchor the source baseline
                    // so any disk-side normalization (e.g. timeoutSec
                    // defaults) becomes the new baseline. Use markSaved
                    // rather than replacing the draft so the user's
                    // selectedStage survives an external refresh. Skip
                    // entirely when the draft is dirty — preserves
                    // work-in-progress.
                    self.draft?.markSaved(as: p)
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
        let p = draft.toPreset(name: draft.source.name, description: draft.source.description)
        do {
            try await presets.save(p)
            await MainActor.run {
                overwriteConfirmVisible = false
                saving = false
                // Re-anchor the draft so isDirty resets and the "edited"
                // badge clears — without losing the user's selected stage.
                self.draft?.markSaved(as: p)
                // Replace the matching entry in our in-memory preset list
                // so the picker + summary reflect the saved version. We
                // skip a full refresh here because the only change on
                // disk is the one we just made.
                if let idx = self.presetList.firstIndex(where: { $0.name == p.name }) {
                    self.presetList[idx] = p
                }
            }
        } catch {
            await MainActor.run {
                saveError = "Save failed: \(error)"
                saving = false
            }
        }
    }
}
