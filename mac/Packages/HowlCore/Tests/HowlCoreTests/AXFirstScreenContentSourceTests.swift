import Foundation
import Testing
@testable import HowlCore

private final class CountingSource: ScreenContentSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _reads = 0
    let content: ScreenContent?
    init(_ content: ScreenContent?) { self.content = content }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
    private func bump() -> ScreenContent? { lock.lock(); defer { lock.unlock() }; _reads += 1; return content }
    func read() async -> ScreenContent? { bump() }
}

private func axSnapshot(chars: Int, imageFraction: Double = 0, title: String = "Doc") -> ScreenContent {
    .text(WindowSnapshot(
        bundleID: "com.a", windowTitle: title,
        text: String(repeating: "w ", count: chars / 2),
        source: .accessibility,
        coverage: AXCoverage(textChars: chars, nodes: 10, largestImageFraction: imageFraction)
    ))
}

private func ocrSnapshot() -> ScreenContent {
    .text(WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "pixels read", source: .screenshot))
}

private func text(_ content: ScreenContent?) -> WindowSnapshot? {
    guard case .text(let s) = content else { return nil }
    return s
}

@Suite("AX-first screen content source")
struct AXFirstScreenContentSourceTests {

    @Test func a_credible_accessibility_reading_is_used_and_no_screenshot_is_taken() async {
        let ax = CountingSource(axSnapshot(chars: 4_000))
        let ocr = CountingSource(ocrSnapshot())
        let source = AXFirstScreenContentSource(accessibility: ax, screenshot: ocr)

        let reading = text(await source.read())

        #expect(reading?.source == .accessibility)
        #expect(reading?.fallbackReason == nil)
        #expect(ocr.reads == 0, "the whole point: no capture, no OCR")
    }

    @Test func a_thin_accessibility_reading_is_replaced_by_the_screenshot_and_says_why() async {
        let ax = CountingSource(axSnapshot(chars: 40))
        let ocr = CountingSource(ocrSnapshot())
        let source = AXFirstScreenContentSource(accessibility: ax, screenshot: ocr)

        let reading = text(await source.read())

        #expect(reading?.source == .screenshot)
        #expect(reading?.fallbackReason == .accessibilityTooThin)
        #expect(ocr.reads == 1)
    }

    @Test func an_image_heavy_window_is_read_from_pixels_and_says_why() async {
        let ax = CountingSource(axSnapshot(chars: 900, imageFraction: 0.7))
        let ocr = CountingSource(ocrSnapshot())
        let source = AXFirstScreenContentSource(accessibility: ax, screenshot: ocr)

        let reading = text(await source.read())

        #expect(reading?.source == .screenshot)
        #expect(reading?.fallbackReason == .imageHeavy)
    }

    @Test func no_accessibility_window_at_all_goes_to_the_screenshot() async {
        let ax = CountingSource(nil)
        let ocr = CountingSource(ocrSnapshot())
        let source = AXFirstScreenContentSource(accessibility: ax, screenshot: ocr)

        let reading = text(await source.read())

        #expect(reading?.source == .screenshot)
        #expect(reading?.fallbackReason == .accessibilityTooThin)
    }

    @Test func when_the_screenshot_also_fails_the_thin_reading_is_better_than_nothing() async {
        // No Screen Recording permission: the thin AX text is all
        // there is, and it is still marked so the inspector can explain.
        let ax = CountingSource(axSnapshot(chars: 40))
        let ocr = CountingSource(nil)
        let source = AXFirstScreenContentSource(accessibility: ax, screenshot: ocr)

        let reading = text(await source.read())

        #expect(reading?.source == .accessibility)
        #expect(reading?.fallbackReason == .screenshotUnavailable)
    }

    @Test func nothing_from_either_is_a_missing_reading() async {
        let source = AXFirstScreenContentSource(accessibility: CountingSource(nil), screenshot: CountingSource(nil))
        #expect(await source.read() == nil)
    }

    @Test func the_alternate_reading_is_the_screenshot() async {
        let ax = CountingSource(axSnapshot(chars: 4_000))
        let ocr = CountingSource(ocrSnapshot())
        let source = AXFirstScreenContentSource(accessibility: ax, screenshot: ocr)
        #expect(text(await source.readAlternate())?.source == .screenshot)
    }
}
