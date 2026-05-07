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

    @Test func testEngineConfig_LLMBaseURL_EncodesUnderSnakeCaseKey() throws {
        let cfg = EngineConfig(
            whisperModelPath: "",
            whisperModelSize: "small",
            language: "en",
            disableNoiseSuppression: false,
            deepFilterModelPath: "",
            llmProvider: "ollama",
            llmModel: "llama3.2",
            llmAPIKey: "",
            customDict: [],
            llmBaseURL: "http://10.0.0.5:11434"
        )
        let data = try JSONEncoder().encode(cfg)
        let json = try #require(String(data: data, encoding: .utf8))
        // JSONEncoder escapes "/" as "\/" — check the key exists and round-trips correctly.
        #expect(json.contains("\"llm_base_url\""),
                "expected llm_base_url key in JSON, got: \(json)")
        let decoded = try JSONDecoder().decode(EngineConfig.self, from: data)
        #expect(decoded.llmBaseURL == "http://10.0.0.5:11434")
    }

    @Test func testEngineConfig_LLMBaseURL_RoundTrip() throws {
        let cfg = EngineConfig(
            whisperModelPath: "/tmp/m.bin",
            whisperModelSize: "small",
            language: "en",
            disableNoiseSuppression: false,
            deepFilterModelPath: "",
            llmProvider: "ollama",
            llmModel: "qwen2.5:14b",
            llmAPIKey: "",
            customDict: [],
            llmBaseURL: ""
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(EngineConfig.self, from: data)
        #expect(decoded.llmBaseURL == "")
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

    @Test func engineConfig_developerMode_jsonKeyIsSnakeCase() throws {
        let cfg = EngineConfig(
            whisperModelPath: "/x", whisperModelSize: "small", language: "en",
            disableNoiseSuppression: false, deepFilterModelPath: "",
            llmProvider: "anthropic", llmModel: "claude", llmAPIKey: "",
            customDict: [],
            developerMode: true
        )
        let data = try JSONEncoder().encode(cfg)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"developer_mode\":true"))
    }

    @Test func engineConfig_developerMode_defaultsFalse() {
        let cfg = EngineConfig(
            whisperModelPath: "/x", whisperModelSize: "small", language: "en",
            disableNoiseSuppression: false, deepFilterModelPath: "",
            llmProvider: "anthropic", llmModel: "claude", llmAPIKey: "",
            customDict: []
        )
        #expect(cfg.developerMode == false)
    }

    // MARK: - TSE threshold + backend + global pipeline timeout
    //
    // These three fields must reach the Go engine as JSON keys whose
    // names match `core/internal/config/config.go`'s json tags exactly.
    // A typo in the Coding key here is invisible until you notice that
    // picking "paranoid" doesn't actually gate.

    @Test func engineConfig_tseThreshold_omitsKeyWhenNil() throws {
        let cfg = EngineConfig(
            whisperModelPath: "/x", whisperModelSize: "small", language: "en",
            disableNoiseSuppression: false, deepFilterModelPath: "",
            llmProvider: "anthropic", llmModel: "claude", llmAPIKey: "",
            customDict: [],
            tseEnabled: true,
            tseThreshold: nil
        )
        let json = String(data: try JSONEncoder().encode(cfg), encoding: .utf8) ?? ""
        // Mirrors Go's `omitempty` on TSEThreshold *float32 so nil
        // round-trips cleanly to no gating, not to 0 explicitly.
        #expect(!json.contains("tse_threshold"))
    }

    @Test func engineConfig_tseThreshold_emitsValueWhenSet() throws {
        let cfg = EngineConfig(
            whisperModelPath: "/x", whisperModelSize: "small", language: "en",
            disableNoiseSuppression: false, deepFilterModelPath: "",
            llmProvider: "anthropic", llmModel: "claude", llmAPIKey: "",
            customDict: [],
            tseEnabled: true,
            tseThreshold: 0.7
        )
        let json = String(data: try JSONEncoder().encode(cfg), encoding: .utf8) ?? ""
        #expect(json.contains("\"tse_threshold\":0.7"))
    }

    @Test func engineConfig_tseBackend_emitsKey() throws {
        let cfg = EngineConfig(
            whisperModelPath: "/x", whisperModelSize: "small", language: "en",
            disableNoiseSuppression: false, deepFilterModelPath: "",
            llmProvider: "anthropic", llmModel: "claude", llmAPIKey: "",
            customDict: [],
            tseBackend: "ecapa"
        )
        let json = String(data: try JSONEncoder().encode(cfg), encoding: .utf8) ?? ""
        #expect(json.contains("\"tse_backend\":\"ecapa\""))
    }

    @Test func engineConfig_pipelineTimeout_emitsValueWhenSet() throws {
        let cfg = EngineConfig(
            whisperModelPath: "/x", whisperModelSize: "small", language: "en",
            disableNoiseSuppression: false, deepFilterModelPath: "",
            llmProvider: "anthropic", llmModel: "claude", llmAPIKey: "",
            customDict: [],
            pipelineTimeoutSec: 12
        )
        let json = String(data: try JSONEncoder().encode(cfg), encoding: .utf8) ?? ""
        #expect(json.contains("\"pipeline_timeout_sec\":12"))
    }

    @Test func engineConfig_pipelineTimeout_omitsKeyWhenZero() throws {
        let cfg = EngineConfig(
            whisperModelPath: "/x", whisperModelSize: "small", language: "en",
            disableNoiseSuppression: false, deepFilterModelPath: "",
            llmProvider: "anthropic", llmModel: "claude", llmAPIKey: "",
            customDict: [],
            pipelineTimeoutSec: 0
        )
        let json = String(data: try JSONEncoder().encode(cfg), encoding: .utf8) ?? ""
        #expect(!json.contains("pipeline_timeout_sec"))
    }

    @Test func engineConfig_newFields_roundTrip() throws {
        let original = EngineConfig(
            whisperModelPath: "/m.bin", whisperModelSize: "small", language: "en",
            disableNoiseSuppression: false, deepFilterModelPath: "",
            llmProvider: "anthropic", llmModel: "claude", llmAPIKey: "k",
            customDict: [],
            tseEnabled: true,
            tseThreshold: 0.7,
            tseBackend: "ecapa",
            pipelineTimeoutSec: 10
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EngineConfig.self, from: data)
        #expect(decoded.tseThreshold == 0.7)
        #expect(decoded.tseBackend == "ecapa")
        #expect(decoded.pipelineTimeoutSec == 10)
    }
}
