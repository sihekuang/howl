import AppKit
import Foundation

/// Resolves the frontmost app's identity. Injectable so the
/// denylist guarantee below is testable without a live AppKit
/// frontmost app; production uses `defaultFrontmostApp`.
public typealias FrontmostAppLookup = @Sendable @MainActor () -> (bundleID: String, pid: pid_t)?

/// Production frontmost-app lookup.
///
/// `NSWorkspace.frontmostApplication`'s thread affinity is not
/// documented by Apple. AppKit is documented as requiring a run loop
/// and not being daemon-safe; `NSRunningApplication`'s properties are
/// documented as atomic, but that guarantees the returned object's
/// consistency, not which thread may call the accessor. Nothing
/// certifies this is safe off the main thread — and nothing in the
/// Swift 6 checker enforces it either, since NSWorkspace carries no
/// actor-isolation annotation for the compiler to catch a mistake
/// against. A clean `swift build` is not a safety certificate. Hence
/// `@MainActor` here and the hop in `resolveReadableFrontmostApp`; do
/// not remove either as "redundant" without documented evidence.
@MainActor
public func defaultFrontmostApp() -> (bundleID: String, pid: pid_t)? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          let bundleID = app.bundleIdentifier else { return nil }
    return (bundleID, app.processIdentifier)
}

/// Resolves the frontmost app and applies the denylist to it **inside a
/// single main-actor hop**, returning nil if it must not be read.
///
/// The adjacency is the entire point, and it is why this lives here
/// rather than in the coordinator. A caller-side gate cannot make this
/// guarantee: the coordinator checks the denylist, then `await`s the
/// capture, and the capturer independently resolves frontmost again —
/// so the app that was checked and the app that gets photographed can
/// differ. That window is not theoretical. It opens on the single most
/// ordinary sequence there is: finish typing in an editor, the 800ms
/// debounce fires precisely because you stopped, and you alt-tab to
/// your password manager while the capture is in flight. The
/// screenshot then contains the vault.
///
/// Resolving the identity and judging it with no suspension point in
/// between closes that: the pid handed back is the pid that was
/// checked, so the window that is captured is by construction the
/// window that was cleared. `shouldSkip` is fail-closed on nil and
/// empty bundle IDs, so "we cannot tell what this is" also declines.
///
/// Both consumers route through here — `ScreenCaptureKitWindowCapturer`
/// (the primary path) and `AXWindowTextReader` (the no-vision
/// fallback) — and the guard precedes every ScreenCaptureKit call, so
/// a denylisted app never even triggers the Screen Recording prompt.
///
/// The denylist is snapshotted BEFORE the hop on purpose: building it
/// reads and JSON-decodes user settings, which has no business running
/// on the main thread. Only the `Set` membership test happens inside.
/// A snapshot microseconds old is irrelevant — it changes only when the
/// user edits settings, whereas the frontmost app changes constantly,
/// and it is that pairing which has to be atomic.
func resolveReadableFrontmostApp(
    denylist: @Sendable () -> ScreenContextDenylist,
    lookup: @escaping FrontmostAppLookup
) async -> (bundleID: String, pid: pid_t)? {
    let list = denylist()
    return await MainActor.run {
        guard let app = lookup() else { return nil }
        if list.shouldSkip(bundleID: app.bundleID) { return nil }
        return app
    }
}

/// Text read from the user's focused window, with the identity needed
/// to cache and denylist it.
///
/// Produced by every content source whose reading is TEXT — Vision OCR
/// over a screenshot (`OCRScreenContentSource`) and the Accessibility
/// tree (`AXScreenContentSource`) — which is why it carries `source`:
/// downstream, the two are the same string and the inspector would
/// otherwise have no way to say which read produced it.
public struct WindowSnapshot: Equatable, Sendable {
    public let bundleID: String
    public let windowTitle: String
    public let text: String
    /// Which read produced this text. Set by the source that made it,
    /// never inferred by the coordinator — the whole point of the
    /// `ScreenContentSource` seam is that the coordinator cannot tell
    /// what strategy is installed.
    public let source: ScreenContextOrigin
    /// Why this reading is a fallback rather than the strategy's
    /// primary one; nil when nothing fell back. Stamped by
    /// `FallbackScreenContentSource` (or by the coordinator when an
    /// extractor rejects the primary reading), not by the leaf source,
    /// which has no way to know it is second in line.
    public let fallbackReason: ScreenContextFallbackReason?
    /// Dimensions of the screenshot this text was read out of; nil for
    /// a reading that came from no pixels at all, like the AX walk.
    ///
    /// Carried purely so a reading that recognised NOTHING can still
    /// say what it was looking at. Without it, a successfully
    /// photographed 159x22 scrap of window chrome and a real window
    /// that genuinely had no text produce identical records, which is
    /// what made `chooseWindow`'s bug invisible for as long as it was.
    public let pixelSize: ScreenContextPixelSize?
    /// How long the stages that produced this reading took. Filled in
    /// by the source, which is the only place the capture/read split
    /// is visible; the coordinator adds `extract` and `total` later.
    public let timings: ScreenContextTimings

    public init(
        bundleID: String,
        windowTitle: String,
        text: String,
        source: ScreenContextOrigin,
        fallbackReason: ScreenContextFallbackReason? = nil,
        pixelSize: ScreenContextPixelSize? = nil,
        timings: ScreenContextTimings = ScreenContextTimings()
    ) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.text = text
        self.source = source
        self.fallbackReason = fallbackReason
        self.pixelSize = pixelSize
        self.timings = timings
    }

    /// The same reading, marked as having come from a fallback.
    public func marked(asFallback reason: ScreenContextFallbackReason) -> WindowSnapshot {
        WindowSnapshot(bundleID: bundleID, windowTitle: windowTitle, text: text,
                       source: source, fallbackReason: reason, pixelSize: pixelSize,
                       timings: timings)
    }
}

/// Reads the text of the frontmost window. Implementations return nil
/// when they cannot read it at all (no permission, no focused window,
/// unsupported app).
public protocol WindowTextReader: Sendable {
    func read() async -> WindowSnapshot?
}
