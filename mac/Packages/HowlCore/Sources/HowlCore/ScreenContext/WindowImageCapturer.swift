import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Raw pixels of the user's focused window, straight from
/// ScreenCaptureKit, with the identity needed to cache and denylist it.
///
/// Deliberately unencoded and un-resampled. What happens to the pixels
/// next is the content source's business: `OCRScreenContentSource`
/// reads them locally and never encodes anything, while
/// `VisionModelScreenContentSource` downscales and PNG-encodes them for
/// the provider. Encoding here would charge the OCR strategy for a
/// round trip it does not use, and downscaling here would silently
/// wreck it (see `OCRWindowTextRecognizer`).
///
/// The pixels are never written to disk, never logged, and never stored
/// in the diagnostic activity record — only the dimensions are.
public struct CapturedWindow: Sendable {
    public let bundleID: String
    public let windowTitle: String
    /// The capture at native resolution.
    public let image: CGImage

    /// Dimensions of `image`. Computed rather than stored so the two
    /// can never disagree.
    public var pixelSize: ScreenContextPixelSize {
        ScreenContextPixelSize(width: image.width, height: image.height)
    }

    public init(bundleID: String, windowTitle: String, image: CGImage) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.image = image
    }
}

/// Captures the frontmost window's pixels. Implementations return nil
/// when they cannot capture it at all (no Screen Recording permission,
/// no on-screen window, denylisted app) — every one of which degrades
/// to whatever the installed strategy has as its fallback, and from
/// there to dictionary-only biasing.
public protocol WindowImageCapturing: Sendable {
    func capture() async -> CapturedWindow?
}

/// One of an app's on-screen windows, reduced to just what choosing
/// between them needs. `SCWindow` cannot be constructed in a test, so
/// the choice is made over this instead and the capturer maps into it.
struct WindowCandidate: Equatable, Sendable {
    let pid: pid_t
    let isOnScreen: Bool
    let width: CGFloat
    let height: CGFloat

    var area: CGFloat { width * height }
}

/// Picks which of an app's windows to photograph, returning its index
/// in `candidates`.
///
/// Apps routinely have more than one on-screen window, and several of
/// them are tiny transients that contain no text worth extracting:
/// Chrome's 159x22 link-preview bubble is the one that prompted this.
/// Taking whichever matching window happened to come first meant that
/// while such a transient existed, the capture was a coin flip between
/// the user's actual window and a scrap of chrome — and the failure was
/// invisible, because a successfully-photographed 159x22 bubble OCRs to
/// nothing and is indistinguishable in the log from a window that
/// genuinely had no text.
///
/// Largest-area wins. It is not a proxy for "focused" and does not try
/// to be: when an app has a real window and a transient, the real one
/// is larger by orders of magnitude, which is the case that was
/// breaking. Ties resolve to the earlier index, preserving the caller's
/// front-to-back order.
func chooseWindow(from candidates: [WindowCandidate], pid: pid_t) -> Int? {
    var best: (index: Int, area: CGFloat)?
    for (index, candidate) in candidates.enumerated() {
        guard candidate.pid == pid, candidate.isOnScreen else { continue }
        // Strictly greater, so equal areas keep the earlier window.
        if best == nil || candidate.area > best!.area {
            best = (index, candidate.area)
        }
    }
    return best?.index
}

/// Screenshots the focused window. Shared by every pixel-based content
/// source — the OCR one and the vision-model one — so the denylist
/// discipline below is written once and cannot drift between them.
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

    public init(denylist: @escaping @Sendable () -> ScreenContextDenylist,
                frontmostApp: @escaping FrontmostAppLookup = defaultFrontmostApp) {
        self.denylist = denylist
        self.frontmostApp = frontmostApp
    }

    public func capture() async -> CapturedWindow? {
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
            // NOT `first(where:)`. An app commonly has several
            // on-screen windows, and the tiny transient ones carry no
            // text — see `chooseWindow`, which this defers to so the
            // policy is unit-testable without a live SCWindow.
            let candidates = content.windows.map {
                WindowCandidate(
                    pid: $0.owningApplication?.processID ?? -1,
                    isOnScreen: $0.isOnScreen,
                    width: $0.frame.width,
                    height: $0.frame.height
                )
            }
            guard let index = chooseWindow(from: candidates, pid: pid) else { return nil }
            let window = content.windows[index]

            // `SCStreamConfiguration.width/height` are measured in
            // pixels, but `window.frame` is in points — on a 2x Retina
            // display, sizing the config directly from the frame would
            // capture at half resolution per axis (a quarter of the
            // pixels) and degrade exactly the small glyphs this feature
            // most needs (dense code identifiers in editors and
            // terminals), whichever strategy is installed. Scale by the
            // content filter's pointPixelScale, and ask for the best
            // available resolution explicitly rather than relying on
            // defaults.
            //
            // Capture at full fidelity and let the content source
            // decide what to do about size: the vision-model source
            // resamples deterministically afterwards, and the OCR
            // source needs every pixel.
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

            return CapturedWindow(
                bundleID: bundleID,
                windowTitle: window.title ?? "",
                image: image
            )
        } catch {
            // Permission denied, or the window vanished mid-capture.
            // Both degrade to "no screenshot" by design — never a
            // thrown error, never a dialog. The error itself is
            // deliberately not logged: it can name the window.
            return nil
        }
    }
}
