import AppKit
import AVFoundation
import SwiftUI
import os
import VoiceKeyboardCore

private let log = Logger(subsystem: "com.voicekeyboard.app", category: "Setup")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let composition = CompositionRoot()
    var openWindowBridge: ((String) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Trigger the macOS mic permission dialog at launch rather than
        // on first Record click. TCC has been observed to silently
        // resolve `requestAccess` to "denied" on later calls if a
        // previous launch dismissed/declined the prompt without an
        // explicit grant — doing this on launch maximizes the chance
        // the user sees the dialog while the bundle identity is fresh.
        // No-op when status is already determined.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        Task { @MainActor in
            await self.evaluateSetup()
            self.openSettingsWindow()
        }
    }

    private func openSettingsWindow() {
        // Use the SwiftUI openWindow bridge when available (registered by
        // VoiceKeyboardApp once the MenuBarExtra label appears at launch).
        // This reliably realizes the Window scene even on first run when
        // no saved window state exists.
        if let bridge = openWindowBridge {
            bridge("settings")
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            log.error("openSettingsWindow: no bridge and window not realized")
            return
        }
        // Apply NSWindow customizations after SwiftUI has had a chance to
        // realize the window from the openWindow call above.
        Task { @MainActor in
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) else { return }
            window.level = .floating
            window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func evaluateSetup() async {
        let permissions = composition.permissions
        let accessOK = permissions.isTrusted()
        let settings = (try? composition.settings.get()) ?? UserSettings()
        let modelPath = ModelPaths.whisperModel(size: settings.whisperModelSize)
        let modelOK = FileManager.default.fileExists(atPath: modelPath.path)
        let storedKey = (try? composition.secrets.getAPIKey()) ?? ""
        let keyOK = !storedKey.isEmpty

        log.info("evaluateSetup: accessOK=\(accessOK, privacy: .public) modelOK=\(modelOK, privacy: .public) modelPath=\(modelPath.path, privacy: .public) keyOK=\(keyOK, privacy: .public) keyLen=\(storedKey.count, privacy: .public)")

        if !accessOK {
            composition.appState.setupGate = .needsAccessibility
        } else if !modelOK {
            composition.appState.setupGate = .needsModel
        } else if !keyOK {
            composition.appState.setupGate = .needsAPIKey
        } else {
            composition.appState.setupGate = .ready
        }

        // Always start the coordinator. coordinator.start ->
        // applyConfig will surface a transient warning if the engine
        // can't configure (e.g. missing API key, missing model file).
        // Better to attempt and fail loud than to silently never
        // configure — which leaves Record clicks throwing
        // `notInitialized` with no UI hint.
        log.info("evaluateSetup: calling coordinator.start()")
        await composition.coordinator.start()
        log.info("evaluateSetup: coordinator.start() returned")

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
    /// TSE separation model. Bundled with the .app at build time (see the
    /// "Copy TSE models into Resources" build phase). Falls back to
    /// modelsDir so a developer can drop a custom-trained model into
    /// ~/Library/Application Support/VoiceKeyboard/models/ without rebuilding.
    static var tseModel: URL {
        if let bundled = Bundle.main.url(forResource: "tse_model", withExtension: "onnx"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return modelsDir.appendingPathComponent("tse_model.onnx")
    }
    /// Speaker encoder used by enrollment to produce the reference embedding
    /// (Wespeaker ECAPA-TDNN-512 with Kaldi Fbank front-end; 192-dim, L2-normalised).
    /// See `tseModel` for bundling rationale.
    static var speakerEncoder: URL {
        if let bundled = Bundle.main.url(forResource: "speaker_encoder", withExtension: "onnx"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return modelsDir.appendingPathComponent("speaker_encoder.onnx")
    }
    /// Where enrollment artefacts live (enrollment.wav, enrollment.emb, speaker.json).
    static var voiceProfileDir: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("VoiceKeyboard/voice")
    }
    /// Default location for the ONNX Runtime shared library on Apple Silicon.
    static var onnxLib: URL {
        URL(fileURLWithPath: "/opt/homebrew/lib/libonnxruntime.dylib")
    }
}
