// mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/ReplayClientTests.swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("ReplayClient")
struct ReplayClientTests {
    @Test func decodes_emptyArray() async throws {
        let spy = SpyCoreEngine()
        spy.stubReplayJSON = "[]"
        let c = LibVKBReplayClient(engine: spy)
        let got = try await c.run(sourceID: "x", presets: ["default"])
        #expect(got.isEmpty)
    }

    @Test func decodes_results() async throws {
        let json = """
        [
          {"preset":"default","cleaned":"Hello.","raw":"hello","dict":"hello","total_ms":1234,
           "replay_dir":"/tmp/x/replay-default"},
          {"preset":"minimal","cleaned":"hi","raw":"hi","dict":"hi","total_ms":900}
        ]
        """
        let spy = SpyCoreEngine()
        spy.stubReplayJSON = json
        let c = LibVKBReplayClient(engine: spy)
        let got = try await c.run(sourceID: "x", presets: ["default", "minimal"])
        #expect(got.count == 2)
        #expect(got[0].preset == "default")
        #expect(got[0].totalMs == 1234)
        #expect(got[1].error == nil)
    }

    @Test func decodes_errorEnvelope_throws() async {
        let spy = SpyCoreEngine()
        spy.stubReplayJSON = #"{"error":"vkb_replay: source not found"}"#
        let c = LibVKBReplayClient(engine: spy)
        await #expect(throws: ReplayClientError.self) {
            _ = try await c.run(sourceID: "x", presets: ["default"])
        }
    }

    @Test func nilFromEngine_throwsUnavailable() async {
        let spy = SpyCoreEngine()
        spy.stubReplayJSON = nil
        let c = LibVKBReplayClient(engine: spy)
        await #expect(throws: ReplayClientError.self) {
            _ = try await c.run(sourceID: "x", presets: ["default"])
        }
    }
}
