import Foundation
import Testing
@testable import VoiceKeyboardCore

/// Spy SessionsClient that returns a fixed manifest list so the probe
/// can be tested without disk I/O.
final class SpySessionsClient: SessionsClient, @unchecked Sendable {
    var stubList: [SessionManifest] = []
    func list() async throws -> [SessionManifest] { stubList }
    func get(_ id: String) async throws -> SessionManifest {
        guard let m = stubList.first(where: { $0.id == id }) else {
            throw NSError(domain: "spy", code: 1)
        }
        return m
    }
    func delete(_ id: String) async throws { stubList.removeAll { $0.id == id } }
    func clear() async throws { stubList.removeAll() }
}

@Suite("RecentSimilarityProbe")
struct RecentSimilarityProbeTests {
    /// Build a SessionManifest via JSON decode (avoids needing public
    /// memberwise inits on the manifest types — which the production
    /// path doesn't need either, since it only ever decodes from libvkb).
    private func session(id: String, tseSim: Float?) throws -> SessionManifest {
        let simField: String
        if let sim = tseSim {
            simField = ", \"tse_similarity\": \(sim)"
        } else {
            simField = ""
        }
        let json = """
        {
          "version": 1, "id": "\(id)", "preset": "default", "duration_sec": 1.0,
          "stages": [
            {"name": "tse", "kind": "chunk", "wav": "tse.wav", "rate_hz": 16000\(simField)}
          ],
          "transcripts": {"raw": "raw.txt", "dict": "dict.txt", "cleaned": "cleaned.txt"}
        }
        """
        return try JSONDecoder().decode(SessionManifest.self, from: Data(json.utf8))
    }

    private func sessionWithoutTSE(id: String) throws -> SessionManifest {
        let json = """
        {
          "version": 1, "id": "\(id)", "preset": "minimal", "duration_sec": 1.0,
          "stages": [],
          "transcripts": {"raw": "raw.txt", "dict": "dict.txt", "cleaned": "cleaned.txt"}
        }
        """
        return try JSONDecoder().decode(SessionManifest.self, from: Data(json.utf8))
    }

    @Test func returnsEmptyWhenNoSessions() async throws {
        let spy = SpySessionsClient()
        let probe = RecentSimilarityProbe(sessions: spy)
        let got = try await probe.recent(limit: 5)
        #expect(got.isEmpty)
    }

    @Test func returnsLastNSimilaritiesNewestFirst() async throws {
        let spy = SpySessionsClient()
        spy.stubList = [
            try session(id: "2026-05-03T03Z", tseSim: 0.7),
            try session(id: "2026-05-03T02Z", tseSim: 0.5),
            try session(id: "2026-05-03T01Z", tseSim: 0.9),
        ]
        let probe = RecentSimilarityProbe(sessions: spy)
        let got = try await probe.recent(limit: 5)
        #expect(got == [0.7, 0.5, 0.9])
    }

    @Test func skipsSessionsWithoutTSEStage() async throws {
        let spy = SpySessionsClient()
        spy.stubList = [
            try sessionWithoutTSE(id: "x"),
            try session(id: "y", tseSim: 0.8),
        ]
        let probe = RecentSimilarityProbe(sessions: spy)
        let got = try await probe.recent(limit: 5)
        #expect(got == [0.8])
    }

    @Test func capsAtLimit() async throws {
        let spy = SpySessionsClient()
        spy.stubList = try (0..<10).map { try session(id: "\($0)", tseSim: Float($0) / 10) }
        let probe = RecentSimilarityProbe(sessions: spy)
        let got = try await probe.recent(limit: 3)
        #expect(got.count == 3)
    }
}
