import SwiftUI
import HowlCore

struct MenuBarIcon: View {
    let appState: AppState

    var body: some View {
        // Idle/ready uses our custom husky template asset; the active
        // states keep SF Symbols so the user still gets a clear visual
        // cue when recording / processing / blocked on setup.
        switch (appState.setupGate, appState.engineState) {
        case (.ready, .idle):
            // Explicit frame — without it, Image("MenuBarIcon") inside
            // a MenuBarExtra label collapses to 0×0 and the husky never
            // shows up. macOS menu bar items render around 18 points.
            Image("MenuBarIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
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
