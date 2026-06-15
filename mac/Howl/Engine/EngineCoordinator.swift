import Foundation
import os
import HowlCore

private let log = Logger(subsystem: "com.howl.app", category: "Engine")

@MainActor
public final class EngineCoordinator {
    let composition: CompositionRoot
    private var pollTask: Task<Void, Never>?
    private var lastWarningTask: Task<Void, Never>?
    private var hotkeyPaused = false
    /// Set when a key-press cancel (`cancelFromKey`) tears down the current
    /// cycle. While true, in-flight pipeline events are ignored in `handle`
    /// so a cancel truly stops everything. Reset at the start of the next
    /// capture (`onPress`).
    private var cancelledThisCycle = false
    /// Drives the brief "Cancelled" overlay confirmation, then hides it.
    private var cancelFeedbackTask: Task<Void, Never>?

    public init(composition: CompositionRoot) {
        self.composition = composition
    }

    /// Best-effort warmup of the active Ollama model. No-op if the
    /// active provider isn't Ollama or no model is selected. The actual
    /// load runs in a detached task so this returns immediately — safe
    /// to call from the hotkey hot path. Errors are silent; the next
    /// real Clean call surfaces any persistent problem with a clearer
    /// message. Called at app start and again on each press, since
    /// Ollama's default keep_alive evicts the model after 5 min idle.
    private func prewarmOllamaIfActive() async {
        let settings = (try? composition.settings.get()) ?? UserSettings()
        guard settings.llmProvider == "ollama", !settings.llmModel.isEmpty else { return }
        let raw = settings.llmBaseURL.isEmpty
            ? OllamaClient.defaultBaseURL
            : (URL(string: settings.llmBaseURL) ?? OllamaClient.defaultBaseURL)
        let model = settings.llmModel
        Task.detached {
            let client = OllamaClient(baseURL: raw)
            try? await client.preloadModel(model)
        }
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

    /// One arbiter fans the keyboard and HID sources into onPress/onRelease
    /// using first-source-owns-stop semantics. Stateful (owner token), so it's
    /// created once and persists across monitor restarts. The engine only ever
    /// sees real start/stop transitions — no re-entrancy guards needed here.
    private lazy var triggerArbiter = TriggerArbiter(
        onStart: { [weak self] in Task { @MainActor in await self?.onPress() } },
        onStop: { [weak self] in Task { @MainActor in await self?.onRelease() } }
    )

    /// (Re)bind the keyboard hotkey through the arbiter. Throws on registration
    /// failure; the caller maps that to the persistent hotkey error.
    private func startKeyboard(_ settings: UserSettings) async throws {
        let kb = triggerArbiter.source(.keyboard)
        try await composition.hotkey.start(settings.hotkey, onPress: kb.onPress, onRelease: kb.onRelease)
    }

    /// (Re)bind the HID trigger through the arbiter, if a binding is configured.
    /// Non-fatal by design: keyboard dictation must keep working regardless of
    /// HID permission/availability, so failures surface a transient warning
    /// only — never the persistent hotkey error.
    private func startHIDTrigger(_ settings: UserSettings) async {
        composition.appState.hidBinding = settings.hidBinding
        composition.hidTrigger.stop()
        guard let binding = settings.hidBinding else { return }
        // Defense-in-depth: never arm a non-button binding (e.g. a stale
        // vendor-page binding from before the learn filter was tightened) —
        // those stream continuously and would jam recording on.
        guard HIDLearnFilter.acceptsUsagePage(binding.usagePage) else {
            log.error("HID trigger: saved binding is not a button (usagePage 0x\(UInt(binding.usagePage), format: .hex, privacy: .public)); ignoring — re-learn a button")
            setTransientWarning("Saved HID trigger is invalid — re-learn a button in Settings → Hotkey.")
            return
        }
        guard composition.hidPermission.isGranted() else {
            log.error("HID trigger: Input Monitoring not granted — skipping (keyboard unaffected)")
            setTransientWarning("HID trigger needs Input Monitoring — grant it in System Settings.")
            return
        }
        do {
            let hid = triggerArbiter.source(.hid)
            try await composition.hidTrigger.start(binding, onPress: hid.onPress, onRelease: hid.onRelease)
            log.notice("HID trigger bound")
        } catch {
            log.error("HID trigger start FAILED: \(String(describing: error), privacy: .public)")
            setTransientWarning("HID trigger failed to start: \(error)")
        }
    }

    /// Phase-1 discovery: start the HID monitor in log mode so every device
    /// element edge is logged (read these from Console under category `hid` to
    /// find the vendor/product/usage to bind). Does not trigger recording.
    public func startHIDDiscovery() async {
        guard composition.hidPermission.isGranted() else {
            _ = composition.hidPermission.request()
            setTransientWarning("Grant Input Monitoring, then start HID discovery again.")
            return
        }
        composition.hidTrigger.stop()
        do {
            try await composition.hidTrigger.start(nil, onPress: {}, onRelease: {})
            log.notice("HID discovery started — press device buttons; watch Console (category: hid)")
        } catch {
            setTransientWarning("HID discovery failed: \(error)")
        }
    }

    /// Phase-2 learn: capture the next learnable HID element, persist it as the
    /// trigger binding, and rebind in bound mode so it's immediately live.
    /// Surfaced from Settings → Hotkey and a menu-bar item.
    public func learnHIDBinding() async {
        guard composition.hidPermission.isGranted() else {
            _ = composition.hidPermission.request()
            setTransientWarning("Grant Input Monitoring, then try learning again.")
            return
        }
        composition.appState.hidLearning = true
        do {
            try await composition.hidTrigger.learnNextBinding { [weak self] binding in
                Task { @MainActor in await self?.persistLearnedHIDBinding(binding) }
            }
            log.notice("HID learn: press the element you want to bind…")
        } catch {
            composition.appState.hidLearning = false
            log.error("HID learn start FAILED: \(String(describing: error), privacy: .public)")
            setTransientWarning("HID learn failed: \(error)")
        }
    }

    private func persistLearnedHIDBinding(_ binding: HIDBinding) async {
        composition.appState.hidLearning = false
        do {
            var settings = try composition.settings.get()
            settings.hidBinding = binding
            try composition.settings.set(settings)
            log.notice("HID binding learned and saved")
            // Release the learn-mode device and rebind in bound mode (one
            // ordered stop+start), so the new trigger is live immediately.
            await startHIDTrigger(settings)
        } catch {
            log.error("HID learn persist FAILED: \(String(describing: error), privacy: .public)")
            setTransientWarning("Saving HID binding failed: \(error)")
        }
    }

    /// Back out of learn mode without capturing. Restores the bound monitor
    /// (or leaves it stopped if no binding is configured).
    public func cancelHIDLearn() async {
        composition.appState.hidLearning = false
        let settings = (try? composition.settings.get()) ?? UserSettings()
        await startHIDTrigger(settings)
    }

    /// Clear the HID trigger binding and stop the monitor.
    public func clearHIDBinding() async {
        do {
            var settings = try composition.settings.get()
            settings.hidBinding = nil
            try composition.settings.set(settings)
            composition.hidTrigger.stop()
            composition.appState.hidBinding = nil
            log.notice("HID binding cleared")
        } catch {
            setTransientWarning("Clearing HID binding failed: \(error)")
        }
    }

    public func start() async {
        log.notice("coordinator.start: binding hotkey then applying config")
        // Bind the hotkey FIRST. applyConfig blocks for several seconds on
        // the Whisper model cold load; if we delayed registration until
        // after, the menu bar would say "Ready" while presses silently
        // dropped during that window. onPress guards on engineLoading
        // and surfaces a clear "still loading" warning until applyConfig
        // returns.
        do {
            let settings = try composition.settings.get()
            try await startKeyboard(settings)
            // Clear any prior registration error from a previous launch
            // or a failed reapply — we're good now.
            composition.appState.hotkeyRegistrationError = nil
            // Peer HID trigger, active alongside the keyboard. Non-fatal.
            await startHIDTrigger(settings)
        } catch {
            // Persistent indicator (not the 5-second toast). Hotkey
            // registration failure is the rare class of error where
            // dictation is silently broken until the user acts; auto-
            // clearing the warning would hide that.
            log.error("coordinator.start: hotkey registration FAILED after retries: \(String(describing: error), privacy: .public)")
            composition.appState.hotkeyRegistrationError = "Open System Settings → Privacy & Security → Accessibility and confirm Howl is granted, then reopen the app."
        }
        // Begin polling now so the loop is live by the time applyConfig
        // builds the pipeline and starts emitting events.
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
        // Apply current settings to the engine. engineLoading is true at
        // launch (AppState default); flip it back to false after the
        // pipeline build returns so the menu bar status and onPress gate
        // unblock.
        composition.appState.engineLoading = true
        await applyConfig()
        composition.appState.engineLoading = false
        // Pre-warm Ollama if it's the active provider so the user's
        // first dictation isn't blocked by a 5–15 s cold model load.
        await prewarmOllamaIfActive()
    }

    public func stop() {
        composition.cancelKeyMonitor.stop()
        composition.hotkey.stop()
        composition.hidTrigger.stop()
        pollTask?.cancel()
        pollTask = nil
    }

    /// Reapply the current settings to a running engine. Called from Settings
    /// after the user changes any field. If the hotkey changed, restart the
    /// hotkey monitor too.
    public func reapplyConfig() async {
        // Mark loading for the duration of the rebuild — same reason as
        // the initial start path: applyConfig blocks on whisper model
        // loading and we don't want presses sneaking through against a
        // half-built pipeline.
        composition.appState.engineLoading = true
        await applyConfig()
        composition.appState.engineLoading = false
        guard !hotkeyPaused else {
            log.info("reapplyConfig: hotkey paused for recording — skipping hotkey restart")
            return
        }
        do {
            let settings = try composition.settings.get()
            composition.hotkey.stop()
            try await startKeyboard(settings)
            composition.appState.hotkeyRegistrationError = nil
            // Rebind HID too — the binding may have changed in Settings.
            await startHIDTrigger(settings)
        } catch {
            log.error("reapplyConfig: hotkey registration FAILED: \(String(describing: error), privacy: .public)")
            composition.appState.hotkeyRegistrationError = "Open System Settings → Privacy & Security → Accessibility and confirm Howl is granted, then reopen the app."
        }
    }

    /// Stop the hotkey monitor while the user records a new shortcut in
    /// Settings. Any in-flight reapplyConfig calls will skip hotkey.start
    /// while paused.
    public func pauseHotkeyForRecording() {
        hotkeyPaused = true
        composition.hotkey.stop()
        // Pause HID too, so holding a bound element while the user records a
        // new keyboard shortcut doesn't fire a recording.
        composition.hidTrigger.stop()
        log.info("hotkey paused for recording")
    }

    /// Allow reapplyConfig to restart the hotkey. Called from save() so the
    /// next reapplyConfig picks up the new shortcut.
    public func clearHotkeyPause() {
        hotkeyPaused = false
    }

    /// Restart the hotkey after a cancelled recording (no save was called).
    public func resumeHotkeyAfterRecording() async {
        hotkeyPaused = false
        do {
            let settings = try composition.settings.get()
            try await startKeyboard(settings)
            composition.appState.hotkeyRegistrationError = nil
            await startHIDTrigger(settings)
            log.notice("hotkey resumed after recording cancel")
        } catch {
            log.error("resumeHotkeyAfterRecording: hotkey registration FAILED: \(String(describing: error), privacy: .public)")
            composition.appState.hotkeyRegistrationError = "Open System Settings → Privacy & Security → Accessibility and confirm Howl is granted, then reopen the app."
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
        cancelledThisCycle = false
        cancelFeedbackTask?.cancel()
        composition.appState.cancelFeedback = false
        composition.cancelKeyMonitor.stop()
        composition.audioCapture.stop()
        try? await composition.engine.stopCapture()
        composition.appState.engineState = .idle
        composition.overlay.hide()
        composition.appState.transientWarning = nil
    }

    /// Immediate, synchronous cancel from a key press. Tears down the UI and
    /// capture right away — no round-trip through the Go `cancelled` event —
    /// then aborts the in-flight pipeline. Subsequent pipeline events for this
    /// cycle are ignored (see `cancelledThisCycle`). Shows a brief "Cancelled"
    /// confirmation in the overlay.
    func cancelFromKey() {
        // Nothing to cancel if we're already idle (e.g. the cycle just
        // finished as the key landed).
        guard composition.appState.engineState != .idle else { return }
        log.info("cancelFromKey: immediate cancel")
        cancelledThisCycle = true
        composition.cancelKeyMonitor.stop()
        composition.audioCapture.stop()
        composition.engine.cancelCapture()
        streamedSoFar = ""
        composition.appState.engineState = .idle
        showCancelFeedback()
    }

    /// Show the "Cancelled" pill briefly, then hide the overlay.
    private func showCancelFeedback() {
        composition.appState.cancelFeedback = true
        composition.overlay.show()
        cancelFeedbackTask?.cancel()
        cancelFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.composition.appState.cancelFeedback = false
            self.composition.overlay.hide()
        }
    }

    /// Tiny audible cue played at the start of each capture cycle so
    /// the user knows the engine is listening without staring at the
    /// menu bar. Held as an instance property so the AVAudioPlayer
    /// has time to actually fire before deinit.
    private let cueSound = CueSound()

    private func onPress() async {
        log.info("onPress: setting state=recording, starting Swift capture and engine")
        // Preflight: the engine pipeline may not be built yet on a cold
        // launch — `coordinator.start` registers the hotkey before
        // applyConfig finishes loading the Whisper model so the user
        // sees the registration; pressing during that window would
        // otherwise call howl_start_capture with a nil pipeline and
        // throw an opaque "rc=1" error. Show a clear loading hint and
        // bail without state churn or the listening cue.
        if composition.appState.engineLoading {
            log.info("onPress: engine still loading — refusing capture")
            setTransientWarning("Howl is still loading — try again in a moment.")
            return
        }
        // Preflight: AVAudioEngine throws an opaque error when no input
        // device is available (mic disconnected, all devices in use by
        // another app, TCC denial). Surface a useful message instead so
        // the user knows what to do.
        if composition.audioCapture.availableInputDevices().isEmpty {
            log.error("onPress: no input devices available — aborting")
            setTransientWarning("No microphone available — connect one and try again.")
            return
        }
        // Kick off Ollama warmup in parallel with capture so a model
        // that got evicted while idle is back in memory by the time
        // Whisper hands the transcript to the LLM.
        await prewarmOllamaIfActive()
        cueSound.playListening()
        // New cycle: clear any prior key-cancel state (and a lingering
        // "Cancelled" pill) so this recording starts clean.
        cancelledThisCycle = false
        cancelFeedbackTask?.cancel()
        composition.appState.cancelFeedback = false
        composition.appState.engineState = .recording
        composition.overlay.show()
        do {
            try await composition.engine.startCapture()
            composition.cancelKeyMonitor.start()
            let settings = (try? composition.settings.get()) ?? UserSettings()
            // Push frames synchronously from the audio thread.
            // pushAudio is nonisolated and the underlying C ABI is
            // internally synchronized, so this is safe and avoids the
            // detached-task race that was dropping ~99% of buffers.
            let engine = composition.engine
            try await composition.audioCapture.start(deviceUID: settings.inputDeviceUID) { samples in
                try? engine.pushAudio(samples)
            }
            log.info("onPress: capture + engine running")
            composition.appState.transientWarning = nil
        } catch {
            log.error("onPress: FAILED: \(String(describing: error), privacy: .public)")
            setTransientWarning("start: \(error)")
            composition.cancelKeyMonitor.stop()
            composition.audioCapture.stop()
            try? await composition.engine.stopCapture()
            composition.appState.engineState = .idle
            composition.overlay.hide()
        }
    }

    private func onRelease() async {
        // A cancel (or other terminal event) may have already ended this
        // cycle — e.g. the user pressed a key to cancel while still holding
        // the trigger, then released it. In that case we're no longer
        // recording, so releasing the trigger must be a no-op. Without this
        // guard, onRelease would re-enter .processing and await a terminal
        // event that never arrives (howl_stop_capture is a no-op after a
        // cancel), leaving the UI stuck showing "Processing…".
        guard composition.appState.engineState == .recording else {
            log.info("onRelease: not recording (cycle already ended) — ignoring release")
            return
        }
        log.info("onRelease: setting state=processing, stopping Swift capture, signaling engine EOI")
        composition.appState.engineState = .processing
        // NOTE: do NOT stop the cancel-key monitor here. It must stay armed
        // through processing so any key still aborts the in-flight pipeline
        // (transcription / LLM / injection). It is disarmed on the terminal
        // events (.result / .cancelled / .error) and in manualReset.
        // Stop the mic FIRST so no more frames push into the engine.
        composition.audioCapture.stop()
        do {
            try await composition.engine.stopCapture()
            log.info("onRelease: engine.stopCapture() returned cleanly; awaiting result event")
        } catch {
            log.error("onRelease: engine.stopCapture() FAILED: \(String(describing: error), privacy: .public)")
            setTransientWarning("stop: \(error)")
            // stopCapture failed → no terminal event will arrive to disarm the
            // monitor, so disarm it here before returning to idle.
            composition.cancelKeyMonitor.stop()
            composition.appState.engineState = .idle
            composition.overlay.hide()
        }
    }

    private func handle(event: EngineEvent) {
        // A key-press cancel (cancelFromKey) tears the cycle down
        // synchronously and aborts the pipeline. Ignore any in-flight
        // pipeline output that still arrives afterward — trailing stream
        // chunks, a late result/warning from the LLM-fallback path, or the
        // eventual cancelled — until the next capture resets the flag.
        if cancelledThisCycle { return }
        switch event {
        case .level(let rms):
            composition.appState.liveRMS = rms
        case .chunk(let text):
            // Streaming LLM delta — type at the cursor and accumulate
            // for the final paste-fallback comparison. We DON'T set
            // engineState here; .result will flip back to idle.
            streamedSoFar += text
            Task { @MainActor in
                try? await composition.streamTyper.injectChunk(text)
            }
        case .result(let text):
            Task { @MainActor in
                composition.cancelKeyMonitor.stop()
                // If streaming already typed everything, skip clipboard
                // paste; otherwise (non-streaming path) fall back to it.
                if streamedSoFar.isEmpty, !text.isEmpty {
                    do {
                        try await composition.injector.inject(text + " ")
                    } catch {
                        setTransientWarning("paste: \(error)")
                    }
                } else if !streamedSoFar.isEmpty {
                    try? await composition.streamTyper.injectChunk(" ")
                }
                streamedSoFar = ""
                composition.appState.engineState = .idle
                composition.overlay.hide()
            }
        case .cancelled:
            // Key-press cancels are handled synchronously by cancelFromKey and
            // gated out at the top of handle(); this arm still runs for
            // engine-originated cancels (e.g. the post-stop pipeline-timeout
            // watchdog), so it is not dead code.
            streamedSoFar = ""
            composition.cancelKeyMonitor.stop()
            // Stop the mic too: a recording-phase cancel fires before
            // onRelease, so the capture is still live here. Without this the
            // mic (and the macOS in-use indicator) would linger until the
            // next cycle. Idempotent when already stopped (processing-phase
            // cancel, where onRelease already stopped it).
            composition.audioCapture.stop()
            composition.appState.engineState = .idle
            composition.overlay.hide()
        case .warning(let msg):
            setTransientWarning(msg)
        case .error(let msg):
            setTransientWarning(msg)
            streamedSoFar = ""
            composition.cancelKeyMonitor.stop()
            composition.appState.engineState = .idle
            composition.overlay.hide()
        }
    }

    /// Concatenation of every `chunk` event received during the
    /// current capture cycle. Reset on result/error. Used to decide
    /// whether the result event should fall back to clipboard paste.
    private var streamedSoFar: String = ""

    private func applyConfig() async {
        let settings = (try? composition.settings.get()) ?? UserSettings()
        await applyConfig(for: settings)
    }

    /// Reconfigure the engine using a caller-supplied UserSettings — does
    /// NOT read from or write to the persistent settings store. Used by
    /// the Playground tab to "test with" a different preset without
    /// changing the user's active preset; revert by calling
    /// `reapplyConfig()` (which re-reads from the store).
    public func applyOverride(_ settings: UserSettings) async {
        await applyConfig(for: settings)
    }

    private func applyConfig(for settings: UserSettings) async {
        // Look up the API key for the active cloud provider. Ollama and
        // any future local-only providers fall through with key="" — the
        // engine ignores LLMAPIKey for providers whose NeedsAPIKey is false.
        let needsKey = (settings.llmProvider == "anthropic" || settings.llmProvider == "openai")
        let key = needsKey ? (try? composition.secrets.getAPIKey(forProvider: settings.llmProvider)) ?? "" : ""
        let paths = resolveEnginePaths(for: settings)
        let cfg = EngineConfig(settings: settings, apiKey: key, paths: paths)
        log.info("applyConfig: whisper=\(paths.resolvedWhisperSize, privacy: .public) llm=\(settings.llmProvider, privacy: .public)/\(settings.llmModel, privacy: .public) keyLen=\(key.count, privacy: .public) lang=\(settings.language, privacy: .public) tse=\(cfg.tseEnabled, privacy: .public) thr=\(String(describing: settings.tseThreshold), privacy: .public) backend=\(settings.tseBackend, privacy: .public) timeout=\(settings.pipelineTimeoutSec, privacy: .public)")
        do {
            try await composition.engine.configure(cfg)
            log.info("applyConfig: engine configured cleanly")
        } catch {
            log.error("applyConfig: configure FAILED: \(String(describing: error), privacy: .public)")
            setTransientWarning("configure: \(error)")
        }
    }

    /// Walk the on-disk locations the engine needs and assemble an
    /// `EnginePaths` for the factory. Falls the Whisper size back to
    /// any other downloaded size if the configured one is missing —
    /// better than failing configure entirely.
    private func resolveEnginePaths(for settings: UserSettings) -> EnginePaths {
        var resolvedSize = settings.whisperModelSize
        var modelPath = ModelPaths.whisperModel(size: resolvedSize).path
        if !FileManager.default.fileExists(atPath: modelPath) {
            for fallback in ["tiny", "base", "small", "medium", "large"]
            where FileManager.default.fileExists(atPath: ModelPaths.whisperModel(size: fallback).path) {
                resolvedSize = fallback
                modelPath = ModelPaths.whisperModel(size: fallback).path
                log.info("applyConfig: configured model '\(settings.whisperModelSize, privacy: .public)' missing; falling back to '\(fallback, privacy: .public)'")
                break
            }
        }
        return EnginePaths(
            whisperModelPath: modelPath,
            resolvedWhisperSize: resolvedSize,
            deepFilterModelPath: "", // engine falls back to passthrough if empty
            voiceProfileDir: ModelPaths.voiceProfileDir.path,
            tseModelPath: ModelPaths.tseModel.path,
            speakerEncoderPath: ModelPaths.speakerEncoder.path,
            onnxLibPath: ModelPaths.onnxLib.path,
            tseAssetsPresent: tseAssetsPresent()
        )
    }

    /// True when both TSE models and the enrollment profile exist on disk.
    /// Guards us from telling the engine `tse_enabled=true` when assets are
    /// missing — the engine would otherwise log a warning and disable TSE,
    /// which is fine but misleading from a UI standpoint.
    private func tseAssetsPresent() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: ModelPaths.tseModel.path) &&
               fm.fileExists(atPath: ModelPaths.speakerEncoder.path) &&
               fm.fileExists(atPath: ModelPaths.voiceProfileDir.appendingPathComponent("speaker.json").path) &&
               fm.fileExists(atPath: ModelPaths.voiceProfileDir.appendingPathComponent("enrollment.emb").path)
    }
}
