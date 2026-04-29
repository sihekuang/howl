import Foundation
import VoiceKeyboardCore

@MainActor
public final class EngineCoordinator {
    let composition: CompositionRoot
    private var pollTask: Task<Void, Never>?

    public init(composition: CompositionRoot) {
        self.composition = composition
    }

    public func start() async {
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
            composition.appState.transientWarning = "Hotkey: \(error)"
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
            composition.appState.transientWarning = "reapply: \(error)"
        }
    }

    private func onPress() async {
        composition.appState.engineState = .recording
        composition.overlay.show()
        do {
            try await composition.engine.startCapture()
        } catch {
            composition.appState.transientWarning = "start: \(error)"
            composition.appState.engineState = .idle
            composition.overlay.hide()
        }
    }

    private func onRelease() async {
        composition.appState.engineState = .processing
        do {
            try await composition.engine.stopCapture()
        } catch {
            composition.appState.transientWarning = "stop: \(error)"
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
                        composition.appState.transientWarning = "paste: \(error)"
                    }
                }
                composition.appState.engineState = .idle
                composition.overlay.hide()
            }
        case .warning(let msg):
            composition.appState.transientWarning = msg
        case .error(let msg):
            composition.appState.transientWarning = msg
            composition.appState.engineState = .idle
            composition.overlay.hide()
        }
    }

    private func applyConfig() async {
        let settings = (try? composition.settings.get()) ?? UserSettings()
        let key = (try? composition.secrets.getAPIKey()) ?? ""
        let modelPath = ModelPaths.whisperModel(size: settings.whisperModelSize).path
        let dfModelPath = "" // engine falls back to passthrough if empty
        let cfg = EngineConfig(
            whisperModelPath: modelPath,
            whisperModelSize: settings.whisperModelSize,
            language: settings.language,
            disableNoiseSuppression: settings.disableNoiseSuppression,
            deepFilterModelPath: dfModelPath,
            llmProvider: settings.llmProvider,
            llmModel: settings.llmModel,
            llmAPIKey: key,
            customDict: settings.customDict
        )
        do {
            try await composition.engine.configure(cfg)
        } catch {
            composition.appState.transientWarning = "configure: \(error)"
        }
    }
}
