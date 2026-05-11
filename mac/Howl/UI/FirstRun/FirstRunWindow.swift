import SwiftUI
import HowlCore

struct FirstRunWindow: View {
    let composition: CompositionRoot
    let onComplete: () -> Void

    var body: some View {
        switch composition.appState.setupGate {
        case .needsAccessibility:
            AccessibilityPanel(permissions: composition.permissions) {
                composition.appState.setupGate = .needsModel
            }
        case .needsModel:
            ModelDownloadPanel {
                composition.appState.setupGate = .needsAPIKey
            }
        case .needsAPIKey:
            APIKeyPanel(secrets: composition.secrets) {
                composition.appState.setupGate = .ready
                onComplete()
            }
        case .ready:
            EmptyView()
        }
    }
}
