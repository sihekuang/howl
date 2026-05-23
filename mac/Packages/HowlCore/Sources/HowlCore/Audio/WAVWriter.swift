// mac/Packages/HowlCore/Sources/HowlCore/Audio/WAVWriter.swift
import Foundation
import AVFoundation

/// Writes mono Float32 sample buffers as 16-bit PCM mono WAV files.
/// Used by TSE Lab to materialize an in-memory recording to disk for
/// downstream TSE processing (which expects a 16 kHz mono WAV).
public enum WAVWriter {
    public enum Error: Swift.Error {
        case formatUnsupported
        case writeFailed(underlying: Swift.Error)
    }

    /// Writes `samples` as a 16-bit PCM mono WAV at `sampleRate` Hz.
    /// Samples are clipped to [-1, 1] before quantization.
    /// Overwrites the destination file if it exists.
    public static func writeMonoPCM16(
        samples: [Float],
        sampleRate: Int,
        to url: URL
    ) throws {
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        ) else {
            throw Error.formatUnsupported
        }

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let file = try AVAudioFile(forWriting: url, settings: outFormat.settings)
            if samples.isEmpty { return }

            guard let srcFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: false
            ),
            let buf = AVAudioPCMBuffer(
                pcmFormat: srcFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            ) else {
                throw Error.formatUnsupported
            }
            buf.frameLength = AVAudioFrameCount(samples.count)
            guard let ch = buf.floatChannelData?[0] else { throw Error.formatUnsupported }
            for i in 0..<samples.count {
                let s = samples[i]
                ch[i] = s > 1 ? 1 : (s < -1 ? -1 : s)
            }
            try file.write(from: buf)
        } catch let e as Error {
            throw e
        } catch {
            throw Error.writeFailed(underlying: error)
        }
    }
}
