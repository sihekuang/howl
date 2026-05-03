import Foundation

/// Configuration sent to the Go core via vkb_configure as JSON.
/// JSON field names match the Go struct's tags exactly.
public struct EngineConfig: Codable, Equatable, Sendable {
    public var whisperModelPath: String
    public var whisperModelSize: String
    public var language: String
    public var disableNoiseSuppression: Bool
    public var deepFilterModelPath: String
    public var llmProvider: String
    public var llmModel: String
    public var llmAPIKey: String
    public var llmBaseURL: String   // empty = provider's default endpoint
    public var developerMode: Bool
    public var customDict: [String]

    // TSE (Target Speaker Extraction) fields. Defaults are off/empty so
    // existing call sites and the CLI continue to work unchanged.
    public var tseEnabled: Bool
    public var tseProfileDir: String
    public var tseModelPath: String
    public var speakerEncoderPath: String
    public var onnxLibPath: String

    public init(
        whisperModelPath: String,
        whisperModelSize: String,
        language: String,
        disableNoiseSuppression: Bool,
        deepFilterModelPath: String,
        llmProvider: String,
        llmModel: String,
        llmAPIKey: String,
        customDict: [String],
        llmBaseURL: String = "",
        developerMode: Bool = false,
        tseEnabled: Bool = false,
        tseProfileDir: String = "",
        tseModelPath: String = "",
        speakerEncoderPath: String = "",
        onnxLibPath: String = ""
    ) {
        self.whisperModelPath = whisperModelPath
        self.whisperModelSize = whisperModelSize
        self.language = language
        self.disableNoiseSuppression = disableNoiseSuppression
        self.deepFilterModelPath = deepFilterModelPath
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.llmAPIKey = llmAPIKey
        self.llmBaseURL = llmBaseURL
        self.developerMode = developerMode
        self.customDict = customDict
        self.tseEnabled = tseEnabled
        self.tseProfileDir = tseProfileDir
        self.tseModelPath = tseModelPath
        self.speakerEncoderPath = speakerEncoderPath
        self.onnxLibPath = onnxLibPath
    }

    enum CodingKeys: String, CodingKey {
        case whisperModelPath = "whisper_model_path"
        case whisperModelSize = "whisper_model_size"
        case language
        case disableNoiseSuppression = "disable_noise_suppression"
        case deepFilterModelPath = "deep_filter_model_path"
        case llmProvider = "llm_provider"
        case llmModel = "llm_model"
        case llmAPIKey = "llm_api_key"
        case llmBaseURL = "llm_base_url"
        case developerMode = "developer_mode"
        case customDict = "custom_dict"
        case tseEnabled = "tse_enabled"
        case tseProfileDir = "tse_profile_dir"
        case tseModelPath = "tse_model_path"
        case speakerEncoderPath = "speaker_encoder_path"
        case onnxLibPath = "onnx_lib_path"
    }
}
