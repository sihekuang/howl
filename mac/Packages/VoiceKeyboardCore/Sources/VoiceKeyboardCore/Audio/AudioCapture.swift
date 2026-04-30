import Foundation
@preconcurrency import AVFoundation
import os

private let log = Logger(subsystem: "com.voicekeyboard.app", category: "AudioCapture")

/// Captures Float32 mono 48 kHz audio from the default system input
/// device and pushes frames to a callback. Lifetime: one start/stop
/// cycle per capture session.
public protocol AudioCapture: Sendable {
    /// Begin capturing. The callback is invoked with each frame of
    /// Float32 mono 48 kHz samples until `stop()` is called. The
    /// callback may be invoked on any thread; the implementation is
    /// expected to run it on the audio thread, so it must NOT block.
    func start(onFrame: @escaping @Sendable ([Float]) -> Void) throws

    /// End capturing. Idempotent; safe to call when not started.
    func stop()
}

public enum AudioCaptureError: Error {
    case engineStartFailed(String)
    case formatUnavailable
}

/// AVAudioEngine-backed capture. Installs a tap on the input node and
/// converts whatever the device delivers to Float32 mono 48 kHz before
/// invoking the callback.
public final class AVAudioInputCapture: AudioCapture, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isRunning = false
    private let lock = NSLock()

    public init() {}

    public func start(onFrame: @escaping @Sendable ([Float]) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        if isRunning { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        log.info("AVAudioInputCapture.start: input format sr=\(inputFormat.sampleRate, privacy: .public) ch=\(inputFormat.channelCount, privacy: .public)")

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatUnavailable
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
            throw AudioCaptureError.formatUnavailable
        }
        targetFormat = target
        converter = conv

        // Install a tap on the input node. Tap buffer size (4096) is a
        // hint; the system may give us fewer samples per call.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.deliver(buffer: buffer, onFrame: onFrame)
        }

        do {
            try engine.start()
            isRunning = true
            log.info("AVAudioInputCapture.start: engine started")
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(String(describing: error))
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        log.info("AVAudioInputCapture.stop: engine stopped")
    }

    private func deliver(buffer: AVAudioPCMBuffer, onFrame: @Sendable ([Float]) -> Void) {
        guard let converter, let targetFormat else { return }

        // Convert to 48 kHz mono Float32. Estimate output capacity
        // generously so AVAudioConverter never truncates a buffer.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return
        }

        // The converter input block is invoked synchronously inside
        // `converter.convert(...)`, so a class-wrapped flag is fine.
        // Marked @unchecked Sendable to satisfy strict concurrency —
        // the runtime never escapes this method.
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if once.done {
                outStatus.pointee = .endOfStream
                return nil
            }
            once.done = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            log.error("AVAudioInputCapture: convert FAILED: \(String(describing: error), privacy: .public)")
            return
        }
        guard let channelData = outBuffer.floatChannelData?[0] else { return }
        let count = Int(outBuffer.frameLength)
        if count == 0 { return }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
        onFrame(samples)
    }
}
