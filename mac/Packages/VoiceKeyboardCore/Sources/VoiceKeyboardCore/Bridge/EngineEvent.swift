import Foundation

/// Events polled from the Go core via vkb_poll_event.
public enum EngineEvent: Sendable, Decodable, Equatable {
    case level(rms: Float)
    case chunk(text: String)
    case result(text: String)
    case warning(msg: String)
    case error(msg: String)

    private enum CodingKeys: String, CodingKey {
        case kind, rms, text, msg
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "level":
            self = .level(rms: try c.decode(Float.self, forKey: .rms))
        case "chunk":
            self = .chunk(text: try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "result":
            self = .result(text: try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "warning":
            self = .warning(msg: try c.decodeIfPresent(String.self, forKey: .msg) ?? "")
        case "error":
            self = .error(msg: try c.decodeIfPresent(String.self, forKey: .msg) ?? "")
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath,
                debugDescription: "unknown event kind: \(kind)"
            ))
        }
    }
}
