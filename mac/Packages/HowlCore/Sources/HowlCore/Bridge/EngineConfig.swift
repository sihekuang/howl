import Foundation

/// Configuration sent to the Go core via howl_configure as JSON.
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
    /// Cosine-similarity threshold for the post-extract speaker gate.
    /// nil omits the JSON key (Go reads as no gating). Set non-zero to
    /// silence chunks that don't sound enough like the enrolled speaker.
    public var tseThreshold: Float?
    /// TSE backend identifier (e.g. "ecapa"). Empty falls back to
    /// `speaker.Default` on the Go side.
    public var tseBackend: String

    /// Pipeline run timeout in seconds. 0 disables the bound. Global —
    /// not preset-driven. The Go pipeline wraps `Run` with a context
    /// timeout when this is > 0.
    public var pipelineTimeoutSec: Int

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
        onnxLibPath: String = "",
        tseThreshold: Float? = nil,
        tseBackend: String = "",
        pipelineTimeoutSec: Int = 0
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
        self.tseThreshold = tseThreshold
        self.tseBackend = tseBackend
        self.pipelineTimeoutSec = pipelineTimeoutSec
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(whisperModelPath, forKey: .whisperModelPath)
        try c.encode(whisperModelSize, forKey: .whisperModelSize)
        try c.encode(language, forKey: .language)
        try c.encode(disableNoiseSuppression, forKey: .disableNoiseSuppression)
        try c.encode(deepFilterModelPath, forKey: .deepFilterModelPath)
        try c.encode(llmProvider, forKey: .llmProvider)
        try c.encode(llmModel, forKey: .llmModel)
        try c.encode(llmAPIKey, forKey: .llmAPIKey)
        try c.encode(llmBaseURL, forKey: .llmBaseURL)
        try c.encode(developerMode, forKey: .developerMode)
        try c.encode(customDict, forKey: .customDict)
        try c.encode(tseEnabled, forKey: .tseEnabled)
        try c.encode(tseProfileDir, forKey: .tseProfileDir)
        try c.encode(tseModelPath, forKey: .tseModelPath)
        try c.encode(speakerEncoderPath, forKey: .speakerEncoderPath)
        try c.encode(onnxLibPath, forKey: .onnxLibPath)
        // Match the Go-side `omitempty` on tse_threshold: omit when nil
        // so the round trip with `*float32` stays clean.
        try c.encodeIfPresent(tseThreshold, forKey: .tseThreshold)
        try c.encode(tseBackend, forKey: .tseBackend)
        // pipeline_timeout_sec also has Go `omitempty`; omit when zero.
        if pipelineTimeoutSec != 0 {
            try c.encode(pipelineTimeoutSec, forKey: .pipelineTimeoutSec)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.whisperModelPath = try c.decode(String.self, forKey: .whisperModelPath)
        self.whisperModelSize = try c.decode(String.self, forKey: .whisperModelSize)
        self.language = try c.decode(String.self, forKey: .language)
        self.disableNoiseSuppression = try c.decode(Bool.self, forKey: .disableNoiseSuppression)
        self.deepFilterModelPath = try c.decode(String.self, forKey: .deepFilterModelPath)
        self.llmProvider = try c.decode(String.self, forKey: .llmProvider)
        self.llmModel = try c.decode(String.self, forKey: .llmModel)
        self.llmAPIKey = try c.decode(String.self, forKey: .llmAPIKey)
        self.llmBaseURL = try c.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? ""
        self.developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
        self.customDict = try c.decode([String].self, forKey: .customDict)
        self.tseEnabled = try c.decodeIfPresent(Bool.self, forKey: .tseEnabled) ?? false
        self.tseProfileDir = try c.decodeIfPresent(String.self, forKey: .tseProfileDir) ?? ""
        self.tseModelPath = try c.decodeIfPresent(String.self, forKey: .tseModelPath) ?? ""
        self.speakerEncoderPath = try c.decodeIfPresent(String.self, forKey: .speakerEncoderPath) ?? ""
        self.onnxLibPath = try c.decodeIfPresent(String.self, forKey: .onnxLibPath) ?? ""
        self.tseThreshold = try c.decodeIfPresent(Float.self, forKey: .tseThreshold)
        self.tseBackend = try c.decodeIfPresent(String.self, forKey: .tseBackend) ?? ""
        self.pipelineTimeoutSec = try c.decodeIfPresent(Int.self, forKey: .pipelineTimeoutSec) ?? 0
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
        case tseThreshold = "tse_threshold"
        case tseBackend = "tse_backend"
        case pipelineTimeoutSec = "pipeline_timeout_sec"
    }
}

/// On-disk paths the engine needs at configure time. Resolved by the
/// app target (FileManager checks, ModelPaths lookups) and handed to
/// the `EngineConfig` factory below — keeping the factory itself pure
/// so it's reachable from the package's test target.
public struct EnginePaths: Sendable, Equatable {
    public var whisperModelPath: String
    /// Whisper model size after the "is the configured size on disk?
    /// fall back to anything else that is" sweep. May differ from
    /// `UserSettings.whisperModelSize` when the configured size isn't
    /// downloaded.
    public var resolvedWhisperSize: String
    public var deepFilterModelPath: String
    public var voiceProfileDir: String
    public var tseModelPath: String
    public var speakerEncoderPath: String
    public var onnxLibPath: String
    /// True when both TSE models AND the enrollment profile are on disk.
    /// When false the factory forces `tseEnabled = false` regardless of
    /// the user's preference, so the engine doesn't log "TSE missing"
    /// every configure.
    public var tseAssetsPresent: Bool

    public init(
        whisperModelPath: String,
        resolvedWhisperSize: String,
        deepFilterModelPath: String,
        voiceProfileDir: String,
        tseModelPath: String,
        speakerEncoderPath: String,
        onnxLibPath: String,
        tseAssetsPresent: Bool
    ) {
        self.whisperModelPath = whisperModelPath
        self.resolvedWhisperSize = resolvedWhisperSize
        self.deepFilterModelPath = deepFilterModelPath
        self.voiceProfileDir = voiceProfileDir
        self.tseModelPath = tseModelPath
        self.speakerEncoderPath = speakerEncoderPath
        self.onnxLibPath = onnxLibPath
        self.tseAssetsPresent = tseAssetsPresent
    }
}

public extension EngineConfig {
    /// Pure factory: build the config the engine sees from `UserSettings`,
    /// the LLM API key, and the resolved on-disk paths. Lives in the
    /// package so package tests (with a `SpyCoreEngine`) can exercise
    /// the full preset → settings → engine.configure path without
    /// touching FileManager, ModelPaths, or the real C ABI.
    init(settings: UserSettings, apiKey: String, paths: EnginePaths) {
        self.init(
            whisperModelPath: paths.whisperModelPath,
            whisperModelSize: paths.resolvedWhisperSize,
            language: settings.language,
            disableNoiseSuppression: settings.disableNoiseSuppression,
            deepFilterModelPath: paths.deepFilterModelPath,
            llmProvider: settings.llmProvider,
            llmModel: settings.llmModel,
            llmAPIKey: apiKey,
            customDict: settings.customDict,
            llmBaseURL: settings.llmBaseURL,
            // The Mac app no longer surfaces a "developer mode" toggle —
            // every dictation captures per-stage WAVs + transcripts so
            // the Playground sessions sidebar always has data to show.
            developerMode: true,
            tseEnabled: settings.tseEnabled && paths.tseAssetsPresent,
            tseProfileDir: paths.voiceProfileDir,
            tseModelPath: paths.tseModelPath,
            speakerEncoderPath: paths.speakerEncoderPath,
            onnxLibPath: paths.onnxLibPath,
            tseThreshold: settings.tseThreshold,
            tseBackend: settings.tseBackend,
            pipelineTimeoutSec: settings.pipelineTimeoutSec
        )
    }
}
