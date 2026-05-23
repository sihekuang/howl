// mac/Packages/HowlCore/Tests/HowlCoreTests/WAVWriterTests.swift
import Foundation
import AVFoundation
import Testing
@testable import HowlCore

@Suite("WAVWriter")
struct WAVWriterTests {
    /// Writes a 1-second 16 kHz mono tone and reads it back. Asserts:
    /// - File exists.
    /// - Header advertises 16 kHz, 1 channel, 16-bit.
    /// - Frame count matches.
    /// - Peak amplitude in [-1, 1] is preserved within int16 quantization error.
    @Test func writeRoundTrip_16kHzMono() throws {
        let sr = 16000
        let n = sr // 1 second
        let amp: Float = 0.5
        let samples: [Float] = (0..<n).map { i in
            sin(2.0 * .pi * 440.0 * Float(i) / Float(sr)) * amp
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wavwriter-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try WAVWriter.writeMonoPCM16(samples: samples, sampleRate: sr, to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == 16000)
        #expect(file.processingFormat.channelCount == 1)
        #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
        #expect(file.length == Int64(n))
    }

    /// Samples outside [-1, 1] clip to int16 limits rather than wrapping.
    @Test func writeClipsOutOfRangeSamples() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wavwriter-clip-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try WAVWriter.writeMonoPCM16(samples: [1.5, -1.5, 0.0], sampleRate: 16000, to: url)

        let file = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 3)!
        try file.read(into: buf)
        #expect(buf.frameLength == 3)
        let ch0 = buf.floatChannelData![0]
        #expect(ch0[0] > 0.999)
        #expect(ch0[1] < -0.999)
        #expect(abs(ch0[2]) < 0.001)
    }

    /// Empty input writes a valid zero-length WAV.
    @Test func writeEmptySamples() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wavwriter-empty-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try WAVWriter.writeMonoPCM16(samples: [], sampleRate: 16000, to: url)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 0)
    }
}
