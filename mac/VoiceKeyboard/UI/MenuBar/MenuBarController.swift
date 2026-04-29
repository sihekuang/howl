import SwiftUI
import VoiceKeyboardCore

struct MenuBarIcon: View {
    let appState: AppState

    var body: some View {
        Image(systemName: iconName)
            .symbolEffect(.pulse, isActive: appState.engineState == .recording)
    }

    private var iconName: String {
        switch appState.setupGate {
        case .ready:
            switch appState.engineState {
            case .idle:       return "mic"
            case .recording:  return "waveform.circle.fill"
            case .processing: return "ellipsis.circle"
            }
        case .needsAccessibility, .needsModel, .needsAPIKey:
            return "exclamationmark.triangle.fill"
        }
    }
}
