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
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        log.info("applicationDidFinishLaunching: mic auth status=\(micStatus.rawValue, privacy: .public)")
        if micStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                let after = AVCaptureDevice.authorizationStatus(for: .audio)
                log.info("launch requestAccess returned granted=\(granted, privacy: .public) status after=\(after.rawValue, privacy: .public)")
            }
        }
        // Hide the dock icon again when the user closes the settings
        // window. We flip to .regular in showSettingsWindow so the
        // window can become key + appear in Cmd-Tab; reverting here
        // restores the menu-bar-only presence. Selector-based observer
        // (rather than the closure-based API) keeps us on AppDelegate's
        // implicit MainActor isolation, sidestepping Swift 6
        // non-Sendable Notification warnings.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        Task { @MainActor in
            await self.evaluateSetup()
            self.showSettingsWindow()
        }
    }

    @objc private func settingsWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier?.rawValue == "settings" else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Realize the Settings window, bring it to the front, and surface a
    /// dock icon while it's open. Safe to call from any path — launch,
    /// menu-bar Settings click, or first-run completion. The dock icon
    /// is hidden again by the willClose observer in
    /// applicationDidFinishLaunching.
    func showSettingsWindow() {
        // .regular makes the dock icon appear AND lets NSApp.activate
        // actually pull the app to the front; on .accessory apps
        // activate is a no-op, which is why a bare openWindow() from
        // the menu bar didn't reliably surface an existing window.
        NSApp.setActivationPolicy(.regular)

        if let bridge = openWindowBridge {
            bridge("settings")
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            log.error("showSettingsWindow: no bridge and window not realized")
            return
        }
        // Bring the window to the front when invoked, but don't pin it
        // above other apps. (Previously we used `.level = .floating` so
        // it stayed on top forever — annoying when the user switches
        // away to look something up.)
        Task { @MainActor in
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) else { return }
            window.level = .normal
            window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func evaluateSetup() async {
        let permissions = composition.permissions
        let accessOK = permissions.isTrusted()
        let settings = (try? composition.settings.get()) ?? UserSettings()
        let modelPath = ModelPaths.whisperModel(size: settings.whisperModelSize)
        let modelOK = FileManager.default.fileExists(atPath: modelPath.path)
        // Cloud providers (anthropic, openai) need a key to be useful.
        // Local providers (ollama) don't — let those users through.
        let needsKey = (settings.llmProvider == "anthropic" || settings.llmProvider == "openai")
        let storedKey = (try? composition.secrets.getAPIKey(forProvider: settings.llmProvider)) ?? ""
        let keyOK = !needsKey || !storedKey.isEmpty

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
    /// Path to the ONNX Runtime shared library. The Mac app bundles
    /// libonnxruntime + its transitive Homebrew deps into Frameworks
    /// (see "Bundle Homebrew dylibs" build phase), and we use that
    /// versioned dylib so Apple's dynamic loader resolves the
    /// @rpath/... references in our other bundled dylibs through the
    /// same physical file. Falls back to the Homebrew prefix for
    /// developer scenarios where the build phase didn't run (e.g.
    /// running a stale build).
    static var onnxLib: URL {
        if let bundled = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("libonnxruntime.1.25.1.dylib"),
            FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: "/opt/homebrew/lib/libonnxruntime.dylib")
    }
}
