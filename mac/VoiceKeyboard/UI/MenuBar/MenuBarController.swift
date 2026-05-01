import SwiftUI
import VoiceKeyboardCore

struct MenuBarIcon: View {
    let appState: AppState

    var body: some View {
        // Idle/ready uses our custom husky template asset; the active
        // states keep SF Symbols so the user still gets a clear visual
        // cue when recording / processing / blocked on setup.
        switch (appState.setupGate, appState.engineState) {
        case (.ready, .idle):
            Image("MenuBarIcon")
                .resizable()
                .scaledToFit()
        case (.ready, .recording):
            Image(systemName: "waveform.circle.fill")
                .symbolEffect(.pulse, options: .repeating, isActive: true)
        case (.ready, .processing):
            Image(systemName: "ellipsis.circle")
        case (.needsAccessibility, _), (.needsModel, _), (.needsAPIKey, _):
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }
}
