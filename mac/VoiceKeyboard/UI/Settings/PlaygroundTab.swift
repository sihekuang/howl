import SwiftUI
import VoiceKeyboardCore

/// A scratch text field where the user can try the full dictation flow
/// without leaving the app, plus (when Developer mode is on) a sidebar
/// of captured sessions and a detail pane for the selected one. The
/// recording controls stay at the top of the right column so dictate →
/// refresh → review is one continuous loop.
struct PlaygroundTab: View {
    let appState: AppState
    let hotkey: VoiceKeyboardCore.KeyboardShortcut
    let coordinator: EngineCoordinator
    let developerMode: Bool
    let sessions: any SessionsClient

    @State private var scratch: String = ""
    @State private var selectedID: String? = nil
    @State private var player = WAVPlayer()
    @State private var sessionList: [SessionManifest] = []

    var body: some View {
        SettingsPane {
            if developerMode {
                HSplitView {
                    SessionList(sessions: sessions, selectedID: $selectedID)
                        .frame(minWidth: 200, idealWidth: 240)
                    rightColumn
                        .frame(minWidth: 320)
                }
            } else {
                playgroundColumn
            }
        }
        .onChange(of: selectedID) { _, _ in
            // Switching sessions invalidates the currently-loaded source.
            player.stop()
            Task { await refreshSelectedManifest() }
        }
        .task {
            if developerMode { await refreshSelectedManifest() }
        }
    }

    @ViewBuilder
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            playgroundColumn
            Divider()
            if let m = selectedManifest {
                SessionDetail(manifest: m, player: player)
            } else {
                Text("Select a session on the left.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var playgroundColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusBanner
            Text("Click into the box below, then hold \(Text(hotkey.displayString).font(.system(.body, design: .monospaced).bold())) and speak. Release to transcribe — the cleaned text appears here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $scratch)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.secondary.opacity(0.3))
                )
                .frame(minHeight: developerMode ? 120 : 200)
            HStack {
                Button {
                    Task { @MainActor in
                        switch appState.engineState {
                        case .idle:
                            await coordinator.manualPress()
                        case .recording:
                            await coordinator.manualRelease()
                        case .processing:
                            break
                        }
                    }
                } label: {
                    Label(recordButtonTitle, systemImage: recordButtonIcon)
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.engineState == .recording ? .red : .accentColor)
                .disabled(appState.engineState == .processing)

                if appState.engineState == .recording {
                    rmsMeter
                }
                if appState.engineState != .idle {
                    Button("Reset") {
                        Task { @MainActor in await coordinator.manualReset() }
                    }
                }
                Spacer()
                Button("Clear") { scratch = "" }
                    .disabled(scratch.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch appState.engineState {
        case .idle:
            Label("Ready — hold \(hotkey.displayString) to dictate", systemImage: "mic")
                .foregroundStyle(.secondary)
        case .recording:
            Label("Listening…", systemImage: "waveform.circle.fill")
                .foregroundStyle(.red)
        case .processing:
            Label("Processing…", systemImage: "ellipsis.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var recordButtonTitle: String {
        switch appState.engineState {
        case .idle: return "Record"
        case .recording: return "Stop"
        case .processing: return "Processing…"
        }
    }

    private var recordButtonIcon: String {
        switch appState.engineState {
        case .idle: return "mic.fill"
        case .recording: return "stop.fill"
        case .processing: return "ellipsis"
        }
    }

    private var rmsMeter: some View {
        let level = CGFloat(min(max(appState.liveRMS * 6, 0), 1))
        return HStack(spacing: 4) {
            ForEach(0..<10) { i in
                let threshold = CGFloat(i) / 10.0
                RoundedRectangle(cornerRadius: 2)
                    .fill(level > threshold ? Color.red : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 14)
            }
        }
    }

    /// Manifest for the currently-selected session. Re-fetched on every
    /// selection change so the detail pane always sees fresh data.
    private var selectedManifest: SessionManifest? {
        guard let id = selectedID else { return nil }
        return sessionList.first(where: { $0.id == id })
    }

    private func refreshSelectedManifest() async {
        do {
            let list = try await sessions.list()
            await MainActor.run { self.sessionList = list }
        } catch {
            // Swallow — SessionList shows the error in its own header.
        }
    }
}
