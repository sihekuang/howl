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
    }
}
