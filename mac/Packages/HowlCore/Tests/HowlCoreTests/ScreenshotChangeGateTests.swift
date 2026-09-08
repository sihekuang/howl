import CoreGraphics
import Foundation
import Testing
@testable import HowlCore

// OCR of a 2560×1080 window costs ~1.4s of multi-core CPU per tick
// (measured 2026-09-08). Most ticks on a window the user is reading
// see the same pixels as the last one, give or take a blinking caret.
// A thumbnail comparison costs a few milliseconds and answers "did
// anything move?" before Vision is asked to read it all again.

private func image(width: Int = 640, height: Int = 400, draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(context)
    return context.makeImage()!
}

/// A page of "text": dark bars on white, like lines in an editor.
private func page(offset: Int = 0) -> CGImage {
    image { ctx in
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        for row in stride(from: 20 + offset, to: 400, by: 24) {
            ctx.fill(CGRect(x: 30, y: row, width: 500, height: 10))
        }
    }
}

/// The same page with a 2×16 caret drawn at one line end.
private func pageWithCaret() -> CGImage {
    image { ctx in
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        for row in stride(from: 20, to: 400, by: 24) {
            ctx.fill(CGRect(x: 30, y: row, width: 500, height: 10))
        }
        ctx.fill(CGRect(x: 532, y: 20, width: 2, height: 16))
    }
}

@Suite("Screenshot change detector")
struct ScreenshotChangeDetectorTests {

    @Test func identical_frames_have_zero_distance() {
        let a = ScreenshotChangeDetector.signature(of: page())
        let b = ScreenshotChangeDetector.signature(of: page())
        #expect(ScreenshotChangeDetector.distance(a, b) == 0)
    }

    @Test func a_blinking_caret_is_under_the_threshold() {
        let a = ScreenshotChangeDetector.signature(of: page())
        let b = ScreenshotChangeDetector.signature(of: pageWithCaret())
        let d = ScreenshotChangeDetector.distance(a, b)
        #expect(d < ScreenContextLimits.screenshotChangeThreshold, "caret moved the score to \(d)")
    }

    @Test func scrolling_by_half_a_line_is_over_the_threshold() {
        let a = ScreenshotChangeDetector.signature(of: page())
        let b = ScreenshotChangeDetector.signature(of: page(offset: 12))
        let d = ScreenshotChangeDetector.distance(a, b)
        #expect(d >= ScreenContextLimits.screenshotChangeThreshold, "scroll only moved the score to \(d)")
    }

    @Test func the_signature_is_small_whatever_the_capture_size() {
        let big = ScreenshotChangeDetector.signature(of: image(width: 2560, height: 1080) { _ in })
        #expect(big.count <= 4_096)
    }
}

// MARK: - The gate in front of OCR

private final class SequenceCapturer: WindowImageCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CGImage]
    init(_ frames: [CGImage]) { self.frames = frames }
    private func next() -> CapturedWindow? {
        lock.lock(); defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }
        return CapturedWindow(bundleID: "com.a", windowTitle: "Doc", image: frames.removeFirst())
    }
    func capture() async -> CapturedWindow? { next() }
}

private final class CountingRecognizer: WindowImageTextRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    private func bump() -> String { lock.lock(); defer { lock.unlock() }; _calls += 1; return "read #\(_calls)" }
    func recognizeText(in capture: CapturedWindow) async -> String? { bump() }
}

private func text(_ content: ScreenContent?) -> WindowSnapshot? {
    guard case .text(let s) = content else { return nil }
    return s
}

@Suite("OCR source — pixel change gate")
struct OCRPixelChangeGateTests {

    @Test func an_unchanged_window_reuses_the_last_reading_without_running_ocr() async {
        let recognizer = CountingRecognizer()
        let source = OCRScreenContentSource(
            capturer: SequenceCapturer([page(), pageWithCaret()]),
            recognizer: recognizer
        )
        let first = text(await source.read())
        let second = text(await source.read())

        #expect(recognizer.calls == 1)
        #expect(first?.text == "read #1")
        #expect(second?.text == "read #1", "the caret blink must not cost an OCR pass")
        #expect(second?.source == .screenshot)
    }

    @Test func a_scrolled_window_is_read_again() async {
        let recognizer = CountingRecognizer()
        let source = OCRScreenContentSource(
            capturer: SequenceCapturer([page(), page(offset: 12)]),
            recognizer: recognizer
        )
        _ = await source.read()
        let second = text(await source.read())

        #expect(recognizer.calls == 2)
        #expect(second?.text == "read #2")
    }

    @Test func the_reused_reading_reports_no_read_time() async {
        let recognizer = CountingRecognizer()
        let source = OCRScreenContentSource(
            capturer: SequenceCapturer([page(), page()]),
            recognizer: recognizer
        )
        _ = await source.read()
        let second = text(await source.read())
        #expect((second?.timings.read ?? 1) < 0.05, "reuse must be nearly free, not a hidden OCR")
    }
}
