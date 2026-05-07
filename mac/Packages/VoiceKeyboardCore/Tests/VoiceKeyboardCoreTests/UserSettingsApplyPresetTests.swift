import Foundation
import Testing
@testable import VoiceKeyboardCore

/// Locks down `UserSettings.applying(_:)` — the Mac-side equivalent of
/// the Go `presets.Resolve(...)` translation. The Go side is the
/// authoritative spec (covered by core/internal/presets/resolve_test.go);
/// these tests assert the Swift translation matches for the fields that
/// are currently wired AND surface the fields that aren't (so a future
/// fix has a clear target).
@Suite("UserSettings.applying(preset:)")
struct UserSettingsApplyPresetTests {

    // MARK: - Bundled-preset fixtures
    //
    // Re-declared here as Swift literals rather than read off disk to
    // keep the test hermetic. If `core/internal/presets/pipeline-presets.json`
    // ever drifts from these, this is the wrong test to fix — update the
    // JSON, then mirror it here.

    private static func paranoid() -> Preset {
        Preset(
            name: "paranoid",
            description: "Default + TSE threshold 0.7.",
            frameStages: [
                .init(name: "denoise",   enabled: true),
                .init(name: "decimate3", enabled: true),
            ],
            chunkStages: [
                .init(name: "tse", enabled: true, backend: "ecapa", threshold: 0.7),
            ],
            transcribe: .init(modelSize: "small"),
            llm: .init(provider: "anthropic"),
            timeoutSec: 10
        )
    }

    private static func minimal() -> Preset {
        Preset(
            name: "minimal",
            description: "No denoise, no TSE.",
            frameStages: [
                .init(name: "denoise",   enabled: false),
                .init(name: "decimate3", enabled: true),
            ],
            chunkStages: [
                .init(name: "tse", enabled: false, backend: "ecapa", threshold: 0.0),
            ],
            transcribe: .init(modelSize: "small"),
            llm: .init(provider: "anthropic"),
            timeoutSec: 5
        )
    }

    private static func aggressive() -> Preset {
        Preset(
            name: "aggressive",
            description: "Denoise + TSE + larger Whisper.",
            frameStages: [
                .init(name: "denoise",   enabled: true),
                .init(name: "decimate3", enabled: true),
            ],
            chunkStages: [
                .init(name: "tse", enabled: true, backend: "ecapa", threshold: 0.0),
            ],
            transcribe: .init(modelSize: "base"),
            llm: .init(provider: "anthropic"),
            timeoutSec: 15
        )
    }

    // MARK: - Wired fields (these MUST match Go's Resolve)

    @Test func applying_paranoid_setsTSEEnabledAndDenoiseOnAndModel() {
        let result = UserSettings().applying(Self.paranoid())
        #expect(result.selectedPresetName == "paranoid")
        #expect(result.tseEnabled == true)
        #expect(result.disableNoiseSuppression == false) // denoise enabled
        #expect(result.whisperModelSize == "small")
        #expect(result.llmProvider == "anthropic")
    }

    @Test func applying_paranoid_stampsThresholdAndBackend() {
        let result = UserSettings().applying(Self.paranoid())
        #expect(result.tseThreshold == 0.7)
        #expect(result.tseBackend == "ecapa")
    }

    @Test func applying_minimal_disablesDenoiseAndTSE() {
        let result = UserSettings().applying(Self.minimal())
        #expect(result.selectedPresetName == "minimal")
        #expect(result.tseEnabled == false)
        #expect(result.disableNoiseSuppression == true) // denoise disabled
        #expect(result.whisperModelSize == "small")
    }

    @Test func applying_aggressive_picksLargerModel() {
        let result = UserSettings().applying(Self.aggressive())
        #expect(result.whisperModelSize == "base")
        #expect(result.tseEnabled == true)
    }

    @Test func applying_preservesUnrelatedFields() {
        var base = UserSettings()
        base.language = "fr"
        base.llmModel = "claude-sonnet-4-6"
        base.customDict = ["MCP", "WebRTC"]
        base.hotkey = .defaultPTT
        base.developerMode = true

        let result = base.applying(Self.paranoid())
        #expect(result.language == "fr")
        #expect(result.llmModel == "claude-sonnet-4-6")
        #expect(result.customDict == ["MCP", "WebRTC"])
        #expect(result.developerMode == true)
    }

    @Test func applying_isPure_doesNotMutateReceiver() {
        let base = UserSettings()
        _ = base.applying(Self.paranoid())
        #expect(base.selectedPresetName == nil)
        #expect(base.tseEnabled == false)
    }

    // MARK: - Preset-driven engine fields

    @Test func applying_minimal_resetsThresholdToZero() {
        // Switching from paranoid (0.7) to minimal (0.0) must re-stamp
        // threshold so the new preset's value wins. A non-resetting
        // implementation would leave 0.7 in place and silently keep
        // gating after the user picked minimal.
        let after = UserSettings().applying(Self.paranoid()).applying(Self.minimal())
        #expect(after.tseThreshold == 0.0)
    }

    @Test func applying_stampsBackendFromTSEStage() {
        let result = UserSettings().applying(Self.paranoid())
        #expect(result.tseBackend == "ecapa")
    }

    // MARK: - Global timeout: NOT preset-driven
    //
    // Pipeline timeout is a global engine-tuning setting. `applying(_:)`
    // must not touch it, even if the preset declares `timeoutSec`.

    @Test func applying_doesNotChangeGlobalTimeout() {
        var base = UserSettings()
        base.pipelineTimeoutSec = 42 // user's chosen global timeout
        let result = base.applying(Self.paranoid()) // declares timeoutSec: 10
        #expect(result.pipelineTimeoutSec == 42)
    }

    @Test func applying_chainOfPresets_keepsGlobalTimeoutStable() {
        var base = UserSettings()
        base.pipelineTimeoutSec = 7
        let result = base
            .applying(Self.minimal())     // preset says 5
            .applying(Self.paranoid())    // preset says 10
            .applying(Self.aggressive())  // preset says 15
        #expect(result.pipelineTimeoutSec == 7)
    }

    // MARK: - Sanity: stage names the engine doesn't know are silently ignored
    //
    // Documents that the StageGraph UI lets you edit any stage name,
    // but `applying(_:)` (and the Go-side Resolve) only translate
    // "denoise" / "decimate3" / "tse". Custom stages added in the
    // Editor are saved to the preset and rendered, but the running
    // pipeline ignores them.

    @Test func applying_ignoresUnknownFrameStage() {
        let preset = Preset(
            name: "experimental",
            description: "",
            frameStages: [
                .init(name: "agc",       enabled: true), // unknown — ignored
                .init(name: "denoise",   enabled: true),
                .init(name: "decimate3", enabled: true),
            ],
            chunkStages: [
                .init(name: "tse", enabled: true, backend: "ecapa", threshold: 0.0),
            ],
            transcribe: .init(modelSize: "small"),
            llm: .init(provider: "anthropic"),
            timeoutSec: 10
        )
        // Should not crash, should not set any unrelated fields.
        let result = UserSettings().applying(preset)
        #expect(result.disableNoiseSuppression == false)
        #expect(result.tseEnabled == true)
    }

    @Test func applying_ignoresUnknownChunkStage() {
        let preset = Preset(
            name: "experimental",
            description: "",
            frameStages: [
                .init(name: "denoise",   enabled: true),
                .init(name: "decimate3", enabled: true),
            ],
            chunkStages: [
                .init(name: "tse",         enabled: false), // wired
                .init(name: "mix-extract", enabled: true),  // unknown — ignored
            ],
            transcribe: .init(modelSize: "small"),
            llm: .init(provider: "anthropic"),
            timeoutSec: 10
        )
        let result = UserSettings().applying(preset)
        #expect(result.tseEnabled == false)
    }

    // MARK: - LLM model stamping (per-preset override)

    @Test func applying_preset_with_llmModel_stampsModel() {
        let preset = Preset(
            name: "test",
            description: "",
            frameStages: [.init(name: "denoise", enabled: true), .init(name: "decimate3", enabled: true)],
            chunkStages: [.init(name: "tse", enabled: true, backend: "ecapa", threshold: 0.0)],
            transcribe: .init(modelSize: "small"),
            llm: .init(provider: "anthropic", model: "claude-haiku-4-5"),
            timeoutSec: 10
        )
        var base = UserSettings()
        base.llmModel = "claude-sonnet-4-6"  // user's previous global default
        let result = base.applying(preset)
        #expect(result.llmModel == "claude-haiku-4-5")
    }

    @Test func applying_preset_without_llmModel_preservesGlobalModel() {
        let preset = Preset(
            name: "test",
            description: "",
            frameStages: [.init(name: "denoise", enabled: true), .init(name: "decimate3", enabled: true)],
            chunkStages: [.init(name: "tse", enabled: true, backend: "ecapa", threshold: 0.0)],
            transcribe: .init(modelSize: "small"),
            llm: .init(provider: "anthropic", model: nil),  // explicit nil
            timeoutSec: 10
        )
        var base = UserSettings()
        base.llmModel = "claude-sonnet-4-6"
        let result = base.applying(preset)
        #expect(result.llmModel == "claude-sonnet-4-6")  // preserved
    }
}
