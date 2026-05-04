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

    // MARK: - Drop logic

    /// Apply a frame-lane move + run the constraint validator. Returns
    /// false (and surfaces an inline message) when the resulting order
    /// would be sample-rate-incompatible — drop is refused, the row
    /// stays where it was. Compare with the Slice 3 behavior, which
    /// applied + reverted; refusing on drop keeps the visual stable.
    @discardableResult
    private func tryFrameMove(source: StageRef, dest: StageRef) -> Bool {
        let stages = draft.frameStages
        guard let s = stages.firstIndex(where: { $0.name == source.name }),
              let d = stages.firstIndex(where: { $0.name == dest.name }),
              s != d else { return false }
        var test = stages
        let item = test.remove(at: s)
        let insertAt = d > s ? d - 1 : d
        test.insert(item, at: insertAt)
        let errs = StageConstraintValidator.validate(frameStages: test)
        if !errs.isEmpty {
            lastInvalidMoveMessage = errs[0].message
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if lastInvalidMoveMessage == errs[0].message {
                    lastInvalidMoveMessage = nil
                }
            }
            return false
        }
        draft.frameStages = test
        lastInvalidMoveMessage = nil
        return true
    }

    private func tryChunkMove(source: StageRef, dest: StageRef) -> Bool {
        let stages = draft.chunkStages
        guard let s = stages.firstIndex(where: { $0.name == source.name }),
              let d = stages.firstIndex(where: { $0.name == dest.name }),
              s != d else { return false }
        var next = stages
        let item = next.remove(at: s)
        let insertAt = d > s ? d - 1 : d
        next.insert(item, at: insertAt)
        draft.chunkStages = next
        return true
    }

    private func performDrop(source: StageRef, dest: StageRef) -> Bool {
        defer { hoverTarget = nil }
        if source == dest { return true }
        if source.lane != dest.lane { return false } // cross-lane blocked
        switch dest.lane {
        case .frame: return tryFrameMove(source: source, dest: dest)
        case .chunk: return tryChunkMove(source: source, dest: dest)
        }
    }
}
