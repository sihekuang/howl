import Testing
import Foundation
@testable import HowlCore

@Suite struct EngineConfigSecondaryLanguageTests {
    private func paths() -> EnginePaths {
        EnginePaths(
            whisperModelPath: "/m.bin", resolvedWhisperSize: "large",
            deepFilterModelPath: "", voiceProfileDir: "",
            tseModelPath: "", speakerEncoderPath: "", onnxLibPath: "",
            tseAssetsPresent: false)
    }

    @Test func encodesSecondaryLanguageKey() throws {
        var s = UserSettings()
        s.secondaryLanguage = "zh"
        let cfg = EngineConfig(settings: s, apiKey: "k", paths: paths())
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(cfg)) as! [String: Any]
        #expect(json["secondary_language"] as? String == "zh")
    }

    @Test func factoryMapsFromSettings() {
        var s = UserSettings()
        s.secondaryLanguage = "ko"
        let cfg = EngineConfig(settings: s, apiKey: "k", paths: paths())
        #expect(cfg.secondaryLanguage == "ko")
    }

    @Test func decodesMissingKeyAsNone() throws {
        let json = #"{"whisper_model_path":"/m","whisper_model_size":"small","language":"en","disable_noise_suppression":false,"deep_filter_model_path":"","llm_provider":"anthropic","llm_model":"x","llm_api_key":"","custom_dict":[]}"#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(EngineConfig.self, from: json)
        #expect(cfg.secondaryLanguage == "none")
    }
}
