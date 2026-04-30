import Foundation
import Testing
@testable import VoiceKeyboardCore

/// Spy that records every call. Exercises the protocol without
/// touching the real C ABI.
final class SpyCoreEngine: CoreEngine, @unchecked Sendable {
    var configureCalls: [EngineConfig] = []
    var startCalls = 0
    var pushSampleCount = 0
    var stopCalls = 0
    var nextEvent: EngineEvent?

    func configure(_ config: EngineConfig) async throws {
        configureCalls.append(config)
    }
    func startCapture() async throws { startCalls += 1 }
    func pushAudio(_ samples: [Float]) throws {
        pushSampleCount += samples.count
    }
    func stopCapture() async throws { stopCalls += 1 }
    func cancelCapture() {}
    func pollEvent() -> EngineEvent? { defer { nextEvent = nil }; return nextEvent }
    func lastError() -> String? { nil }
    func shutdown() {}
}

@Suite("CoreEngine protocol")
struct CoreEngineTests {
    @Test func spyHonorsProtocol() async throws {
        let spy = SpyCoreEngine()
        try await spy.configure(EngineConfig(
            whisperModelPath: "/x", whisperModelSize: "tiny",
            language: "en", disableNoiseSuppression: false,
            deepFilterModelPath: "", llmProvider: "anthropic",
            llmModel: "claude-sonnet-4-6", llmAPIKey: "k",
            customDict: []))
        try await spy.startCapture()
        try await spy.stopCapture()
        #expect(spy.configureCalls.count == 1)
        #expect(spy.startCalls == 1)
        #expect(spy.stopCalls == 1)
    }
}
