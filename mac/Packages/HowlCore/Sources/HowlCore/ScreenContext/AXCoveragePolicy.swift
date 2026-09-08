import Foundation

/// What an accessibility walk found, beyond the text itself. The
/// numbers the router needs to judge whether that text is a credible
/// reading of the window.
///
/// Measured 2026-09-08 on live windows: a terminal exposes its whole
/// buffer as one `AXTextArea` (5,244 chars in 7 nodes); Chrome and
/// Electron apps expose only toolbar chrome (60 and 12 chars) until
/// their accessibility tree wakes up, and thousands of chars after.
/// An image is one `AXImage` node whatever text is drawn inside it.
public struct AXCoverage: Equatable, Sendable {
    /// Characters of value/title text collected by the walk.
    public let textChars: Int
    /// Nodes visited.
    public let nodes: Int
    /// Area of the largest `AXImage` as a fraction of the window's
    /// area, 0 when there is none. Text drawn inside that image is
    /// invisible to accessibility, which is what this number is for.
    public let largestImageFraction: Double

    public init(textChars: Int, nodes: Int, largestImageFraction: Double) {
        self.textChars = textChars
        self.nodes = nodes
        self.largestImageFraction = largestImageFraction
    }
}

/// Whether to trust an accessibility reading or take a screenshot.
///
/// Accessibility goes first because it is 25–100× cheaper than OCR:
/// 1–70ms and a few milliseconds of CPU in each process, against
/// ~1.4s of multi-core Vision per tick on a 2560×1080 window. It is
/// also exact, which OCR is not, so an unchanged window hits the
/// exact-hash cache instead of jittering past the similarity gate
/// into another LLM call.
///
/// It cannot read pixels, and it cannot read apps that expose
/// nothing. Both cases fall back to the screenshot — with a distinct
/// reason each, because the fixes differ: a thin tree may wake up on
/// its own (Chromium enables accessibility once it notices queries),
/// while an image-heavy window stays image-heavy.
public enum AXCoveragePolicy {
    public enum Decision: Equatable, Sendable {
        case useAccessibility
        case useScreenshot(ScreenContextFallbackReason)
    }

    public static func decide(_ coverage: AXCoverage?) -> Decision {
        guard let coverage else { return .useScreenshot(.accessibilityTooThin) }
        if coverage.largestImageFraction >= ScreenContextLimits.maxAccessibilityImageFraction {
            return .useScreenshot(.imageHeavy)
        }
        if coverage.textChars < ScreenContextLimits.minAccessibilityChars {
            return .useScreenshot(.accessibilityTooThin)
        }
        return .useAccessibility
    }
}
