// mac/Packages/HowlCore/Sources/HowlCore/Audio/TSELabRecorder.swift
import Foundation
@preconcurrency import AVFoundation
import Combine
import os

private let log = Logger(subsystem: "com.howl.app", category: "TSELabRecorder")

public enum TSELabRecorderError: Error {
    /// stop()/cancel() called when not recording.
    case notRecording
    case wavWriteFailed(underlying: Error)
    case downsampleFailed
}

/// Captures 48 kHz mono audio via the injected AudioCapture, buffers it
/// in memory, and on stop() downsamples to 16 kHz and writes a temp WAV
/// suitable for TSE input. Used by TSE Lab to record from the mic
/// instead of uploading a WAV.
///
/// Single start/stop cycle per session. Re-call `start` for a new
/// session — the previous buffer is discarded.
@MainActor
public final class TSELabRecorder: ObservableObject {
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var elapsed: TimeInterval = 0

    private let audioCapture: any AudioCapture
    private let captureRate: Double = 48000
    private let targetRate: Double = 16000

    // Mutated only from the main actor: `feed` callbacks dispatch back
    // here before appending.
    private var samples: [Float] = []
    private var startedAt: Date?
    private var timerCancellable: AnyCancellable?

    public init(audioCapture: any AudioCapture) {
        self.audioCapture = audioCapture
    }

    public func start() async throws {
        samples.removeAll(keepingCapacity: true)
        startedAt = Date()
        elapsed = 0

        try await audioCapture.start(deviceUID: nil) { [weak self] frame in
            // onFrame may run off-main; hop back before mutating state.
            // If already on main (e.g. in tests), append synchronously so
            // frames land before the next await in stop().
            if Thread.isMainThread {
                // We're already on the main thread; perform the isolation hop
                // synchronously by accessing the MainActor-isolated property
                // directly via a detached task that is guaranteed to be
                // scheduled before the caller's next suspension.
                // The cleanest way: use MainActor.assumeIsolated when available.
                MainActor.assumeIsolated {
                    self?.samples.append(contentsOf: frame)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.samples.append(contentsOf: frame)
                }
            }
        }

        isRecording = true
        // Drive elapsed at 10 Hz for the UI; coarse is fine.
        timerCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let s = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
    }

    /// Stops capture, downsamples 48 kHz → 16 kHz, writes a temp WAV,
    /// returns its URL.
    public func stop() async throws -> URL {
        guard isRecording else { throw TSELabRecorderError.notRecording }
        audioCapture.stop()
        // Drain any pending main-actor append tasks dispatched from the
        // off-main onFrame path before we snapshot. Without this we'd
        // silently drop a few ms of tail audio.
        await Task.yield()
        timerCancellable?.cancel()
        timerCancellable = nil
        isRecording = false
        startedAt = nil

        let captured = samples
        samples.removeAll(keepingCapacity: false)

        let downsampled = try downsample(captured, from: captureRate, to: targetRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tse-lab-rec-\(UUID().uuidString).wav")
        do {
            try WAVWriter.writeMonoPCM16(samples: downsampled, sampleRate: Int(targetRate), to: url)
        } catch {
            throw TSELabRecorderError.wavWriteFailed(underlying: error)
        }
        log.info("TSELabRecorder.stop: wrote \(downsampled.count, privacy: .public) samples to \(url.path, privacy: .public)")
        return url
    }

    /// Stops capture and discards the buffer without writing a file.
    public func cancel() {
        guard isRecording else { return }
        audioCapture.stop()
        timerCancellable?.cancel()
        timerCancellable = nil
        isRecording = false
        startedAt = nil
        samples.removeAll(keepingCapacity: false)
    }

    // MARK: - Internal

    private func downsample(_ input: [Float], from srcRate: Double, to dstRate: Double) throws -> [Float] {
        if input.isEmpty { return [] }
        guard let srcFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: srcRate, channels: 1, interleaved: false
        ), let dstFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: dstRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: srcFmt, to: dstFmt),
           let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(input.count)) else {
            throw TSELabRecorderError.downsampleFailed
        }
        srcBuf.frameLength = AVAudioFrameCount(input.count)
        let ch = srcBuf.floatChannelData![0]
        for i in 0..<input.count { ch[i] = input[i] }

        let ratio = dstRate / srcRate
        let outCap = AVAudioFrameCount(Double(input.count) * ratio + 64)
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: outCap) else {
            throw TSELabRecorderError.downsampleFailed
        }

        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        var error: NSError?
        let status = converter.convert(to: dstBuf, error: &error) { _, outStatus in
            if once.done {
                outStatus.pointee = .endOfStream
                return nil
            }
            once.done = true
            outStatus.pointee = .haveData
            return srcBuf
        }
        if status == .error {
            log.error("TSELabRecorder.downsample: convert FAILED: \(String(describing: error), privacy: .public)")
            throw TSELabRecorderError.downsampleFailed
        }
        guard let cd = dstBuf.floatChannelData?[0] else { throw TSELabRecorderError.downsampleFailed }
        let n = Int(dstBuf.frameLength)
        return Array(UnsafeBufferPointer(start: cd, count: n))
    }
}
