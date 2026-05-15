import SwiftUI
import AppKit
import HowlCore

/// Contents of the menu that drops down from the status item.
/// Rendered in standard macOS NSMenu style by MenuBarExtra's `.menu`
/// styling — top-level Buttons become menu items, Dividers become
/// system separators. Avoid VStack / padding / custom backgrounds:
/// they don't translate to menu items and revert to the old custom
/// popup look.
struct MenuBarMenu: View {
    let appState: AppState
    let hotkey: String
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        // Status as a disabled Button — renders as a greyed informational
        // header. Plain Text in `.menu` style would still be tappable; an
        // explicitly-disabled Button is the conventional way to expose a
        // non-interactive label.
        Button(statusText) { }
            .disabled(true)

        if let hotkeyErr = appState.hotkeyRegistrationError {
            // Persistent — stays until registration succeeds or the user
            // resolves the underlying issue (typically Accessibility
            // permission). Shown above the transient warning so it's
            // the first thing the user sees in the menu.
            Button("⚠️ Hotkey not active: \(hotkeyErr)") { }
                .disabled(true)
        }

        if let warning = appState.transientWarning {
            Button(warning) { }
                .disabled(true)
        }

        Divider()

        Button("Settings…") {
            openSettings()
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button("Quit Howl") { quit() }
            .keyboardShortcut("q", modifiers: [.command])
    }

    private var statusText: String {
        switch appState.setupGate {
        case .ready:
            switch appState.engineState {
            case .idle:       return "Ready — hold \(hotkey) to dictate"
            case .recording:  return "Listening…"
            case .processing: return "Processing…"
            }
        case .needsAccessibility: return "Grant Accessibility permission"
        case .needsModel:         return "Download a Whisper model"
        case .needsAPIKey:        return "Set Anthropic API key"
        }
    }
}
