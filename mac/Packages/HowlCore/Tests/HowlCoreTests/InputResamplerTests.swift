import AVFoundation
import Testing
@testable import HowlCore

// AirPods expose their mic at 16 kHz (24 kHz on some models), so they
// are the input that takes the resampling path — built-in mics are
// 48 kHz and skip it. Until 2026-10, the converter's input block
// answered its second pull with `.endOfStream`; AVAudioConverter
// takes that as the end of the whole stream, so the first tap buffer
// of each session converted and every later one came back empty.
// Users saw recordings from AirPods contain only the first ~0.1 s.

private func sineBuffer(sampleRate: Double, frames: Int) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buf.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
        buf.floatChannelData![0][i] = sin(Float(i) * 2 * .pi * 440 / Float(sampleRate)) * 0.5
    }
    return buf
}

@Test(arguments: [16000.0, 24000.0])
func resamplerKeepsConvertingAfterTheFirstBuffer(sampleRate: Double) throws {
    let frames = Int(sampleRate / 10) // 100 ms per tap buffer
    let resampler = try #require(InputResampler(from: sineBuffer(sampleRate: sampleRate, frames: 1).format))

    var produced: [Int] = []
    for _ in 0..<10 {
        let out = try resampler.convert(sineBuffer(sampleRate: sampleRate, frames: frames))
        produced.append(out?.count ?? 0)
    }

    // 1 s of input at any rate is 48 000 output samples, give or take
    // the converter's priming latency on the first buffer.
    let total = produced.reduce(0, +)
    #expect(produced.dropFirst().allSatisfy { $0 > 0 }, "per-buffer output: \(produced)")
    #expect(abs(total - 48000) < 200, "total \(total), per-buffer output: \(produced)")
}
