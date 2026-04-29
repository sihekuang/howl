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
    public var customDict: [String]

    public init(
        whisperModelPath: String,
        whisperModelSize: String,
        language: String,
        disableNoiseSuppression: Bool,
        deepFilterModelPath: String,
        llmProvider: String,
        llmModel: String,
        llmAPIKey: String,
        customDict: [String]
    ) {
        self.whisperModelPath = whisperModelPath
        self.whisperModelSize = whisperModelSize
        self.language = language
        self.disableNoiseSuppression = disableNoiseSuppression
        self.deepFilterModelPath = deepFilterModelPath
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.llmAPIKey = llmAPIKey
        self.customDict = customDict
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
        case customDict = "custom_dict"
    }
}
