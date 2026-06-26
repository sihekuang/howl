// mac/Howl/UI/Settings/Pipeline/EditorView.swift
import SwiftUI
import HowlCore

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
    /// Session-scoped preset selection (owned by CompositionRoot) so a
    /// manual pick survives this view being recreated on navigation.
    @ObservedObject var editorState: PipelineEditorState
    let navigateTo: (SettingsPage) -> Void

    @State private var presetList: [Preset] = []
    @State private var draft: PresetDraft? = nil
    @State private var loadError: String? = nil
    @State private var saveSheetVisible = false
    @State private var overwriteConfirmVisible = false
    @State private var deleteConfirmVisible = false
    @State private var saveError: String? = nil
    @State private var saving = false
    @State private var deleting = false
    /// Increments on every "click on a disabled control while a bundled
    /// preset is selected" — drives a transient pulse on the Save as…
    /// button so the user notices the alternative.
    @State private var saveAsPulseTrigger: Int = 0

    private var isBundled: Bool { draft?.source.isBundled ?? false }

    /// Bridges the optional session selection to the Picker's non-optional
    /// `Binding<String>` ("" when nothing is chosen, matching the "(none)"
    /// tag).
    private var selection: Binding<String> {
        Binding(
            get: { editorState.selectedPresetName ?? "" },
            set: { editorState.selectedPresetName = $0.isEmpty ? nil : $0 }
        )
    }

    /// True when the preset being edited is the one currently applied to
    /// the running pipeline — drives the "● Active preset" caption and the
    /// "· active" marker in the picker.
    private var isSelectedActive: Bool {
        guard let active = settings.selectedPresetName else { return false }
        return editorState.selectedPresetName == active
    }

    /// Picker label with a trailing "· active" marker on the active preset
    /// so the user can locate the live config in the dropdown.
    private func pickerLabel(for preset: Preset) -> String {
        preset.name == settings.selectedPresetName
            ? "\(preset.displayName) · active"
            : preset.displayName
    }

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
        .sheet(isPresented: $deleteConfirmVisible) {
            if let draft = draft {
                DeletePresetConfirmSheet(
                    presetName: draft.source.name,
                    deleting: deleting,
                    onCancel: { deleteConfirmVisible = false },
                    onConfirm: { Task { await performDelete() } }
                )
            }
        }
        .onChange(of: editorState.selectedPresetName) { _, newName in
            if let newName, let p = presetList.first(where: { $0.name == newName }) {
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
                Picker("Preset", selection: selection) {
                    if presetList.isEmpty {
                        Text("(none)").tag("")
                    } else {
                        ForEach(presetList) { p in
                            Text(pickerLabel(for: p)).tag(p.name)
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            if isSelectedActive {
                Text("● Active preset").font(.caption).foregroundStyle(.green)
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
                    if let name = editorState.selectedPresetName,
                       let p = presetList.first(where: { $0.name == name }) {
                        draft?.resetTo(p)
                    }
                } label: { Label("Reset", systemImage: "arrow.uturn.backward") }
                .controlSize(.small)
                .disabled(draft?.isDirty != true || isBundled)
                if !isBundled, draft != nil {
                    Button(role: .destructive) {
                        deleteConfirmVisible = true
                    } label: { Label("Delete", systemImage: "trash") }
                    .controlSize(.small)
                }
            }
        }
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

    /// Preset to default the picker to when there's no valid remembered
    /// selection: the active preset (the one applied to the running
    /// pipeline), else "default", else the first available.
    private func seedPreset(from list: [Preset]) -> Preset? {
        list.first(where: { $0.name == settings.selectedPresetName })
            ?? list.first(where: { $0.name == "default" })
            ?? list.first
    }

    private func refresh() async {
        do {
            let list = try await presets.list()
            await MainActor.run {
                self.presetList = list
                if let current = self.editorState.selectedPresetName,
                   let p = list.first(where: { $0.name == current }) {
                    // Remembered selection still valid (a prior pick this
                    // app run).
                    if self.draft == nil {
                        // Fresh view — recreated on navigation while the
                        // selection lived on in editorState. Rebuild the
                        // draft for the remembered preset so the right pane
                        // renders.
                        self.draft = PresetDraft(p)
                    } else if !(self.draft?.isDirty ?? false) {
                        // Clean refresh of an existing draft: re-anchor the
                        // source baseline so any disk-side normalization
                        // (e.g. timeoutSec defaults) becomes the new
                        // baseline. Use markSaved rather than replacing the
                        // draft so the user's selectedStage survives.
                        // Skip when dirty — preserves work-in-progress.
                        self.draft?.markSaved(as: p)
                    }
                } else if let seed = self.seedPreset(from: list) {
                    // No valid remembered selection — first open this app
                    // run, no active preset (legacy installs), or the
                    // remembered/active preset was deleted. Default to the
                    // active preset, falling back to "default" then first.
                    self.editorState.selectedPresetName = seed.name
                    self.draft = PresetDraft(seed)
                }
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                self.loadError = "Failed to load presets: \(error)"
            }
        }
    }

    private func performDelete() async {
        guard let draft = draft else { return }
        let name = draft.source.name
        await MainActor.run { deleting = true; saveError = nil }
        do {
            try await presets.delete(name)
            await MainActor.run {
                deleteConfirmVisible = false
                deleting = false
                // Drop the deleted entry from the in-memory list and
                // pick a successor — prefer "default" if present, else
                // the first remaining preset.
                self.presetList.removeAll { $0.name == name }
                let next = self.presetList.first(where: { $0.name == "default" })
                    ?? self.presetList.first
                if let next {
                    self.editorState.selectedPresetName = next.name
                    self.draft = PresetDraft(next)
                } else {
                    self.editorState.selectedPresetName = nil
                    self.draft = nil
                }
            }
        } catch {
            await MainActor.run {
                saveError = "Delete failed: \(error)"
                deleting = false
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
