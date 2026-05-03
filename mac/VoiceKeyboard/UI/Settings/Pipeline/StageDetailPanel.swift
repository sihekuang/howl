// mac/VoiceKeyboard/UI/Settings/Pipeline/StageDetailPanel.swift
import SwiftUI
import VoiceKeyboardCore

/// Per-stage detail panel shown below the StageGraph when a stage is
/// selected. Tunables vary by stage:
///   - All stages: Enabled toggle.
///   - tse only:   Backend dropdown, Threshold slider, Recent similarity.
struct StageDetailPanel: View {
    @Bindable var draft: PresetDraft
    let sessions: any SessionsClient

    @State private var recentSimilarities: [Float] = []
    @State private var loadError: String? = nil

    private var selected: Preset.StageSpec? {
        guard let ref = draft.selectedStage else { return nil }
        return draft.stage(for: ref)
    }

    var body: some View {
        if let ref = draft.selectedStage, let stage = selected {
            VStack(alignment: .leading, spacing: 10) {
                header(ref: ref, stage: stage)
                Divider()
                enabledRow(ref: ref, stage: stage)
                if stage.name == "tse" {
                    backendRow(ref: ref, stage: stage)
                    thresholdRow(ref: ref, stage: stage)
                    recentSimilarityRow(stage: stage)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: ref) { await refreshSimilarity() }
        } else {
            Text("Select a stage to edit its tunables.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    @ViewBuilder
    private func header(ref: StageRef, stage: Preset.StageSpec) -> some View {
        HStack {
            Text(stage.name).font(.callout).bold()
            Text("(\(ref.lane == .frame ? "frame" : "chunk"))")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Deselect") { draft.selectedStage = nil }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func enabledRow(ref: StageRef, stage: Preset.StageSpec) -> some View {
        Toggle(isOn: Binding(
            get: { stage.enabled },
            set: { draft.setEnabled($0, for: ref) }
        )) {
            Text("Enabled")
        }
    }

    @ViewBuilder
    private func backendRow(ref: StageRef, stage: Preset.StageSpec) -> some View {
        HStack {
            Text("Backend").frame(width: 96, alignment: .leading)
            Picker("", selection: Binding(
                get: { stage.backend ?? "ecapa" },
                set: { draft.setBackend($0, for: ref) }
            )) {
                Text("ecapa").tag("ecapa")
                // Future backends append here as they land.
            }
            .labelsHidden()
            .frame(maxWidth: 160)
            Spacer()
        }
    }

    @ViewBuilder
    private func thresholdRow(ref: StageRef, stage: Preset.StageSpec) -> some View {
        let threshold = stage.threshold ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Threshold").frame(width: 96, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(threshold) },
                    set: { draft.setThreshold(Float($0), for: ref) }
                ), in: 0...1, step: 0.05)
                Text(String(format: "%.2f", threshold))
                    .font(.callout.monospaced())
                    .frame(width: 44, alignment: .trailing)
            }
            Text("Below threshold the chunk is silenced; 0 disables gating.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func recentSimilarityRow(stage: Preset.StageSpec) -> some View {
        let threshold = stage.threshold ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent").frame(width: 96, alignment: .leading)
                if recentSimilarities.isEmpty {
                    Text("(no captured chunks yet)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(Array(recentSimilarities.enumerated()), id: \.offset) { _, s in
                            Text(String(format: "%.2f", s))
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(s >= threshold ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                }
                Spacer()
            }
            if let err = loadError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func refreshSimilarity() async {
        do {
            let probe = RecentSimilarityProbe(sessions: sessions)
            let got = try await probe.recent(limit: 5)
            await MainActor.run { self.recentSimilarities = got; self.loadError = nil }
        } catch {
            await MainActor.run { self.loadError = "Couldn't load recent similarity: \(error)" }
        }
    }
}
