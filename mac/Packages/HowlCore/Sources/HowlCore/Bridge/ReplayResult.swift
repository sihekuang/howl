// mac/Packages/HowlCore/Sources/HowlCore/Bridge/ReplayResult.swift
import Foundation

/// One preset's outcome from a Compare run. Mirrors Go's replay.Result.
public struct ReplayResult: Codable, Equatable, Sendable, Identifiable {
    public let preset: String
    public let cleaned: String
    public let raw: String
    public let dict: String
    public let totalMs: Int64
    public let replayDir: String?
    public let error: String?

    public var id: String { preset }

    public init(
        preset: String, cleaned: String, raw: String, dict: String,
        totalMs: Int64, replayDir: String? = nil, error: String? = nil
    ) {
        self.preset = preset
        self.cleaned = cleaned
        self.raw = raw
        self.dict = dict
        self.totalMs = totalMs
        self.replayDir = replayDir
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case preset, cleaned, raw, dict, error
        case totalMs = "total_ms"
        case replayDir = "replay_dir"
    }
}

/// Top-level error envelope when howl_replay fails before producing
/// per-preset results (no session, bad CSV, etc.). Decoded as a
/// fallback when the JSON isn't an array.
public struct ReplayError: Codable, Sendable {
    public let error: String
}
