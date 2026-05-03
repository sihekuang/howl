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

    public var id: String { name }

    public init(
        name: String,
        description: String,
        frameStages: [StageSpec],
        chunkStages: [StageSpec],
        transcribe: TranscribeSpec,
        llm: LLMSpec
    ) {
        self.name = name
        self.description = description
        self.frameStages = frameStages
        self.chunkStages = chunkStages
        self.transcribe = transcribe
        self.llm = llm
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
        public init(provider: String) { self.provider = provider }
    }

    enum CodingKeys: String, CodingKey {
        case name, description, transcribe, llm
        case frameStages = "frame_stages"
        case chunkStages = "chunk_stages"
    }
}
