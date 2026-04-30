import SwiftUI
import AppKit
import VoiceKeyboardCore

struct MenuBarMenu: View {
    let appState: AppState
    let hotkey: String
    let quit: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading) {
            statusRow
            if let warning = appState.transientWarning {
                Divider()
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            Divider()
            Button("Settings…") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: [.command])
            Divider()
            Button("Quit VoiceKeyboard") { quit() }
                .keyboardShortcut("q", modifiers: [.command])
        }
        .padding(8)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch appState.setupGate {
        case .ready:
            switch appState.engineState {
            case .idle:
                Label("Ready — hold \(hotkey) to dictate", systemImage: "mic")
            case .recording:
                Label("Listening…", systemImage: "waveform.circle.fill")
                    .foregroundStyle(.red)
            case .processing:
                Label("Processing…", systemImage: "ellipsis.circle.fill")
                    .foregroundStyle(.orange)
            }
        case .needsAccessibility:
            Label("Grant Accessibility permission", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .needsModel:
            Label("Download a Whisper model", systemImage: "arrow.down.circle")
                .foregroundStyle(.orange)
        case .needsAPIKey:
            Label("Set Anthropic API key", systemImage: "key")
                .foregroundStyle(.orange)
        }
    }
}
