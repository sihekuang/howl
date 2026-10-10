@preconcurrency import AVFoundation

/// Converts tap buffers from a non-48 kHz input device to Float32 mono
/// 48 kHz. One instance per capture session: `AVAudioConverter` keeps
/// filter state between calls, so buffers must be fed in order.
///
/// Bluetooth headsets are the usual reason this runs — AirPods expose
/// their mic at 16 kHz (24 kHz on some models) — while built-in mics
/// are 48 kHz and never get here.
final class InputResampler: @unchecked Sendable {
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48000,
        channels: 1,
        interleaved: false
    )!

    private let converter: AVAudioConverter

    init?(from inputFormat: AVAudioFormat) {
        guard let conv = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
            return nil
        }
        converter = conv
    }

    /// Converts one tap buffer. Returns nil when the converter produced
    /// nothing for it.
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float]? {
        let n = Int(buffer.frameLength)
        if n == 0 { return nil }
        let ratio = Self.outputFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(n) * ratio + 64)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: outCapacity) else {
            return nil
        }
        // Hand over this buffer, then say "nothing more for now". Must be
        // `.noDataNow`, not `.endOfStream`: end-of-stream ends the
        // converter for good, and every later call yields 0 frames.
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if once.done {
                outStatus.pointee = .noDataNow
                return nil
            }
            once.done = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw error ?? AudioCaptureError.formatUnavailable
        }
        guard let cd = outBuffer.floatChannelData?[0] else { return nil }
        let count = Int(outBuffer.frameLength)
        if count == 0 { return nil }
        return Array(UnsafeBufferPointer(start: cd, count: count))
    }
}
