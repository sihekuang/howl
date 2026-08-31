import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
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

    public init(bundleID: String, windowTitle: String, pngData: Data) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.pngData = pngData
    }
}

/// Captures the frontmost window as an encoded image. Implementations
/// return nil when they cannot capture it at all (no Screen Recording
/// permission, no on-screen window, denylisted app, encode failure) —
/// every one of which degrades to dictionary-only biasing.
public protocol WindowImageCapturing: Sendable {
    func capture() async -> WindowImageCapture?
}

/// Sizing policy for the captured screenshot, factored out of the
/// capturer so it is testable without a live display.
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
/// vision model. This is the primary screen-context path; the model
/// does the reading that Vision OCR used to do here.
///
/// Constructing it does nothing; the Screen Recording TCC prompt
/// appears on the first actual `capture()` — and never for a
/// denylisted app, because the guard below precedes every
/// ScreenCaptureKit call. Pixel buffers are never written to disk.
public struct ScreenCaptureKitWindowCapturer: WindowImageCapturing {
    /// No default, for the same reason as `AXWindowTextReader` — and
    /// more sharply here, because this is the type that takes the
    /// screenshot.
    private let denylist: @Sendable () -> ScreenContextDenylist
    private let frontmostApp: FrontmostAppLookup
    private let maxLongEdge: Int

    public init(denylist: @escaping @Sendable () -> ScreenContextDenylist,
                frontmostApp: @escaping FrontmostAppLookup = defaultFrontmostApp,
                maxLongEdge: Int = ScreenshotScaling.maxLongEdge) {
        self.denylist = denylist
        self.frontmostApp = frontmostApp
        self.maxLongEdge = maxLongEdge
    }

    public func capture() async -> WindowImageCapture? {
        // Identity resolved and denylist-checked in ONE main-actor hop,
        // and the pid that comes back is the pid that was cleared. Do
        // not replace this with an independent
        // `NSWorkspace.frontmostApplication` lookup: the two
        // observations would no longer be atomic, and the window this
        // photographs could then be a window the denylist never saw.
        // The sequence is entirely ordinary — focus settles in an
        // editor, the debounce fires precisely because typing stopped,
        // and the user alt-tabs to their password manager while the
        // capture is in flight. See `resolveReadableFrontmostApp`.
        //
        // This guard also precedes every ScreenCaptureKit call below,
        // so a denylisted app never even triggers the Screen Recording
        // permission prompt.
        guard let (bundleID, pid) = await resolveReadableFrontmostApp(
            denylist: denylist, lookup: frontmostApp
        ) else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let window = content.windows.first(where: {
                $0.owningApplication?.processID == pid && $0.isOnScreen
            }) else { return nil }

            // `SCStreamConfiguration.width/height` are measured in
            // pixels, but `window.frame` is in points — on a 2x Retina
            // display, sizing the config directly from the frame would
            // capture at half resolution per axis (a quarter of the
            // pixels) and hand the vision model a blurred copy of
            // exactly the small glyphs this feature most needs (dense
            // code identifiers in editors and terminals). Scale by the
            // content filter's pointPixelScale, and ask for the best
            // available resolution explicitly rather than relying on
            // defaults.
            //
            // Carried over verbatim from the deleted OCR reader, where
            // it was arrived at the hard way. Capture at full fidelity
            // and downscale afterwards, rather than asking
            // ScreenCaptureKit for a smaller frame: the resample below
            // is deterministic and aspect-preserving, whereas
            // `captureResolution = .best` against an undersized config
            // is not documented to produce either.
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)

            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )

            let sized = ScreenCaptureKitWindowCapturer.downscale(image, maxLongEdge: maxLongEdge) ?? image
            guard let png = ScreenCaptureKitWindowCapturer.encodePNG(sized) else { return nil }

            return WindowImageCapture(
                bundleID: bundleID,
                windowTitle: window.title ?? "",
                pngData: png
            )
        } catch {
            // Permission denied, window vanished mid-capture, or an
            // encode failure. All degrade to "no screen context" by
            // design — never a thrown error, never a dialog. The error
            // itself is deliberately not logged: it can name the
            // window.
            return nil
        }
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
