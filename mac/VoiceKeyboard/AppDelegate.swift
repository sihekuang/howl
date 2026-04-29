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
        } else if !modelOK {
            composition.appState.setupGate = .needsModel
        } else if !keyOK {
            composition.appState.setupGate = .needsAPIKey
        } else {
            composition.appState.setupGate = .ready
            // Engine wiring lands in Task 12 (EngineCoordinator).
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
