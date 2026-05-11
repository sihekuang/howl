// mac/Howl/UI/Settings/Pipeline/StageDetailPane.swift
import SwiftUI
import HowlCore

/// Right-pane detail view. Switches on the selected stage:
///   - nil:                   placeholder
///   - .frame:                "no tunables" hint + Enabled is on the row
///   - .chunk(tse):           backend / threshold / recent similarity
///   - .terminal(whisper):    model-size picker + "Manage in General →"
///   - .terminal(dict):       N-terms + "Edit in Dictionary →"
///   - .terminal(llm):        provider + model + "Manage in LLM Provider →"
///
/// All editable controls dim when `editingDisabled` is true. Bodies for
/// the three terminal stages live in TerminalStageBodies.swift.
struct StageDetailPane: View {
    @Bindable var draft: PresetDraft
    let sessions: any SessionsClient
    @Binding var settings: UserSettings
    let editingDisabled: Bool
    let navigateTo: (SettingsPage) -> Void

    @State private var recentSimilarities: [Float] = []
    @State private var loadError: String? = nil

    var body: some View {
        if let ref = draft.selectedStage {
            VStack(alignment: .leading, spacing: 10) {
                header(ref: ref)
                Divider()
                content(for: ref)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: ref) {
                if ref.lane == .chunk && ref.name == "tse" {
                    await refreshSimilarity()
                }
            }
        } else {
            Text("Select a stage to edit its tunables.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    @ViewBuilder
    private func header(ref: StageRef) -> some View {
        HStack {
            Text(ref.name).font(.callout).bold()
            Text("(\(laneLabel(ref.lane)))").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Deselect") { draft.selectedStage = nil }
                .controlSize(.small)
        }
    }

    private func laneLabel(_ lane: StageRef.Lane) -> String {
        switch lane {
        case .frame:    return "frame"
        case .chunk:    return "chunk"
        case .terminal: return "terminal"
        }
    }

    @ViewBuilder
    private func content(for ref: StageRef) -> some View {
        switch ref.lane {
        case .frame:
            Text("No tunables — toggle this stage on or off via the checkbox in the row.")
                .font(.caption).foregroundStyle(.secondary)
        case .chunk:
            if ref.name == "tse", let stage = draft.stage(for: ref) {
                tseBody(ref: ref, stage: stage)
                    .disabled(editingDisabled)
            } else {
                Text("No tunables.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .terminal:
            switch ref.name {
            case "whisper":
                WhisperStageBody(
                    draft: draft,
                    settings: $settings,
                    isBundled: editingDisabled,
                    navigateTo: navigateTo
                )
            case "dict":
                DictStageBody(settings: $settings, navigateTo: navigateTo)
            case "llm":
                LLMStageBody(
                    draft: draft,
                    settings: $settings,
                    isBundled: editingDisabled,
                    navigateTo: navigateTo
                )
            default:
                Text("Unknown terminal stage \(ref.name)")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Existing tse body (preserved verbatim from the pre-redesign pane)

    @ViewBuilder
    private func tseBody(ref: StageRef, stage: Preset.StageSpec) -> some View {
        backendRow(ref: ref, stage: stage)
        thresholdRow(ref: ref, stage: stage)
        recentSimilarityRow(stage: stage)
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
