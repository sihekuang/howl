import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("EngineEvent")
struct EngineEventTests {
    @Test func decodeLevel() throws {
        let json = #"{"kind":"level","rms":0.42}"#
        let ev = try JSONDecoder().decode(EngineEvent.self, from: Data(json.utf8))
        guard case .level(let rms) = ev else {
            Issue.record("expected .level, got \(ev)")
            return
        }
        #expect(abs(rms - 0.42) < 1e-5)
    }

    @Test func decodeResult() throws {
        let json = #"{"kind":"result","text":"Hello, world."}"#
        let ev = try JSONDecoder().decode(EngineEvent.self, from: Data(json.utf8))
        guard case .result(let text) = ev else {
            Issue.record("expected .result")
            return
        }
        #expect(text == "Hello, world.")
    }

    @Test func decodeWarning() throws {
        let json = #"{"kind":"warning","msg":"llm: rate limit"}"#
        let ev = try JSONDecoder().decode(EngineEvent.self, from: Data(json.utf8))
        guard case .warning(let msg) = ev else {
            Issue.record("expected .warning")
            return
        }
        #expect(msg == "llm: rate limit")
    }

    @Test func decodeError() throws {
        let json = #"{"kind":"error","msg":"capture failed"}"#
        let ev = try JSONDecoder().decode(EngineEvent.self, from: Data(json.utf8))
        guard case .error(let msg) = ev else {
            Issue.record("expected .error")
            return
        }
        #expect(msg == "capture failed")
    }

    @Test func decodeUnknownKind() {
        let json = #"{"kind":"meow"}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(EngineEvent.self, from: Data(json.utf8))
        }
    }
}
