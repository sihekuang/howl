// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/RecentSimilarityProbe.swift
import Foundation

/// Reads recent TSE cosine similarity values from session manifests.
/// Used by the Editor's stage detail panel to surface a calibration
/// readout (last N similarities) above/below the current threshold.
public struct RecentSimilarityProbe {
    private let sessions: any SessionsClient

    public init(sessions: any SessionsClient) {
        self.sessions = sessions
    }

    /// Returns up to `limit` similarities, newest first. Sessions
    /// without a TSE stage (or without a tseSimilarity value on the
    /// TSE stage) are skipped. Raises only on backend errors.
    public func recent(limit: Int) async throws -> [Float] {
        let manifests = try await sessions.list()
        var out: [Float] = []
        for m in manifests {
            guard let tse = m.stages.first(where: { $0.name == "tse" }) else { continue }
            guard let sim = tse.tseSimilarity else { continue }
            out.append(sim)
            if out.count >= limit { break }
        }
        return out
    }
}
