import AppKit
import SwiftUI
import VoiceKeyboardCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let composition = CompositionRoot()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await self.evaluateSetup()
        }
    }

    func evaluateSetup() async {
        let permissions = composition.permissions
        let accessOK = permissions.isTrusted()
        let settings = (try? composition.settings.get()) ?? UserSettings()
        let modelPath = ModelPaths.whisperModel(size: settings.whisperModelSize)
        let modelOK = FileManager.default.fileExists(atPath: modelPath.path)
        let keyOK = (try? composition.secrets.getAPIKey()) != nil

        // Update the gate badge for UI surfaces (menu bar, first-run
        // wizard) so the user knows what's still missing.
        if !accessOK {
            composition.appState.setupGate = .needsAccessibility
        } else if !modelOK {
            composition.appState.setupGate = .needsModel
        } else if !keyOK {
            composition.appState.setupGate = .needsAPIKey
        } else {
            composition.appState.setupGate = .ready
        }

        // Always start the coordinator if the engine has what it
        // needs to configure (model + API key). Accessibility is only
        // required for paste injection and the (now Carbon-based)
        // hotkey doesn't need it either, so we shouldn't gate engine
        // initialization on it. Without this, clicking Record in the
        // Playground throws `notInitialized` immediately because the
        // pipeline is never configured.
        if modelOK && keyOK {
            await composition.coordinator.start()
        }

        // First-run wizard for anything still missing.
        if !accessOK || !modelOK || !keyOK {
            openFirstRunWindow()
        }
    }

    private func openFirstRunWindow() {
        // SwiftUI's openWindow action requires an Environment. From AppKit
        // we just bring the window to front by identifier — SwiftUI will
        // realize it on demand.
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "first-run" }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Fall back: post a notification or open a standard panel.
            // For now, log and continue — the user can click the menu bar
            // icon to see the "needs setup" state.
            print("first-run window not yet available")
        }
    }

    /// Called by the first-run wizard's APIKeyPanel onComplete to start
    /// the engine after setup completes mid-session.
    func setupCompletedRetry() {
        Task { @MainActor in
            await self.evaluateSetup()
        }
    }
}

enum ModelPaths {
    static var modelsDir: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("VoiceKeyboard/models")
    }
    static func whisperModel(size: String) -> URL {
        modelsDir.appendingPathComponent("ggml-\(size).en.bin")
    }
}
