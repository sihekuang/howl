// mac/VoiceKeyboard/UI/Settings/Pipeline/EditorView.swift
import SwiftUI
import VoiceKeyboardCore

/// Slice 2 Editor: preset dropdown + Save/Reset + per-stage detail
/// panel showing TSE threshold + recent similarity. The drag-and-drop
/// stage graph is Slice 3.
struct EditorView: View {
    let presets: any PresetsClient

    @State private var presetList: [Preset] = []
    @State private var selectedName: String = ""
    @State private var loadError: String? = nil
    @State private var saveSheetVisible = false

    private var selectedPreset: Preset? {
        presetList.first(where: { $0.name == selectedName })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            Divider()
            if let p = selectedPreset {
                presetDetail(p)
            } else if let err = loadError {
                Text(err).foregroundStyle(.red).font(.callout)
            } else {
                Text("Loading presets…").foregroundStyle(.secondary).font(.callout)
            }
        }
        .task { await refresh() }
        .sheet(isPresented: $saveSheetVisible) {
            if let p = selectedPreset {
                SaveAsPresetSheet(
                    basePreset: p,
                    presets: presets,
                    onSaved: {
                        saveSheetVisible = false
                        Task { await refresh() }
                    },
                    onCancel: { saveSheetVisible = false }
                )
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
            .frame(maxWidth: 240)

            Button {
                saveSheetVisible = true
            } label: { Label("Save as…", systemImage: "square.and.arrow.down") }
            .controlSize(.small)
            .disabled(selectedName.isEmpty)

            Button {
                Task { await selectPreset("default") }
            } label: { Label("Reset", systemImage: "arrow.uturn.backward") }
            .controlSize(.small)

            Spacer()
        }
    }

    @ViewBuilder
    private func presetDetail(_ p: Preset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.description).font(.callout).foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Text("STAGES").font(.caption).foregroundStyle(.secondary).bold()
            ForEach(p.frameStages, id: \.name) { st in
                stageRow(st, kind: "frame")
            }
            ForEach(p.chunkStages, id: \.name) { st in
                stageRow(st, kind: "chunk")
            }

            Divider().padding(.vertical, 4)

            Text("TRANSCRIBE").font(.caption).foregroundStyle(.secondary).bold()
            HStack {
                Text("Whisper model").font(.callout)
                Spacer()
                Text(p.transcribe.modelSize).font(.callout.monospaced()).foregroundStyle(.secondary)
            }

            Text("LLM").font(.caption).foregroundStyle(.secondary).bold()
            HStack {
                Text("Provider").font(.callout)
                Spacer()
                Text(p.llm.provider).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func stageRow(_ st: Preset.StageSpec, kind: String) -> some View {
        HStack {
            Image(systemName: st.enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(st.enabled ? .green : .secondary)
            Text(st.name).font(.callout).bold()
            Text("(\(kind))").foregroundStyle(.secondary).font(.caption)
            Spacer()
            if st.name == "tse", let t = st.threshold {
                Text("threshold: \(String(format: "%.2f", t))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let backend = st.backend, !backend.isEmpty {
                Text(backend).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
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
                }
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                self.loadError = "Failed to load presets: \(error)"
            }
        }
    }

    private func selectPreset(_ name: String) async {
        await MainActor.run { self.selectedName = name }
    }
}
