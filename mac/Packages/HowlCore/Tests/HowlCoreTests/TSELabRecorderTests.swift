// mac/Packages/HowlCore/Tests/HowlCoreTests/TSELabRecorderTests.swift
import Foundation
import AVFoundation
import Testing
@testable import HowlCore

/// Fake AudioCapture that records the onFrame callback and lets the
/// test push synthetic 48 kHz mono frames into it.
final class FakeAudioCapture: AudioCapture, @unchecked Sendable {
    var onFrameHandler: (@Sendable ([Float]) -> Void)?
    var startError: Error?
    private(set) var isStarted = false
    private(set) var stopCount = 0

    func start(deviceUID: String?, onFrame: @escaping @Sendable ([Float]) -> Void) async throws {
        if let e = startError { throw e }
        onFrameHandler = onFrame
        isStarted = true
    }
    func stop() {
        stopCount += 1
        isStarted = false
        onFrameHandler = nil
    }
    func isAuthorized() -> Bool { true }
    func openSystemSettings() {}
    func availableInputDevices() -> [AudioInputDevice] { [] }

    /// Test helper — push N samples to the registered callback.
    func feed(_ frames: [Float]) {
        onFrameHandler?(frames)
    }
}

@Suite("TSELabRecorder")
struct TSELabRecorderTests {
    /// Start → feed 1 second of 48 kHz audio → stop → expect a 16 kHz
    /// mono WAV with ~16000 frames written to a temp URL.
    @MainActor
    @Test func recordRoundTrip_writes16kHzWAV() async throws {
        let fake = FakeAudioCapture()
        let rec = TSELabRecorder(audioCapture: fake)
        try await rec.start()
        #expect(rec.isRecording)
        #expect(fake.isStarted)

        // Feed 1 second of 48 kHz audio in 480-sample chunks (10 ms).
        let chunk = [Float](repeating: 0.1, count: 480)
        for _ in 0..<100 { fake.feed(chunk) } // 100 * 10ms = 1s

        let url = try await rec.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!rec.isRecording)
        #expect(fake.stopCount == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == 16000)
        #expect(file.processingFormat.channelCount == 1)
        // 1s at 16 kHz = 16000 frames; allow ±100 for converter framing.
        let len = Int(file.length)
        #expect(len > 15900 && len < 16100, "len=\(len)")
    }

    /// Cancel after start → recorder returns to idle, no file produced.
    @MainActor
    @Test func cancelDiscardsBuffer() async throws {
        let fake = FakeAudioCapture()
        let rec = TSELabRecorder(audioCapture: fake)
        try await rec.start()
        fake.feed([Float](repeating: 0.0, count: 480))
        rec.cancel()
        #expect(!rec.isRecording)
        #expect(fake.stopCount == 1)
    }

    /// AudioCapture start failure propagates out.
    @MainActor
    @Test func startPropagatesAuthorizationFailure() async {
        let fake = FakeAudioCapture()
        fake.startError = AudioCaptureError.permissionDenied
        let rec = TSELabRecorder(audioCapture: fake)
        await #expect(throws: AudioCaptureError.self) {
            try await rec.start()
        }
        #expect(!rec.isRecording)
    }

    /// stop() without a prior start() throws.
    @MainActor
    @Test func stopWithoutStartThrows() async {
        let fake = FakeAudioCapture()
        let rec = TSELabRecorder(audioCapture: fake)
        await #expect(throws: TSELabRecorderError.self) {
            _ = try await rec.stop()
        }
    }
}
