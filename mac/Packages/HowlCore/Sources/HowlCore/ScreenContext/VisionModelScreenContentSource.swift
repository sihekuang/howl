import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A PNG screenshot of the user's focused window, with the identity
/// needed to cache and denylist it.
///
/// `pngData` is the exact payload handed to the vision model. It is
/// never written to disk, never logged, and never stored in the
/// diagnostic activity record — only its byte count is.
public struct WindowImageCapture: Equatable, Sendable {
    public let bundleID: String
    public let windowTitle: String
    public let pngData: Data
    /// Dimensions of `pngData` as encoded, i.e. after any downscale.
    /// The source already has these numbers; carrying them costs two
    /// integers and lets the diagnostic inspector report what the model
    /// was actually shown without the image travelling any further than
    /// it already does.
    public let pixelSize: ScreenContextPixelSize
    /// Why this reading is a fallback rather than the strategy's
    /// primary one; nil when nothing fell back. See
    /// `WindowSnapshot.fallbackReason`.
    public let fallbackReason: ScreenContextFallbackReason?
    /// How long the stages that produced this reading took. The vision
    /// strategy has no `read` stage — the model does that itself, and
    /// the time lands in `extract`.
    public let timings: ScreenContextTimings

    public init(
        bundleID: String,
        windowTitle: String,
        pngData: Data,
        pixelSize: ScreenContextPixelSize,
        fallbackReason: ScreenContextFallbackReason? = nil,
        timings: ScreenContextTimings = ScreenContextTimings()
    ) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.pngData = pngData
        self.pixelSize = pixelSize
        self.fallbackReason = fallbackReason
        self.timings = timings
    }

    /// The same reading, marked as having come from a fallback.
    public func marked(asFallback reason: ScreenContextFallbackReason) -> WindowImageCapture {
        WindowImageCapture(bundleID: bundleID, windowTitle: windowTitle, pngData: pngData,
                           pixelSize: pixelSize, fallbackReason: reason, timings: timings)
    }
}

/// Sizing policy for the screenshot sent to a vision model, factored
/// out of the source so it is testable without a live display.
///
/// Applies to the VISION-MODEL strategy only. It exists to cut what a
/// remote model is billed for, and OCR — which reads the same pixels
/// locally, for free — must never be put through it: shrinking the
/// image is precisely what stops Vision recognizing small text. See
/// `OCRWindowTextRecognizer`.
public enum ScreenshotScaling {
    /// Anthropic documents 1568px as the long edge above which images
    /// are downscaled server-side anyway; OpenAI's tiling is
    /// comparable. Sending anything larger costs bytes and latency and
    /// buys nothing.
    ///
    /// The measured OCR data behind the design justifies stopping here
    /// rather than going smaller: rendered code stayed fully legible at
    /// 1x down to ~9pt, so halving a Retina capture is safely inside
    /// that envelope and halving it again would not be.
    public static let maxLongEdge = 1568

    /// Pixel size to encode at, preserving aspect ratio. Returns nil
    /// when no resampling is needed — a window smaller than the cap is
    /// encoded exactly as captured, so small glyphs are never softened
    /// by a pointless resample.
    public static func downscaledSize(width: Int, height: Int, maxLongEdge: Int = maxLongEdge) -> (width: Int, height: Int)? {
        let longEdge = max(width, height)
        guard longEdge > maxLongEdge, width > 0, height > 0, maxLongEdge > 0 else { return nil }
        let factor = Double(maxLongEdge) / Double(longEdge)
        return (
            width: max(1, Int((Double(width) * factor).rounded())),
            height: max(1, Int((Double(height) * factor).rounded()))
        )
    }
}

/// Screenshots the focused window and hands the PNG bytes to the
/// provider's vision model, which does the reading itself and answers
/// with keywords.
///
/// One of the three interchangeable `ScreenContentSource` strategies.
/// It is the only one that encodes anything: PNG encoding exists
/// solely to put pixels on the wire, so the OCR strategy — which reads
/// the same capture in-process — must never pay for it.
///
/// Constructing it does nothing; the Screen Recording TCC prompt
/// appears on the first actual `read()` — and never for a denylisted
/// app, because the capturer's guard precedes every ScreenCaptureKit
/// call. Pixel buffers are never written to disk.
public struct VisionModelScreenContentSource: ScreenContentSource {
    private let capturer: any WindowImageCapturing
    private let maxLongEdge: Int

    public init(capturer: any WindowImageCapturing,
                maxLongEdge: Int = ScreenshotScaling.maxLongEdge) {
        self.capturer = capturer
        self.maxLongEdge = maxLongEdge
    }

    /// Convenience for the composition root.
    public init(denylist: @escaping @Sendable () -> ScreenContextDenylist,
                maxLongEdge: Int = ScreenshotScaling.maxLongEdge) {
        self.init(capturer: ScreenCaptureKitWindowCapturer(denylist: denylist), maxLongEdge: maxLongEdge)
    }

    public func read() async -> ScreenContent? {
        // The capturer enforces the denylist itself, in one main-actor
        // hop, before ScreenCaptureKit is touched at all.
        // Measured across capture AND the resample/encode below: all
        // three are what it costs to produce the pixels the model is
        // shown, and the clock stops where the reading is ready.
        let clock = ContinuousClock()
        let start = clock.now
        guard let captured = await capturer.capture() else { return nil }

        // Resample AFTER capture rather than asking ScreenCaptureKit
        // for a smaller frame: this is deterministic and
        // aspect-preserving, whereas `captureResolution = .best`
        // against an undersized config is not documented to be either.
        let sized = VisionModelScreenContentSource.downscale(captured.image, maxLongEdge: maxLongEdge)
            ?? captured.image
        // An encode failure loses the reading entirely — nil rather
        // than an empty payload, so a composed fallback can still run.
        guard let png = VisionModelScreenContentSource.encodePNG(sized) else { return nil }

        return .image(WindowImageCapture(
            bundleID: captured.bundleID,
            windowTitle: captured.windowTitle,
            pngData: png,
            pixelSize: ScreenContextPixelSize(width: sized.width, height: sized.height),
            // The downscale and PNG encode are inside `capture`
            // rather than given a stage of their own: they are part of
            // producing the pixels the model is shown, and splitting
            // them out would invent a stage the other two strategies
            // have no counterpart for. `read` stays nil — this
            // strategy never turns the window into text locally.
            timings: ScreenContextTimings(capture: (clock.now - start).timeInterval)
        ))
    }

    /// Resamples to the long-edge cap, or returns nil when the image is
    /// already within it (the caller then encodes the original).
    static func downscale(_ image: CGImage, maxLongEdge: Int) -> CGImage? {
        guard let target = ScreenshotScaling.downscaledSize(
            width: image.width, height: image.height, maxLongEdge: maxLongEdge
        ) else { return nil }

        guard let context = CGContext(
            data: nil,
            width: target.width,
            height: target.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // Text survives a downscale far better with a proper filter
        // than with the default; this runs once per debounced focus
        // change, so the cost is irrelevant.
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        return context.makeImage()
    }

    /// PNG rather than JPEG: JPEG's ringing artifacts land hardest on
    /// small glyphs, which is the entire content of interest here.
    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
