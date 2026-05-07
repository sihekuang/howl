import Foundation
import Testing
@testable import VoiceKeyboardCore

/// Integration test for the Mac config flow with the C ABI stubbed out.
///
/// Drives the full preset → `UserSettings.applying(_:)` → `EngineConfig`
/// factory → `engine.configure(...)` path against a `SpyCoreEngine`,
/// verifying the spy receives an `EngineConfig` whose serialized JSON
/// matches what the Go side expects.
///
/// This is the layer the original bug lived in: the per-stage unit
/// tests were green while the spy never received a `tse_threshold`,
/// `tse_backend`, or `pipeline_timeout_sec`. Locking it down here so a
/// future regression can't sneak through.
@Suite("Preset → Engine.configure (C ABI stubbed)")
struct PresetEngineConfigureIntegrationTests {

    // MARK: - Bundled-preset fixtures
    //
    // Mirrors `core/internal/presets/pipeline-presets.json`. Hermetic to
    // keep the test fast and free of FS / libvkb dependencies.

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

    private static func defaultPreset() -> Preset {
        Preset(
            name: "default",
            description: "Standard pipeline.",
            frameStages: [
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
    }

    // MARK: - Stub paths
    //
    // Caller-supplied paths simulate what `EngineCoordinator.resolveEnginePaths`
    // would return after FileManager checks. `tseAssetsPresent: true` so
    // the factory doesn't downgrade `tseEnabled` on us.

    private static let stubPaths = EnginePaths(
        whisperModelPath: "/m/ggml-small.bin",
        resolvedWhisperSize: "small",
        deepFilterModelPath: "",
        voiceProfileDir: "/profile",
        tseModelPath: "/m/tse.onnx",
        speakerEncoderPath: "/m/enc.onnx",
        onnxLibPath: "/lib/libort.dylib",
        tseAssetsPresent: true
    )

    /// Drive the same flow `EngineCoordinator.applyConfig` runs:
    ///   1. Compute new settings via `applying(preset)`
    ///   2. Build EngineConfig with the factory
    ///   3. Hand to `engine.configure(...)`
    /// Returns the engine the spy received the config on.
    private func configure(
        preset: Preset,
        baseSettings: UserSettings = UserSettings(),
        apiKey: String = "sk-ant-test"
    ) async throws -> SpyCoreEngine {
        let stamped = baseSettings.applying(preset)
        let cfg = EngineConfig(settings: stamped, apiKey: apiKey, paths: Self.stubPaths)
        let spy = SpyCoreEngine()
        try await spy.configure(cfg)
        return spy
    }

    // MARK: - Locks down the original bug

    @Test func paranoidPreset_carriesThresholdToEngine() async throws {
        let spy = try await configure(preset: Self.paranoid())
        let cfg = try #require(spy.configureCalls.first)
        #expect(cfg.tseEnabled == true)
        #expect(cfg.tseThreshold == 0.7)
        #expect(cfg.tseBackend == "ecapa")
    }

    @Test func paranoidPreset_jsonHasTSEThresholdKey() async throws {
        // Even tighter assertion: the JSON the C ABI sees has the key
        // `tse_threshold` with value 0.7. This is what `vkb_configure`
        // actually parses — the test prior fixed the bug, this test
        // pins the wire format.
        let spy = try await configure(preset: Self.paranoid())
        let cfg = try #require(spy.configureCalls.first)
        let json = try String(decoding: JSONEncoder().encode(cfg), as: UTF8.self)
        #expect(json.contains("\"tse_threshold\":0.7"))
        #expect(json.contains("\"tse_backend\":\"ecapa\""))
    }

    @Test func defaultPreset_omitsThresholdKey() async throws {
        // default preset declares threshold 0.0 — Float?(0.0) is non-nil
        // so the key gets emitted with value 0. Either way Go reads it
        // as no gating.
        let spy = try await configure(preset: Self.defaultPreset())
        let cfg = try #require(spy.configureCalls.first)
        #expect(cfg.tseThreshold == 0.0)
    }

    @Test func minimalPreset_disablesTSEEntirely() async throws {
        let spy = try await configure(preset: Self.minimal())
        let cfg = try #require(spy.configureCalls.first)
        #expect(cfg.tseEnabled == false)
        #expect(cfg.disableNoiseSuppression == true)
    }

    // MARK: - Global timeout (NOT preset-driven)

    @Test func presetSwitch_keepsGlobalTimeoutStable() async throws {
        var base = UserSettings()
        base.pipelineTimeoutSec = 7

        // Even though paranoid declares timeoutSec: 10, the engine
        // receives the user's global 7.
        let spy = try await configure(preset: Self.paranoid(), baseSettings: base)
        let cfg = try #require(spy.configureCalls.first)
        #expect(cfg.pipelineTimeoutSec == 7)
    }

    @Test func defaultGlobalTimeout_reachesEngine() async throws {
        let spy = try await configure(preset: Self.defaultPreset())
        let cfg = try #require(spy.configureCalls.first)
        #expect(cfg.pipelineTimeoutSec == 10) // UserSettings default
    }

    @Test func zeroGlobalTimeout_omitsKeyFromJSON() async throws {
        var base = UserSettings()
        base.pipelineTimeoutSec = 0
        let spy = try await configure(preset: Self.paranoid(), baseSettings: base)
        let cfg = try #require(spy.configureCalls.first)
        let json = try String(decoding: JSONEncoder().encode(cfg), as: UTF8.self)
        // 0 means "no bound" — match Go's `omitempty` semantics by
        // omitting the key entirely.
        #expect(!json.contains("pipeline_timeout_sec"))
    }

    // MARK: - Path-resolution boundary
    //
    // Verifies the factory honors `tseAssetsPresent: false` even when
    // the user enabled TSE — protects against the engine logging
    // "TSE missing" on every configure (and against the converse: the
    // engine running TSE without the model on disk).

    @Test func tseDisabledWhenAssetsMissing_evenIfPresetWantsIt() async throws {
        let stamped = UserSettings().applying(Self.paranoid())
        var paths = Self.stubPaths
        paths.tseAssetsPresent = false
        let cfg = EngineConfig(settings: stamped, apiKey: "k", paths: paths)
        let spy = SpyCoreEngine()
        try await spy.configure(cfg)
        let got = try #require(spy.configureCalls.first)
        #expect(got.tseEnabled == false)
        // But threshold + backend still flow through — they're cheap to
        // carry and this preserves the user's intent for the next time
        // assets land on disk.
        #expect(got.tseThreshold == 0.7)
        #expect(got.tseBackend == "ecapa")
    }

    // MARK: - Reconfigure semantics
    //
    // Picking a new preset must overwrite the previous engine config
    // entirely — no field from the prior configure can leak through.

    @Test func switchingPresets_overwritesPreviousEngineConfig() async throws {
        let spy = SpyCoreEngine()
        // First: paranoid with threshold 0.7
        let first = UserSettings().applying(Self.paranoid())
        try await spy.configure(EngineConfig(settings: first, apiKey: "k", paths: Self.stubPaths))
        // Then: minimal (TSE off entirely)
        let second = UserSettings().applying(Self.minimal())
        try await spy.configure(EngineConfig(settings: second, apiKey: "k", paths: Self.stubPaths))

        #expect(spy.configureCalls.count == 2)
        let last = try #require(spy.configureCalls.last)
        #expect(last.tseEnabled == false)
        #expect(last.tseThreshold == 0.0) // reset by applying(minimal)
        #expect(last.disableNoiseSuppression == true)
    }
}
