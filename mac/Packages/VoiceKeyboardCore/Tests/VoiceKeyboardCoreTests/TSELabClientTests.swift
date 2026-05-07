// mac/Packages/VoiceKeyboardCore/Tests/VoiceKeyboardCoreTests/TSELabClientTests.swift
import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("TSELabClient")
struct TSELabClientTests {
    @Test func success_returnsTempURL_andForwardsArgs() async throws {
        let spy = SpyCoreEngine()
        spy.stubTSEExtractRC = 0
        let c = LibVKBTSELabClient(
            engine: spy,
            modelsDir: URL(fileURLWithPath: "/models"),
            voiceDir: URL(fileURLWithPath: "/voice"),
            onnxLibPath: "/usr/local/lib/libonnxruntime.dylib"
        )
        let input = URL(fileURLWithPath: "/tmp/in.wav")
        let out = try await c.extract(input: input)

        #expect(out.path.contains("tse-lab-"))
        #expect(out.pathExtension == "wav")
        #expect(spy.tseExtractCalls.count == 1)
        let call = spy.tseExtractCalls[0]
        #expect(call.input == "/tmp/in.wav")
        #expect(call.modelsDir == "/models")
        #expect(call.voiceDir == "/voice")
        #expect(call.onnxLibPath == "/usr/local/lib/libonnxruntime.dylib")
        #expect(call.output == out.path)
    }

    @Test func nonZeroRC_throwsBackendError_withLastError() async {
        let spy = SpyCoreEngine()
        spy.stubTSEExtractRC = -1
        spy.stubLastError = "input file not found"
        let c = LibVKBTSELabClient(
            engine: spy,
            modelsDir: URL(fileURLWithPath: "/models"),
            voiceDir: URL(fileURLWithPath: "/voice"),
            onnxLibPath: "/lib/libonnx.dylib"
        )
        await #expect(throws: TSELabClientError.self) {
            _ = try await c.extract(input: URL(fileURLWithPath: "/missing.wav"))
        }
    }

    @Test func nonZeroRC_nilLastError_fallsBackToGenericMessage() async throws {
        let spy = SpyCoreEngine()
        spy.stubTSEExtractRC = -1
        spy.stubLastError = nil
        let c = LibVKBTSELabClient(
            engine: spy,
            modelsDir: URL(fileURLWithPath: "/models"),
            voiceDir: URL(fileURLWithPath: "/voice"),
            onnxLibPath: "/lib/libonnx.dylib"
        )
        do {
            _ = try await c.extract(input: URL(fileURLWithPath: "/missing.wav"))
            Issue.record("expected error")
        } catch let TSELabClientError.backend(msg) {
            #expect(msg.contains("rc=-1"))
        }
    }
}
