import Foundation

/// Mirror of Go's sessions.Manifest. Decoded from JSON returned by
/// howl_list_sessions / howl_get_session.
public struct SessionManifest: Codable, Equatable, Sendable, Identifiable {
    public let version: Int
    public let id: String
    public let preset: String
    public let durationSec: Double
    public let stages: [Stage]
    public let transcripts: Transcripts
    /// Screen-derived terms that reached whisper's initial prompt for
    /// this dictation. `omitempty` on the Go side (`sessions.Manifest`),
    /// so a legacy manifest without the key decodes to `[]`.
    public let screenKeywords: [String]
    /// The exact `initial_prompt` handed to the ASR for this dictation
    /// (custom dictionary + surviving screen keywords, after
    /// token-budget trimming) and its real token count. Distinct from
    /// `transcripts.prompt`, which is the LLM CLEANUP prompt. Both
    /// `omitempty` on the Go side, so a legacy manifest decodes to
    /// `""` / `0`.
    public let whisperPrompt: String
    public let whisperPromptTokens: Int

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.id = try c.decode(String.self, forKey: .id)
        self.preset = try c.decode(String.self, forKey: .preset)
        self.durationSec = try c.decode(Double.self, forKey: .durationSec)
        self.stages = try c.decode([Stage].self, forKey: .stages)
        self.transcripts = try c.decode(Transcripts.self, forKey: .transcripts)
        self.screenKeywords = try c.decodeIfPresent([String].self, forKey: .screenKeywords) ?? []
        self.whisperPrompt = try c.decodeIfPresent(String.self, forKey: .whisperPrompt) ?? ""
        self.whisperPromptTokens = try c.decodeIfPresent(Int.self, forKey: .whisperPromptTokens) ?? 0
    }

    public struct Stage: Codable, Equatable, Sendable {
        public let name: String
        public let kind: String      // "frame" | "chunk"
        public let wav: String       // path relative to session folder
        public let rateHz: Int
        public let tseSimilarity: Float?

        enum CodingKeys: String, CodingKey {
            case name, kind, wav
            case rateHz = "rate_hz"
            case tseSimilarity = "tse_similarity"
        }
    }

    public struct Transcripts: Codable, Equatable, Sendable {
        public let raw: String
        public let dict: String
        public let cleaned: String
        public let prompt: String

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.raw = try c.decode(String.self, forKey: .raw)
            self.dict = try c.decode(String.self, forKey: .dict)
            self.cleaned = try c.decode(String.self, forKey: .cleaned)
            self.prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        }

        enum CodingKeys: String, CodingKey {
            case raw, dict, cleaned, prompt
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, id, preset, stages, transcripts
        case durationSec = "duration_sec"
        case screenKeywords = "screen_keywords"
        case whisperPrompt = "whisper_prompt"
        case whisperPromptTokens = "whisper_prompt_tokens"
    }
}
