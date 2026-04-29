import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("EngineConfig")
struct EngineConfigTests {
    @Test func roundTrip() throws {
        let original = EngineConfig(
            whisperModelPath: "/tmp/ggml-small.bin",
            whisperModelSize: "small",
            language: "en",
            disableNoiseSuppression: false,
            deepFilterModelPath: "/tmp/DeepFilterNet3.tar.gz",
            llmProvider: "anthropic",
            llmModel: "claude-sonnet-4-6",
            llmAPIKey: "sk-ant-test",
            customDict: ["MCP", "WebRTC"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EngineConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test func snakeCaseTags() throws {
        let cfg = EngineConfig(
            whisperModelPath: "/x", whisperModelSize: "tiny",
            language: "en", disableNoiseSuppression: false,
            deepFilterModelPath: "", llmProvider: "anthropic",
            llmModel: "claude-sonnet-4-6", llmAPIKey: "k",
            customDict: []
        )
        let data = try JSONEncoder().encode(cfg)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"whisper_model_path\""))
        #expect(json.contains("\"disable_noise_suppression\""))
        #expect(json.contains("\"llm_api_key\""))
        #expect(json.contains("\"custom_dict\""))
    }
}
