// mac/VoiceKeyboard/UI/Settings/Pipeline/StageList.swift
import SwiftUI
import VoiceKeyboardCore

/// Three-lane pipeline graph (read-only ordering). Stages render in
/// the order their preset declares; the user toggles each stage on or
/// off via the detail panel below. Reordering was tried in earlier
/// slices but the small lanes (2-3 stages each, with audio-engineering
/// constraints between them) made drag-drop more friction than value.
///
/// Lanes:
/// - Frame (denoise, decimate3) — runs on every pushed buffer.
/// - Chunker boundary — visual separator.
/// - Chunk (tse) — runs once per utterance chunk.
/// - Terminal (whisper, dict, llm) — fixed.
struct StageList: View {
    @Bindable var draft: PresetDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            laneHeader("Streaming stages", subtitle: "frame-rate; runs on every pushed buffer")
            frameLane

            chunkerBoundary

            laneHeader("Per-utterance stages", subtitle: "chunk-rate; runs once per utterance chunk")
            chunkLane

            laneHeader("Transcribe + cleanup", subtitle: "fixed terminal chain")
            fixedTerminal
        }
    }

    // MARK: - Lane headers + boundary

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

    // MARK: - Lanes

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

    // MARK: - Fixed terminal

    @ViewBuilder
    private var fixedTerminal: some View {
        VStack(alignment: .leading, spacing: 4) {
            terminalRow(name: "whisper", subtitle: draft.transcribeModelSize)
            terminalRow(name: "dict",    subtitle: "fuzzy correction")
            terminalRow(name: "llm",     subtitle: draft.llmProvider)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func terminalRow(name: String, subtitle: String) -> some View {
        HStack {
            Image(systemName: "lock.fill")
                .foregroundStyle(.tertiary).font(.caption)
                .frame(width: 14)
            Text(name).font(.callout).bold()
            Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Stage row (frame + chunk)

    @ViewBuilder
    private func stageRow(_ stage: Preset.StageSpec, lane: StageRef.Lane) -> some View {
        let ref = StageRef(lane: lane, name: stage.name)
        let isSelected = draft.selectedStage == ref
        HStack(spacing: 6) {
            // Inline enable/disable toggle in place of the static
            // checkmark. Toggle handles its own gesture so tapping
            // the checkbox doesn't trigger the row's select behavior.
            Toggle("", isOn: Binding(
                get: { stage.enabled },
                set: { draft.setEnabled($0, for: ref) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
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
            draft.selectedStage = (draft.selectedStage == ref) ? nil : ref
        }
    }
}
