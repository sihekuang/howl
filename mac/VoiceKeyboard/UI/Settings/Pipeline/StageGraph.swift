// mac/VoiceKeyboard/UI/Settings/Pipeline/StageGraph.swift
import SwiftUI
import VoiceKeyboardCore

/// Three-lane drag-drop pipeline graph:
/// - Frame lane (denoise, decimate3) — reorderable within lane.
/// - Chunker boundary — visual separator.
/// - Chunk lane (tse) — reorderable within lane.
/// - Fixed terminal (whisper → dict → llm) — rendered, not draggable.
///
/// Cross-lane drags are structurally blocked by SwiftUI: each List has
/// its own drop target.
struct StageGraph: View {
    @Bindable var draft: PresetDraft

    @State private var frameValidationErrors: [StageConstraintValidator.ValidationError] = []
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

    // MARK: - Frame lane

    @ViewBuilder
    private var frameLane: some View {
        List {
            ForEach(Array(draft.frameStages.enumerated()), id: \.element.name) { i, stage in
                stageRow(stage,
                         lane: .frame,
                         hasError: frameValidationErrors.contains(where: { $0.index == i }))
            }
            .onMove { source, destination in
                attemptFrameMove(from: source, to: destination)
            }
        }
        .listStyle(.plain)
        .frame(minHeight: laneMinHeight(rowCount: draft.frameStages.count))
    }

    private func attemptFrameMove(from source: IndexSet, to destination: Int) {
        // Snapshot, apply, validate, revert if invalid.
        let snapshot = draft.frameStages
        draft.moveFrameStage(from: source, to: destination)
        let errs = StageConstraintValidator.validate(frameStages: draft.frameStages)
        if !errs.isEmpty {
            // Revert + surface the first error inline.
            draft.frameStages = snapshot
            lastInvalidMoveMessage = errs[0].message
            frameValidationErrors = []
            // Auto-clear the error after a few seconds so the lane
            // doesn't carry a stale red tooltip forever.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if lastInvalidMoveMessage == errs[0].message {
                    lastInvalidMoveMessage = nil
                }
            }
        } else {
            lastInvalidMoveMessage = nil
            frameValidationErrors = []
        }
    }

    // MARK: - Chunk lane

    @ViewBuilder
    private var chunkLane: some View {
        List {
            ForEach(Array(draft.chunkStages.enumerated()), id: \.element.name) { _, stage in
                stageRow(stage, lane: .chunk, hasError: false)
            }
            .onMove { source, destination in
                draft.moveChunkStage(from: source, to: destination)
                // No rate validation today — the chunk lane has only
                // tse, which is rate-preserving.
            }
        }
        .listStyle(.plain)
        .frame(minHeight: laneMinHeight(rowCount: draft.chunkStages.count))
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
            Image(systemName: "lock.fill").foregroundStyle(.tertiary).font(.caption)
            Text(name).font(.callout).bold()
            Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Stage row (frame + chunk)

    @ViewBuilder
    private func stageRow(_ stage: Preset.StageSpec, lane: StageRef.Lane, hasError: Bool) -> some View {
        let ref = StageRef(lane: lane, name: stage.name)
        HStack {
            Image(systemName: stage.enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(stage.enabled ? .green : .secondary)
            Text(stage.name).font(.callout).bold()
            if let backend = stage.backend, !backend.isEmpty {
                Text(backend).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(draft.selectedStage == ref ? Color.accentColor.opacity(0.15) : Color.clear)
        .onTapGesture {
            draft.selectedStage = (draft.selectedStage == ref) ? nil : ref
        }
    }

    private func laneMinHeight(rowCount: Int) -> CGFloat {
        // SwiftUI List in a constrained Settings pane needs an explicit
        // min height or rows squash. ~28pt per row + a little breathing
        // room; minimum 1 row's worth so an empty lane still shows.
        let perRow: CGFloat = 28
        return CGFloat(max(1, rowCount)) * perRow + 8
    }
}
