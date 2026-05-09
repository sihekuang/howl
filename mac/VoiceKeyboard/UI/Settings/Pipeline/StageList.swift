// mac/VoiceKeyboard/UI/Settings/Pipeline/StageList.swift
import SwiftUI
import VoiceKeyboardCore

/// Left-column stage list for the Pipeline editor. Three sections:
///
/// - Streaming      (frame stages: denoise, decimate3)
/// - Per-utterance  (chunk stages: tse) — separated above by a CHUNKER divider
/// - Transcribe + cleanup (terminal stages: whisper, dict, llm) — selectable rows
///                  whose right-pane bodies live in StageDetailPane.
///
/// Toggle checkboxes on frame/chunk rows mutate `draft.setEnabled(...)` —
/// terminal rows have no toggle (they're always part of the pipeline)
/// and a chevron indicator instead.
///
/// All rows respect `editingDisabled` so bundled-preset selection
/// renders the controls dimmed; tapping a disabled control fires
/// `nudgeSaveAs` so EditorView can pulse the Save as… button.
struct StageList: View {
    @Bindable var draft: PresetDraft
    let editingDisabled: Bool
    let nudgeSaveAs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            laneHeader("Streaming", subtitle: "frame-rate; runs on every pushed buffer")
            frameLane

            chunkerBoundary

            laneHeader("Per-utterance", subtitle: "chunk-rate; runs once per utterance chunk")
            chunkLane

            laneHeader("Transcribe + cleanup", subtitle: "fixed terminal chain")
            terminalLane
        }
    }

    // MARK: - Headers + boundary

    @ViewBuilder
    private func laneHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).bold().foregroundStyle(.secondary)
            Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var chunkerBoundary: some View {
        HStack {
            Rectangle().fill(.secondary).frame(height: 1)
            Text("CHUNKER")
                .font(.caption2.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
                .foregroundStyle(.secondary)
            Rectangle().fill(.secondary).frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Frame + chunk lanes

    @ViewBuilder
    private var frameLane: some View {
        VStack(spacing: 4) {
            ForEach(draft.frameStages, id: \.name) { stage in
                stageRow(stage, lane: .frame)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var chunkLane: some View {
        VStack(spacing: 4) {
            ForEach(draft.chunkStages, id: \.name) { stage in
                stageRow(stage, lane: .chunk)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Terminal lane (whisper / dict / llm)

    @ViewBuilder
    private var terminalLane: some View {
        VStack(alignment: .leading, spacing: 4) {
            terminalRow(name: "whisper", subtitle: draft.transcribeModelSize)
            terminalRow(name: "dict",    subtitle: "fuzzy correction")
            terminalRow(name: "llm",     subtitle: llmSubtitle)
        }
        .padding(.vertical, 4)
    }

    private var llmSubtitle: String {
        if draft.llmModel.isEmpty {
            return draft.llmProvider
        }
        return "\(draft.llmProvider) · \(draft.llmModel)"
    }

    // MARK: - Rows

    @ViewBuilder
    private func stageRow(_ stage: Preset.StageSpec, lane: StageRef.Lane) -> some View {
        let ref = StageRef(lane: lane, name: stage.name)
        let isSelected = draft.selectedStage == ref
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { stage.enabled },
                set: { draft.setEnabled($0, for: ref) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(editingDisabled)

            Text(stage.name).font(.callout).bold()
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            if let backend = stage.backend, !backend.isEmpty {
                Text(backend)
                    .font(.caption.monospaced())
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
            Spacer()
            Text(lane == .frame ? "frame" : "chunk")
                .font(.caption2)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture {
            if editingDisabled {
                nudgeSaveAs()
            } else {
                draft.selectedStage = (draft.selectedStage == ref) ? nil : ref
            }
        }
    }

    @ViewBuilder
    private func terminalRow(name: String, subtitle: String) -> some View {
        let ref = StageRef(lane: .terminal, name: name)
        let isSelected = draft.selectedStage == ref
        HStack {
            Image(systemName: "chevron.right")
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                .font(.caption)
                .frame(width: 14)
            Text(name).font(.callout).bold()
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Text(subtitle).font(.caption.monospaced())
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture {
            // Terminal rows are still selectable in bundled-preset mode —
            // the right pane will show the values but its controls are
            // disabled. Tapping the row itself doesn't need a nudge.
            draft.selectedStage = (draft.selectedStage == ref) ? nil : ref
        }
    }
}
