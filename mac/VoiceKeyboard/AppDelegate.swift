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

        if !accessOK {
            composition.appState.setupGate = .needsAccessibility
            openFirstRunWindow()
        } else if !modelOK {
            composition.appState.setupGate = .needsModel
            openFirstRunWindow()
        } else if !keyOK {
            composition.appState.setupGate = .needsAPIKey
            openFirstRunWindow()
        } else {
            composition.appState.setupGate = .ready
            await composition.coordinator.start()
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
