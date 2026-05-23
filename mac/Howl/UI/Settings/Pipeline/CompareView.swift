// mac/Howl/UI/Settings/Pipeline/CompareView.swift
import SwiftUI
import HowlCore

/// Compare view: pick a captured session as the audio source, pick
/// one preset to replay it through, click Run, see source on the
/// left and the preset's replay on the right.
///
/// Both panes reuse SessionDetail (per-stage Play buttons + transport
/// bar + transcript Open buttons). Single shared WAVPlayer across both
/// panes — playing audio in one stops audio in the other.
struct CompareView: View {
    let sessions: any SessionsClient
    let presets: any PresetsClient
    let replay: any ReplayClient

    @State private var sessionList: [SessionManifest] = []
    @State private var presetList: [Preset] = []
    @State private var selectedSourceID: String? = nil
    @State private var selectedPresetName: String? = nil
    @State private var result: ReplayResult? = nil
    @State private var replayManifest: SessionManifest? = nil
    @State private var running = false
    @State private var loadError: String? = nil
    @State private var runError: String? = nil
    @State private var player = WAVPlayer()

    private var canRun: Bool {
        selectedSourceID != nil && selectedPresetName != nil && !running
    }

    private var sourceManifest: SessionManifest? {
        guard let id = selectedSourceID else { return nil }
        return sessionList.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            Divider()
            if let err = loadError {
                Text(err).font(.callout).foregroundStyle(.red)
            }
            HStack(alignment: .top, spacing: 10) {
                leftPane.frame(minWidth: 320, maxWidth: .infinity)
                rightPane.frame(minWidth: 320, maxWidth: .infinity)
            }
        }
        .task { await refresh() }
        .onChange(of: selectedSourceID) { _, _ in
            // Switching sources stops playback and clears the right
            // pane back to its empty state — the prior replay's
            // manifest belongs to a different source.
            player.stop()
            result = nil
            replayManifest = nil
            // Default the preset picker to the new source's preset
            // when the new source has one we recognize.
            if let sourcePreset = sourceManifest?.preset,
               presetList.contains(where: { $0.name == sourcePreset }) {
                selectedPresetName = sourcePreset
            }
        }
        .onChange(of: selectedPresetName) { _, _ in
            // Same teardown — comparing against a different preset
            // means the prior replay isn't relevant anymore.
            player.stop()
            result = nil
            replayManifest = nil
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Source:").foregroundStyle(.secondary).font(.callout)
            Picker("Source", selection: Binding(
                get: { selectedSourceID ?? sessionList.first?.id ?? "" },
                set: { if !$0.isEmpty { selectedSourceID = $0 } }
            )) {
                if sessionList.isEmpty {
                    Text("(no sessions)").tag("")
                } else {
                    ForEach(sessionList) { s in
                        Text("\(relativeTime(s.id)) · \(s.preset.isEmpty ? "—" : s.preset)")
                            .tag(s.id)
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)

            Text("Preset:").foregroundStyle(.secondary).font(.callout)
            Picker("Preset", selection: Binding(
                get: { selectedPresetName ?? "" },
                set: { if !$0.isEmpty { selectedPresetName = $0 } }
            )) {
                if presetList.isEmpty {
                    Text("(no presets)").tag("")
                } else {
                    ForEach(presetList) { p in
                        Text(p.name).tag(p.name)
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)

            Spacer()

            Button {
                Task { await runReplay() }
            } label: {
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Run", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canRun)
        }
    }

    // MARK: - Panes

    @ViewBuilder
    private var leftPane: some View {
        if let source = sourceManifest {
            ComparePane(
                label: "ORIGINAL",
                labelColor: Color.secondary,
                subtitle: paneSubtitle(for: source)
            ) {
                SessionDetail(manifest: source, player: player)
            }
        } else {
            ComparePane(
                label: "ORIGINAL",
                labelColor: Color.secondary,
                subtitle: "(no source selected)"
            ) {
                Text("Pick a captured session above.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var rightPane: some View {
        if let replay = replayManifest, let preset = selectedPresetName {
            ComparePane(
                label: preset.uppercased(),
                labelColor: Color.accentColor,
                subtitle: paneSubtitle(for: replay)
            ) {
                SessionDetail(manifest: replay, player: player)
            }
        } else if running {
            ComparePane(
                label: (selectedPresetName ?? "PRESET").uppercased(),
                labelColor: Color.accentColor,
                subtitle: "running\u{2026}"
            ) {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 20)
            }
        } else if let err = runError {
            ComparePane(
                label: (selectedPresetName ?? "PRESET").uppercased(),
                labelColor: Color.accentColor,
                subtitle: "error"
            ) {
                Text(err).font(.callout).foregroundStyle(.red)
            }
        } else if let r = result, let errString = r.error {
            // Replay returned but this preset's run failed; surface its error.
            ComparePane(
                label: r.preset.uppercased(),
                labelColor: Color.accentColor,
                subtitle: "error"
            ) {
                Text(errString).font(.callout).foregroundStyle(.red)
            }
        } else {
            ComparePane(
                label: (selectedPresetName ?? "PRESET").uppercased(),
                labelColor: Color.accentColor.opacity(0.4),
                subtitle: "not run yet"
            ) {
                Text("Pick a preset and click Run.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func paneSubtitle(for m: SessionManifest) -> String {
        let preset = m.preset.isEmpty ? "—" : m.preset
        return "\(preset) · \(String(format: "%.1fs", m.durationSec))"
    }

    private func relativeTime(_ id: String) -> String {
        guard let d = RelativeTime.parse(id) else { return id }
        return RelativeTime.string(now: Date(), then: d)
    }

    // MARK: - Actions

    private func refresh() async {
        do {
            async let s = sessions.list()
            async let p = presets.list()
            self.sessionList = try await s
            self.presetList = try await p
            if selectedSourceID == nil { selectedSourceID = sessionList.first?.id }
            if selectedPresetName == nil {
                // Default to the source's own preset if it's known,
                // else "default", else first available.
                let sourcePreset = sourceManifest?.preset ?? ""
                if presetList.contains(where: { $0.name == sourcePreset }) {
                    selectedPresetName = sourcePreset
                } else if presetList.contains(where: { $0.name == "default" }) {
                    selectedPresetName = "default"
                } else {
                    selectedPresetName = presetList.first?.name
                }
            }
        } catch {
            self.loadError = "Failed to load: \(error)"
        }
    }

    private func runReplay() async {
        guard let id = selectedSourceID, let preset = selectedPresetName else { return }
        running = true
        runError = nil
        result = nil
        replayManifest = nil
        defer { running = false }
        do {
            let got = try await replay.run(sourceID: id, presets: [preset])
            await MainActor.run {
                self.result = got.first
                self.replayManifest = CompareSourceLoader.loadReplayManifest(
                    sourceID: id,
                    presetName: preset
                )
            }
        } catch {
            await MainActor.run {
                self.runError = "Replay failed: \(error)"
            }
        }
    }
}
