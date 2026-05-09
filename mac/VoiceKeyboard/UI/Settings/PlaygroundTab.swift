import SwiftUI
import VoiceKeyboardCore

/// A scratch text field where the user can try the full dictation flow
/// without leaving the app, plus (when Developer mode is on) a sidebar
/// of captured sessions and a detail pane for the selected one.
///
/// Layout: Playground sits as a full-width banner at the top of the
/// tab so it's visually decoupled from any selected session — it's a
/// tab-level tool, not a child of the row you happen to be reviewing.
/// Below the banner, sessions list (left) + detail (right) share an
/// HSplitView.
struct PlaygroundTab: View {
    let appState: AppState
    let hotkey: VoiceKeyboardCore.KeyboardShortcut
    let coordinator: EngineCoordinator
    let developerMode: Bool
    let sessions: any SessionsClient
    let presets: any PresetsClient
    @Binding var settings: UserSettings
    /// Persists settings + reapplies the engine config (parent's save handler).
    let onSave: (UserSettings) -> Void
    /// Called when the user clicks "Configure…" in the preset banner.
    /// Parent flips the Settings page to Pipeline → Editor.
    let navigateToPipeline: () -> Void

    @State private var scratch: String = ""
    @State private var selectedID: String? = nil
    @State private var player = WAVPlayer()
    @State private var sessionList: [SessionManifest] = []

    var body: some View {
        SettingsPane {
            if developerMode {
                VStack(spacing: 0) {
                    playgroundBanner
                    Divider()
                    HSplitView {
                        SessionList(sessions: sessions, selectedID: $selectedID)
                            .frame(minWidth: 200, idealWidth: 240)
                        detailColumn
                            .frame(minWidth: 320)
                    }
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

    /// Right-side detail pane — just the SessionDetail (no playground
    /// here; that lives in the top banner). Padded so the content
    /// doesn't butt against the HSplitView divider.
    @ViewBuilder
    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let m = selectedManifest {
                SessionDetail(manifest: m, player: player)
            } else {
                Text("Select a session on the left.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Full-width recording-controls banner. Sits at the top of the
    /// developer-mode layout so it's visually a tab-level tool — not a
    /// child of whichever session is selected below.
    @ViewBuilder
    private var playgroundBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            presetBanner

            HStack(spacing: 8) {
                Image(systemName: "mic.circle.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("PLAYGROUND").font(.caption2).bold().foregroundStyle(.secondary)
                    statusBanner.font(.caption)
                }
                Spacer()
            }

            scratchEditor
                .frame(minHeight: 160)

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
                Text("Hold \(Text(hotkey.displayString).font(.system(.body, design: .monospaced).bold())) anywhere to dictate")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear") { scratch = "" }
                    .disabled(scratch.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.05))
    }

    /// Single-column fallback for when Developer mode is off. Same as
    /// the prior PlaygroundTab.
    @ViewBuilder
    private var playgroundColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            presetBanner
            statusBanner
            Text("Click into the box below, then hold \(Text(hotkey.displayString).font(.system(.body, design: .monospaced).bold())) and speak. Release to transcribe — the cleaned text appears here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            scratchEditor
                .frame(minHeight: 200)
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

    /// Compact preset banner reused across both layout modes. Picker
    /// writes back to UserSettings via applyPreset; "Configure…" jumps
    /// to Pipeline → Editor — but only in developer mode, since the
    /// Pipeline tab is dev-only. Non-dev users see preset selection
    /// without an edit affordance.
    @ViewBuilder
    private var presetBanner: some View {
        PresetBanner(
            presets: presets,
            selectedPresetName: Binding(
                get: { settings.selectedPresetName },
                set: { settings.selectedPresetName = $0 }
            ),
            apply: { p in applyPreset(p) },
            onConfigure: developerMode ? { navigateToPipeline() } : nil
        )
    }

    /// Translate a Preset's stage specs into UserSettings fields and
    /// persist via the parent's save handler. The translation itself
    /// lives on `UserSettings.applying(_:)` so it's testable in isolation.
    private func applyPreset(_ p: Preset) {
        let s = settings.applying(p)
        settings = s
        onSave(s)
    }

    /// Multiline scratch editor — TextEditor expands vertically with
    /// content, anchored to the minHeight set by the caller.
    @ViewBuilder
    private var scratchEditor: some View {
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
