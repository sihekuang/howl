import Foundation
import Testing
@testable import HowlCore

@Suite("SessionsClient", .serialized)
struct SessionsClientTests {
    @Test func list_decodesEmptyArray() async throws {
        let engine = SpyCoreEngine()
        engine.stubSessionsListJSON = "[]"
        let c = LibVKBSessionsClient(engine: engine)
        let got = try await c.list()
        #expect(got.isEmpty)
    }

    @Test func list_decodesManifests() async throws {
        let json = """
        [
          {"version":1,"id":"2026-05-02T14:32:11Z","preset":"default","duration_sec":3.2,
           "stages":[{"name":"denoise","kind":"frame","wav":"denoise.wav","rate_hz":48000}],
           "transcripts":{"raw":"raw.txt","dict":"dict.txt","cleaned":"cleaned.txt"}}
        ]
        """
        let engine = SpyCoreEngine()
        engine.stubSessionsListJSON = json
        let c = LibVKBSessionsClient(engine: engine)
        let got = try await c.list()
        #expect(got.count == 1)
        #expect(got[0].id == "2026-05-02T14:32:11Z")
        #expect(got[0].stages[0].rateHz == 48000)
    }

    @Test func list_engineUnavailable_throws() async {
        let engine = SpyCoreEngine()
        engine.stubSessionsListJSON = nil
        let c = LibVKBSessionsClient(engine: engine)
        await #expect(throws: SessionsClientError.self) { try await c.list() }
    }

    @Test func get_returnsManifest() async throws {
        let engine = SpyCoreEngine()
        engine.stubSessionGetJSON["abc"] = """
        {"version":1,"id":"abc","preset":"default","duration_sec":1.0,
         "stages":[],"transcripts":{"raw":"raw.txt","dict":"dict.txt","cleaned":"cleaned.txt"}}
        """
        let c = LibVKBSessionsClient(engine: engine)
        let got = try await c.get("abc")
        #expect(got.id == "abc")
    }

    @Test func get_unknownThrows() async {
        let engine = SpyCoreEngine()
        engine.stubSessionGetJSON = [:]
        let c = LibVKBSessionsClient(engine: engine)
        await #expect(throws: SessionsClientError.self) { try await c.get("nope") }
    }

    @Test func delete_nonZeroRC_throws() async {
        let engine = SpyCoreEngine()
        engine.stubSessionDeleteRC = 5
        let c = LibVKBSessionsClient(engine: engine)
        await #expect(throws: SessionsClientError.self) { try await c.delete("../escape") }
    }

    @Test func clear_zeroRC_succeeds() async throws {
        let engine = SpyCoreEngine()
        engine.stubSessionsClearRC = 0
        let c = LibVKBSessionsClient(engine: engine)
        try await c.clear()  // no throw
    }
}
