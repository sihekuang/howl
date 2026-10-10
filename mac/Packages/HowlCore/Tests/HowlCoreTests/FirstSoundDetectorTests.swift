import Testing
@testable import HowlCore

// The listening cue plays when the mic actually delivers audio, not on
// key press. AirPods measured in Howl 2026-10-09: buffers start ~0.5 s
// after press but stay exact zeros until the headset finishes switching
// into call mode, 2–4 s from an idle start. The recording overlay's
// waveform only moves once real audio arrives; the cue now fires at the
// same moment.

@Test func silentFramesDoNotCountAsSound() {
    let d = FirstSoundDetector()
    #expect(!d.observe([0, 0, 0, 0]))
    #expect(!d.observe([]))
}

@Test func firstFrameWithAnySoundFiresOnce() {
    let d = FirstSoundDetector()
    #expect(!d.observe([0, 0]))
    #expect(d.observe([0, 0.00001, 0]))
    #expect(!d.observe([0.5, -0.5]))
}

@Test func negativeSamplesCountAsSound() {
    let d = FirstSoundDetector()
    #expect(d.observe([0, -0.2]))
}

@Test func resetArmsItForTheNextRecording() {
    let d = FirstSoundDetector()
    #expect(d.observe([0.1]))
    d.reset()
    #expect(!d.observe([0]))
    #expect(d.observe([0.1]))
}
