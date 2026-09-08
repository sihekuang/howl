import Foundation
import Testing
@testable import HowlCore

// The accessibility walk is 25–100× cheaper than OCR (measured
// 2026-09-08: 1–70ms against 1.4s of multi-core Vision), so it goes
// first. But AX cannot read text that lives inside pixels, and some
// apps expose nothing until their accessibility tree wakes up. This
// policy is the router: use the AX reading when it is credible, fall
// back to a screenshot when it is not — and say WHY, because the two
// reasons have different fixes.

@Suite("AX coverage policy")
struct AXCoveragePolicyTests {

    @Test func a_text_heavy_window_is_read_from_accessibility() {
        let coverage = AXCoverage(textChars: 5_244, nodes: 7, largestImageFraction: 0)
        #expect(AXCoveragePolicy.decide(coverage) == .useAccessibility)
    }

    @Test func too_little_text_falls_back_to_a_screenshot() {
        // Chrome before its accessibility tree wakes up: 92 nodes of
        // toolbar chrome and 60 characters of text.
        let coverage = AXCoverage(textChars: 60, nodes: 92, largestImageFraction: 0)
        #expect(AXCoveragePolicy.decide(coverage) == .useScreenshot(.accessibilityTooThin))
    }

    @Test func an_image_dominated_window_falls_back_even_with_some_text() {
        // A screenshot pasted into a chat: captions around it read
        // fine, the text IN it is invisible to AX.
        let coverage = AXCoverage(textChars: 900, nodes: 40, largestImageFraction: 0.6)
        #expect(AXCoveragePolicy.decide(coverage) == .useScreenshot(.imageHeavy))
    }

    @Test func a_small_inline_image_does_not_trigger_the_fallback() {
        let coverage = AXCoverage(textChars: 900, nodes: 40, largestImageFraction: 0.1)
        #expect(AXCoveragePolicy.decide(coverage) == .useAccessibility)
    }

    @Test func no_reading_at_all_is_thin() {
        #expect(AXCoveragePolicy.decide(nil) == .useScreenshot(.accessibilityTooThin))
    }

    @Test func the_thresholds_are_the_published_limits() {
        let justEnough = AXCoverage(textChars: ScreenContextLimits.minAccessibilityChars, nodes: 1, largestImageFraction: 0)
        #expect(AXCoveragePolicy.decide(justEnough) == .useAccessibility)
        let oneShort = AXCoverage(textChars: ScreenContextLimits.minAccessibilityChars - 1, nodes: 1, largestImageFraction: 0)
        #expect(AXCoveragePolicy.decide(oneShort) == .useScreenshot(.accessibilityTooThin))
        let atLimit = AXCoverage(textChars: 5_000, nodes: 1, largestImageFraction: ScreenContextLimits.maxAccessibilityImageFraction)
        #expect(AXCoveragePolicy.decide(atLimit) == .useScreenshot(.imageHeavy))
    }
}
