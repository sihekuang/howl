// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/Preset.swift
import Foundation

/// Mirrors core/internal/presets.Preset. Decoded from JSON returned by
/// vkb_list_presets / vkb_get_preset.
public struct Preset: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String
    public let frameStages: [StageSpec]
    public let chunkStages: [StageSpec]
    public let transcribe: TranscribeSpec
    public let llm: LLMSpec
    public let timeoutSec: Int?

    public var id: String { name }

    public init(
        name: String,
        description: String,
        frameStages: [StageSpec],
        chunkStages: [StageSpec],
        transcribe: TranscribeSpec,
        llm: LLMSpec,
        timeoutSec: Int? = nil
    ) {
        self.name = name
        self.description = description
        self.frameStages = frameStages
        self.chunkStages = chunkStages
        self.transcribe = transcribe
        self.llm = llm
        self.timeoutSec = timeoutSec
    }

    public struct StageSpec: Codable, Equatable, Sendable {
        public let name: String
        public let enabled: Bool
        public let backend: String?
        public let threshold: Float?

        public init(name: String, enabled: Bool, backend: String? = nil, threshold: Float? = nil) {
            self.name = name
            self.enabled = enabled
            self.backend = backend
            self.threshold = threshold
        }
    }

    public struct TranscribeSpec: Codable, Equatable, Sendable {
        public let modelSize: String
        public init(modelSize: String) { self.modelSize = modelSize }
        enum CodingKeys: String, CodingKey { case modelSize = "model_size" }
    }

    public struct LLMSpec: Codable, Equatable, Sendable {
        public let provider: String
        /// Optional per-preset LLM model override. `nil` means "fall back
        /// to the engine's current LLMModel" (the user's global default
        /// from the LLM Provider tab). Bundled presets always pin a
        /// model. Encoded with omit-when-nil so old preset JSON without
        /// this key round-trips cleanly.
        public let model: String?

        public init(provider: String, model: String? = nil) {
            self.provider = provider
            self.model = model
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(provider, forKey: .provider)
            if let model { try c.encode(model, forKey: .model) }
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.provider = try c.decode(String.self, forKey: .provider)
            self.model = try c.decodeIfPresent(String.self, forKey: .model)
        }

        enum CodingKeys: String, CodingKey { case provider, model }
    }

    enum CodingKeys: String, CodingKey {
        case name, description, transcribe, llm
        case frameStages = "frame_stages"
        case chunkStages = "chunk_stages"
        case timeoutSec = "timeout_sec"
    }
}
