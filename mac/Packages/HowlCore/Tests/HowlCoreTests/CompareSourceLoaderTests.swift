// CompareSourceLoader is in the app target (depends on SessionPaths).
// To test it from the SwiftPM test target, we test the URL-taking
// overload that lives in HowlCore alongside the rest of the
// session-manifest plumbing. The app-target wrapper is a one-liner
// that just builds the URL and forwards.
import Foundation
import Testing
@testable import HowlCore

@Suite("CompareSourceLoader")
struct CompareSourceLoaderTests {
    private func writeManifest(at url: URL, _ json: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: url)
    }

    private let validJSON = """
    {
      "version": 1,
      "id": "2026-05-06T18:00:00Z",
      "preset": "paranoid",
      "duration_sec": 4.2,
      "stages": [
        {"name": "denoise", "kind": "frame", "wav": "denoise.wav", "rate_hz": 48000}
      ],
      "transcripts": {"raw": "raw.txt", "dict": "dict.txt", "cleaned": "cleaned.txt"}
    }
    """

    @Test func loadFrom_validJSON_returnsManifest() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vkb-test-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("session.json")
        try writeManifest(at: url, validJSON)
        defer { try? FileManager.default.removeItem(at: dir) }

        let m = CompareSourceLoader.loadFrom(url: url)
        #expect(m != nil)
        #expect(m?.preset == "paranoid")
        #expect(m?.durationSec == 4.2)
        #expect(m?.stages.count == 1)
    }

    @Test func loadFrom_missingFile_returnsNil() {
        let url = URL(fileURLWithPath: "/no/such/path/session.json")
        #expect(CompareSourceLoader.loadFrom(url: url) == nil)
    }

    @Test func loadFrom_corruptJSON_returnsNil() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vkb-test-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("session.json")
        try writeManifest(at: url, "{not json")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(CompareSourceLoader.loadFrom(url: url) == nil)
    }
}
