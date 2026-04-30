import Foundation
import os
import VoiceKeyboardCore

private let log = Logger(subsystem: "com.voicekeyboard.app", category: "Engine")

@MainActor
public final class EngineCoordinator {
    let composition: CompositionRoot
    private var pollTask: Task<Void, Never>?
    private var lastWarningTask: Task<Void, Never>?

    public init(composition: CompositionRoot) {
        self.composition = composition
    }

    /// Set a transient warning that auto-clears after 5 seconds, unless a
    /// newer warning replaces it first.
    private func setTransientWarning(_ msg: String) {
        composition.appState.transientWarning = msg
        lastWarningTask?.cancel()
        let captured = msg
        lastWarningTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.composition.appState.transientWarning == captured {
                self?.composition.appState.transientWarning = nil
            }
        }
    }

    public func start() async {
        log.info("coordinator.start: applying config and binding hotkey")
        // Apply current settings to the engine
        await applyConfig()
        // Hook hotkey
        do {
            let settings = try composition.settings.get()
            try composition.hotkey.start(
                settings.hotkey,
                onPress: { [weak self] in
                    Task { @MainActor in await self?.onPress() }
                },
                onRelease: { [weak self] in
                    Task { @MainActor in await self?.onRelease() }
                }
            )
        } catch {
            setTransientWarning("Hotkey: \(error)")
        }
        // Begin polling
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                while let ev = self.composition.engine.pollEvent() {
                    self.handle(event: ev)
                }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    public func stop() {
        composition.hotkey.stop()
        pollTask?.cancel()
        pollTask = nil
    }

    /// Reapply the current settings to a running engine. Called from Settings
    /// after the user changes any field. If the hotkey changed, restart the
    /// hotkey monitor too.
    public func reapplyConfig() async {
        await applyConfig()
        do {
            let settings = try composition.settings.get()
            composition.hotkey.stop()
            try composition.hotkey.start(
                settings.hotkey,
                onPress: { [weak self] in
                    Task { @MainActor in await self?.onPress() }
                },
                onRelease: { [weak self] in
                    Task { @MainActor in await self?.onRelease() }
                }
            )
        } catch {
            setTransientWarning("reapply: \(error)")
        }
    }

    /// Manual entry points for UI surfaces (e.g. Playground tab) that want
    /// to drive recording without going through the global hotkey.
    public func manualPress() async {
        log.info("manualPress invoked")
        await onPress()
    }
    public func manualRelease() async {
        log.info("manualRelease invoked")
        await onRelease()
    }

    /// Force-reset the UI state. Best-effort: also stops mic capture
    /// and nudges the engine to stop any in-flight capture. If the
    /// Go core already finished and just dropped its result event,
    /// this lets the user keep going.
    public func manualReset() async {
        composition.audioCapture.stop()
        try? await composition.engine.stopCapture()
        composition.appState.engineState = .idle
        composition.overlay.hide()
        composition.appState.transientWarning = nil
    }

    private func onPress() async {
        log.info("onPress: setting state=recording, starting Swift capture and engine")
        composition.appState.engineState = .recording
        composition.overlay.show()
        do {
            try await composition.engine.startCapture()
            let settings = (try? composition.settings.get()) ?? UserSettings()
            // Start AVAudioEngine and feed frames into the engine.
            // The closure may run on the audio thread; hop to a Task
            // so the actor-isolated engine.pushAudio call is safe.
            let engine = composition.engine
            try await composition.audioCapture.start(deviceUID: settings.inputDeviceUID) { samples in
                Task.detached {
                    try? await engine.pushAudio(samples)
                }
            }
            log.info("onPress: capture + engine running")
            composition.appState.transientWarning = nil
        } catch {
            log.error("onPress: FAILED: \(String(describing: error), privacy: .public)")
            setTransientWarning("start: \(error)")
            composition.audioCapture.stop()
            try? await composition.engine.stopCapture()
            composition.appState.engineState = .idle
            composition.overlay.hide()
        }
    }

    private func onRelease() async {
        log.info("onRelease: setting state=processing, stopping Swift capture, signaling engine EOI")
        composition.appState.engineState = .processing
        // Stop the mic FIRST so no more frames push into the engine.
        composition.audioCapture.stop()
        do {
            try await composition.engine.stopCapture()
            log.info("onRelease: engine.stopCapture() returned cleanly; awaiting result event")
        } catch {
            log.error("onRelease: engine.stopCapture() FAILED: \(String(describing: error), privacy: .public)")
            setTransientWarning("stop: \(error)")
            composition.appState.engineState = .idle
            composition.overlay.hide()
        }
    }

    private func handle(event: EngineEvent) {
        switch event {
        case .level(let rms):
            composition.appState.liveRMS = rms
        case .result(let text):
            Task { @MainActor in
                if !text.isEmpty {
                    do {
                        try await composition.injector.inject(text)
                    } catch {
                        setTransientWarning("paste: \(error)")
                    }
                }
                composition.appState.engineState = .idle
                composition.overlay.hide()
            }
        case .warning(let msg):
            setTransientWarning(msg)
        case .error(let msg):
            setTransientWarning(msg)
            composition.appState.engineState = .idle
            composition.overlay.hide()
        }
    }

    private func applyConfig() async {
        let settings = (try? composition.settings.get()) ?? UserSettings()
        let key = (try? composition.secrets.getAPIKey()) ?? ""
        var resolvedSize = settings.whisperModelSize
        var modelPath = ModelPaths.whisperModel(size: resolvedSize).path
        // If the configured size isn't downloaded but another size is,
        // fall back to that — better than failing configure entirely.
        if !FileManager.default.fileExists(atPath: modelPath) {
            for fallback in ["tiny", "base", "small", "medium", "large"]
            where FileManager.default.fileExists(atPath: ModelPaths.whisperModel(size: fallback).path) {
                resolvedSize = fallback
                modelPath = ModelPaths.whisperModel(size: fallback).path
                log.info("applyConfig: configured model '\(settings.whisperModelSize, privacy: .public)' missing; falling back to '\(fallback, privacy: .public)'")
                break
            }
        }
        let dfModelPath = "" // engine falls back to passthrough if empty
        let cfg = EngineConfig(
            whisperModelPath: modelPath,
            whisperModelSize: resolvedSize,
            language: settings.language,
            disableNoiseSuppression: settings.disableNoiseSuppression,
            deepFilterModelPath: dfModelPath,
            llmProvider: settings.llmProvider,
            llmModel: settings.llmModel,
            llmAPIKey: key,
            customDict: settings.customDict
        )
        log.info("applyConfig: model=\(modelPath, privacy: .public) keyLen=\(key.count, privacy: .public) lang=\(settings.language, privacy: .public)")
        do {
            try await composition.engine.configure(cfg)
            log.info("applyConfig: engine configured cleanly")
        } catch {
            log.error("applyConfig: configure FAILED: \(String(describing: error), privacy: .public)")
            setTransientWarning("configure: \(error)")
        }
    }
}
