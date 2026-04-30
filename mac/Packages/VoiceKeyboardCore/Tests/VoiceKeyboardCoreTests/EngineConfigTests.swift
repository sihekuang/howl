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

    @Test func testEngineConfig_TSEFieldsRoundTrip() throws {
        let cfg = EngineConfig(
            whisperModelPath: "/m.bin",
            whisperModelSize: "small",
            language: "en",
            disableNoiseSuppression: false,
            deepFilterModelPath: "",
            llmProvider: "anthropic",
            llmModel: "claude-sonnet-4-6",
            llmAPIKey: "k",
            customDict: [],
            tseEnabled: true,
            tseProfileDir: "/p",
            tseModelPath: "/m/tse.onnx",
            speakerEncoderPath: "/m/enc.onnx",
            onnxLibPath: "/lib/libort.dylib"
        )
        let data = try JSONEncoder().encode(cfg)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"tse_enabled\":true"))
        #expect(json.contains("\"tse_profile_dir\":\"\\/p\""))

        let decoded = try JSONDecoder().decode(EngineConfig.self, from: data)
        #expect(decoded.tseEnabled == true)
        #expect(decoded.tseProfileDir == "/p")
        #expect(decoded.tseModelPath == "/m/tse.onnx")
        #expect(decoded.speakerEncoderPath == "/m/enc.onnx")
        #expect(decoded.onnxLibPath == "/lib/libort.dylib")
    }
}
