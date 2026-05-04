// mac/VoiceKeyboard/UI/Settings/Pipeline/StageGraph.swift
import SwiftUI
import VoiceKeyboardCore

/// Three-lane drag-drop pipeline graph:
/// - Frame lane (denoise, decimate3) — reorderable within lane.
/// - Chunker boundary — visual separator.
/// - Chunk lane (tse) — reorderable within lane.
/// - Fixed terminal (whisper → dict → llm) — rendered, not draggable.
///
/// Built on `.draggable(_:)` + `.dropDestination(for:)` for first-class
/// macOS drag affordances: a leading hamburger handle on each row,
/// a custom drag preview that names the stage, and pre-drop validation
/// that highlights invalid targets in red rather than accepting and
/// reverting after the fact.
struct StageGraph: View {
    @Bindable var draft: PresetDraft

    /// Stage currently being hovered as a drop target.
    @State private var hoverTarget: StageRef? = nil
    /// Inline error surfaced when an invalid drop is rejected.
    @State private var lastInvalidMoveMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            laneHeader("Streaming stages", subtitle: "frame-rate; runs on every pushed buffer")
            frameLane
            if let err = lastInvalidMoveMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }

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
                draggableRow(stage, lane: .frame)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var chunkLane: some View {
        VStack(spacing: 4) {
            ForEach(draft.chunkStages, id: \.name) { stage in
                draggableRow(stage, lane: .chunk)
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

    // MARK: - Draggable row

    @ViewBuilder
    private func draggableRow(_ stage: Preset.StageSpec, lane: StageRef.Lane) -> some View {
        let ref = StageRef(lane: lane, name: stage.name)
        let isSelected = draft.selectedStage == ref
        let isHovered = hoverTarget == ref

        rowBody(stage, ref: ref, isSelected: isSelected, dragHandleVisible: true)
            .background(rowBackground(isSelected: isSelected, isHovered: isHovered))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture {
                draft.selectedStage = (draft.selectedStage == ref) ? nil : ref
            }
            .draggable(ref) {
                rowBody(stage, ref: ref, isSelected: false, dragHandleVisible: false)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    )
                    .shadow(radius: 4)
            }
            .dropDestination(for: StageRef.self) { items, _ in
                guard let dropped = items.first else { return false }
                return performDrop(source: dropped, dest: ref)
            } isTargeted: { targeted in
                if targeted {
                    hoverTarget = ref
                } else if hoverTarget == ref {
                    hoverTarget = nil
                }
            }
    }

    @ViewBuilder
    private func rowBody(_ stage: Preset.StageSpec, ref: StageRef, isSelected: Bool, dragHandleVisible: Bool) -> some View {
        HStack(spacing: 6) {
            if dragHandleVisible {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .help("Drag to reorder within lane")
            }
            Image(systemName: stage.enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(stage.enabled ? .green : .secondary)
            Text(stage.name).font(.callout).bold()
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            if let backend = stage.backend, !backend.isEmpty {
                Text(backend)
                    .font(.caption.monospaced())
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
            Spacer()
            Text(ref.lane == .frame ? "frame" : "chunk")
                .font(.caption2)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func rowBackground(isSelected: Bool, isHovered: Bool) -> some View {
        if isHovered {
            Color.accentColor.opacity(0.18)
        } else if isSelected {
            Color.accentColor
        } else {
            Color.clear
        }
    }

    // MARK: - Drop logic — delegates to StageDropPlanner so the
    // semantics are unit-tested (tests live in VoiceKeyboardCore;
    // see StageDropPlannerTests).

    private func performDrop(source: StageRef, dest: StageRef) -> Bool {
        defer { hoverTarget = nil }
        if source == dest { return true }
        if source.lane != dest.lane { return false } // cross-lane blocked
        switch dest.lane {
        case .frame:
            let result = StageDropPlanner.planMove(
                in: draft.frameStages,
                sourceName: source.name,
                destName: dest.name,
                validate: { StageConstraintValidator.validate(frameStages: $0) }
            )
            if result.accepted {
                draft.frameStages = result.newStages
                lastInvalidMoveMessage = nil
                return true
            }
            if let msg = result.validationError {
                lastInvalidMoveMessage = msg
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if lastInvalidMoveMessage == msg {
                        lastInvalidMoveMessage = nil
                    }
                }
            }
            return false
        case .chunk:
            let result = StageDropPlanner.planMove(
                in: draft.chunkStages,
                sourceName: source.name,
                destName: dest.name,
                validate: nil
            )
            if result.accepted {
                draft.chunkStages = result.newStages
                return true
            }
            return false
        }
    }
}
