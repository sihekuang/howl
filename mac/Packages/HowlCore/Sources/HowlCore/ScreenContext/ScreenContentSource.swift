import Foundation
import OSLog

/// What a source yields for the focused window.
///
/// Two shapes, because the strategies genuinely produce different
/// things: Accessibility and OCR both read the window into TEXT, while
/// a vision model is handed the PIXELS and answers with keywords
/// itself. Go has one extractor for each shape, and this enum is what
/// tells the coordinator which one to call — the only thing about the
/// installed strategy it is allowed to know.
public enum ScreenContent: Sendable {
    /// Read into text on this machine. Goes to Go's text extractor
    /// (`howl_extract_keywords`).
    case text(WindowSnapshot)
    /// Read by the provider's vision model. Goes to Go's image
    /// extractor (`howl_extract_keywords_image`).
    case image(WindowImageCapture)

    /// The app the reading came from, for the post-read denylist gate
    /// and the activity record. Present in both shapes, which is why
    /// the gate can be written once.
    public var bundleID: String {
        switch self {
        case .text(let snapshot): snapshot.bundleID
        case .image(let capture): capture.bundleID
        }
    }

    /// Why this reading is a fallback rather than the strategy's
    /// primary one; nil when nothing fell back.
    public var fallbackReason: ScreenContextFallbackReason? {
        switch self {
        case .text(let snapshot): snapshot.fallbackReason
        case .image(let capture): capture.fallbackReason
        }
    }

    /// How long the stages that produced this reading took. Present in
    /// both shapes for the same reason `bundleID` is: the coordinator
    /// merges its own stages in without knowing which strategy ran.
    public var timings: ScreenContextTimings {
        switch self {
        case .text(let snapshot): snapshot.timings
        case .image(let capture): capture.timings
        }
    }

    /// The same reading, carrying `seconds` of additional model time.
    /// Used when a reading is retried through a different extractor and
    /// the first attempt's cost must not be lost.
    public func addingExtract(_ seconds: TimeInterval) -> ScreenContent {
        switch self {
        case .text(let s):
            .text(WindowSnapshot(
                bundleID: s.bundleID, windowTitle: s.windowTitle, windowID: s.windowID, text: s.text,
                source: s.source, fallbackReason: s.fallbackReason,
                pixelSize: s.pixelSize, timings: s.timings.addingExtract(seconds),
                coverage: s.coverage
            ))
        case .image(let c):
            .image(WindowImageCapture(
                bundleID: c.bundleID, windowTitle: c.windowTitle, pngData: c.pngData,
                pixelSize: c.pixelSize, fallbackReason: c.fallbackReason,
                timings: c.timings.addingExtract(seconds)
            ))
        }
    }

    /// The same reading, marked as having come from a fallback.
    public func marked(asFallback reason: ScreenContextFallbackReason) -> ScreenContent {
        switch self {
        case .text(let snapshot): .text(snapshot.marked(asFallback: reason))
        case .image(let capture): .image(capture.marked(asFallback: reason))
        }
    }
}

/// How the focused window gets read. THE injection seam for this
/// feature: OCR, a vision model and the Accessibility tree are three
/// interchangeable implementations, and swapping between them is one
/// expression in `CompositionRoot` with nothing else touched.
///
/// EVERY implementation owns the denylist guarantee in full. The rule
/// is not "the coordinator checks first" — it does, but that check and
/// the read are not atomic with each other. Each source must resolve
/// the frontmost app and apply the denylist in ONE MainActor hop via
/// `resolveReadableFrontmostApp`, and read the pid that hop returned.
/// No implementation may perform its own `NSWorkspace.frontmostApplication`
/// lookup; a source that did would be reading a window the denylist
/// never saw. See `resolveReadableFrontmostApp` for the scenario.
public protocol ScreenContentSource: Sendable {
    /// The strategy's reading of the focused window, or nil when it
    /// could not read it at all (no permission, no window, denylisted).
    func read() async -> ScreenContent?

    /// A reading of the same window in a DIFFERENT shape, for a caller
    /// that could not consume the first one — today, an extractor
    /// reporting that the configured model cannot accept images at all
    /// (`no_vision`). That verdict is about the extractor, not about
    /// the window, so it cannot be discovered by a source; the caller
    /// asks for this only after it hears it.
    ///
    /// Composed sources answer with their secondary. A leaf source has
    /// no alternative and answers nil, the default — which the caller
    /// treats as "no keywords this time" rather than an error.
    func readAlternate() async -> ScreenContent?
}

public extension ScreenContentSource {
    func readAlternate() async -> ScreenContent? { nil }
}

/// Reads the focused window through the Accessibility API. See
/// `AXWindowTextReader` for why this path is still here and must stay
/// healthy: it is the only zero-prompt strategy (no Screen Recording
/// TCC) and the only one that works when there are no pixels at all.
public struct AXScreenContentSource: ScreenContentSource {
    private let reader: any WindowTextReader

    public init(reader: any WindowTextReader) {
        self.reader = reader
    }

    /// Convenience for the composition root: the production reader,
    /// wired to the denylist it must never be built without.
    public init(denylist: @escaping @Sendable () -> ScreenContextDenylist) {
        self.init(reader: AXWindowTextReader(denylist: denylist))
    }

    public func read() async -> ScreenContent? {
        // The reader enforces the denylist itself, in one main-actor
        // hop, before it walks anything.
        let (snapshot, seconds) = await measuringDuration { await reader.read() }
        guard let snapshot else { return nil }
        // `capture` stays nil rather than zero: this strategy takes no
        // screenshot at all, which is a different fact from taking one
        // instantly.
        return .text(WindowSnapshot(
            bundleID: snapshot.bundleID, windowTitle: snapshot.windowTitle, windowID: snapshot.windowID,
            text: snapshot.text, source: snapshot.source,
            fallbackReason: snapshot.fallbackReason, pixelSize: snapshot.pixelSize,
            timings: snapshot.timings.merging(ScreenContextTimings(read: seconds)),
            coverage: snapshot.coverage
        ))
    }
}

/// Screenshots the focused window and reads it with local Vision OCR.
/// The default strategy: nothing but the recognized text ever leaves
/// the machine, and there is no per-image cost to trade against
/// resolution.
public struct OCRScreenContentSource: ScreenContentSource {
    private let capturer: any WindowImageCapturing
    private let recognizer: any WindowImageTextRecognizing
    /// The last reading per window, so a tick that captures the same
    /// pixels again can hand back the same text without paying for
    /// Vision. See `ScreenshotChangeDetector`.
    private let lastReadings = LastReadings()

    private final class LastReadings: @unchecked Sendable {
        struct Reading {
            let signature: [UInt8]
            let text: String
        }
        private let lock = NSLock()
        private var byWindow: [String: Reading] = [:]

        /// The previous text if the capture is (near enough) the same
        /// pixels as last time, else nil.
        func unchangedText(for key: String, signature: [UInt8]) -> String? {
            lock.lock(); defer { lock.unlock() }
            guard let previous = byWindow[key] else { return nil }
            let distance = ScreenshotChangeDetector.distance(previous.signature, signature)
            return distance < ScreenContextLimits.screenshotChangeThreshold ? previous.text : nil
        }

        func store(_ text: String, for key: String, signature: [UInt8]) {
            lock.lock(); defer { lock.unlock() }
            byWindow[key] = Reading(signature: signature, text: text)
            // Windows come and go; a handful of stale entries is
            // harmless, a thousand is a leak.
            if byWindow.count > 32 { byWindow.removeValue(forKey: byWindow.keys.first!) }
        }
    }

    public init(capturer: any WindowImageCapturing, recognizer: any WindowImageTextRecognizing) {
        self.capturer = capturer
        self.recognizer = recognizer
    }

    /// Convenience for the composition root.
    public init(denylist: @escaping @Sendable () -> ScreenContextDenylist) {
        self.init(
            capturer: ScreenCaptureKitWindowCapturer(denylist: denylist),
            recognizer: OCRWindowTextRecognizer()
        )
    }

    public func read() async -> ScreenContent? {
        // The capturer enforces the denylist itself, in one main-actor
        // hop, before ScreenCaptureKit is touched at all.
        let (capturedOrNil, captureSeconds) = await measuringDuration { await capturer.capture() }
        guard let captured = capturedOrNil else {
            return nil
        }
        // PIXEL GATE. Same window, same pixels as last tick — give or
        // take a caret — is the same text; Vision would spend ~1.4s of
        // multi-core CPU confirming that. The signature costs a few
        // milliseconds.
        let key = captured.windowID.map { "\(captured.bundleID)#\($0)" }
            ?? "\(captured.bundleID)\u{0}\(captured.windowTitle)"
        let (signature, signatureSeconds) = await measuringDuration {
            ScreenshotChangeDetector.signature(of: captured.image)
        }
        if let unchanged = lastReadings.unchangedText(for: key, signature: signature) {
            return .text(WindowSnapshot(
                bundleID: captured.bundleID,
                windowTitle: captured.windowTitle,
                windowID: captured.windowID,
                text: unchanged,
                source: .screenshot,
                pixelSize: captured.pixelSize,
                timings: ScreenContextTimings(capture: captureSeconds, read: signatureSeconds)
            ))
        }
        let (recognized, readSeconds) = await measuringDuration {
            await recognizer.recognizeText(in: captured)
        }
        // A screenshot that reads as blank is an EMPTY reading, not a
        // missing one: the capture happened, so the source must not
        // report "no window" and send the caller to a fallback.
        let text = recognized ?? ""
        lastReadings.store(text, for: key, signature: signature)
        return .text(WindowSnapshot(
            bundleID: captured.bundleID,
            windowTitle: captured.windowTitle,
            windowID: captured.windowID,
            text: text,
            source: .screenshot,
            pixelSize: captured.pixelSize,
            timings: ScreenContextTimings(capture: captureSeconds, read: signatureSeconds + readSeconds)
        ))
    }
}

/// Accessibility first, screenshot when accessibility is not credible.
///
/// The router the coverage policy feeds. `AXCoveragePolicy` says why
/// this order: the AX walk is 25–100× cheaper than OCR and exact where
/// OCR jitters. The screenshot stays as the fallback for the two
/// things AX cannot do — read text drawn in pixels, and read apps that
/// expose nothing — and each fallback is marked with its reason so the
/// inspector can tell them apart.
///
/// When the screenshot fails too (no Screen Recording permission), a
/// thin accessibility reading is still handed back rather than
/// nothing, marked `.screenshotUnavailable`.
public struct AXFirstScreenContentSource: ScreenContentSource {
    private let accessibility: any ScreenContentSource
    private let screenshot: any ScreenContentSource
    private let log = Logger(subsystem: "com.howl.app", category: "screencontext")

    public init(accessibility: any ScreenContentSource, screenshot: any ScreenContentSource) {
        self.accessibility = accessibility
        self.screenshot = screenshot
    }

    public func read() async -> ScreenContent? {
        let axContent = await accessibility.read()
        let coverage: AXCoverage? = {
            if case .text(let snapshot)? = axContent { return snapshot.coverage }
            return nil
        }()
        switch AXCoveragePolicy.decide(coverage) {
        case .useAccessibility:
            return axContent
        case .useScreenshot(let reason):
            if let pixels = await screenshot.read() {
                return pixels.marked(asFallback: reason)
            }
            log.notice("screen context screenshot unavailable; keeping the thin accessibility reading")
            return axContent?.marked(asFallback: .screenshotUnavailable)
        }
    }

    public func readAlternate() async -> ScreenContent? {
        await screenshot.read()
    }
}

/// Tries `primary`, and falls back to `secondary` when it yields
/// nothing at all.
///
/// This is how the fallback chain is expressed: by COMPOSITION, not by
/// branching inside the coordinator. The coordinator cannot see that
/// there are two sources here, which is exactly why swapping the
/// primary is a one-expression change.
///
/// `reasonWhenSecondaryUsed` is stamped onto the secondary's reading so
/// the diagnostic inspector can say why the user is looking at
/// accessibility text rather than their screen. Without it, a fallback
/// reading is indistinguishable from a primary one, and "grant Screen
/// Recording" becomes unguessable.
public struct FallbackScreenContentSource: ScreenContentSource {
    private let primary: any ScreenContentSource
    private let secondary: any ScreenContentSource
    private let reasonWhenSecondaryUsed: ScreenContextFallbackReason

    private let log = Logger(subsystem: "com.howl.app", category: "screencontext")

    public init(
        primary: any ScreenContentSource,
        secondary: any ScreenContentSource,
        reasonWhenSecondaryUsed: ScreenContextFallbackReason
    ) {
        self.primary = primary
        self.secondary = secondary
        self.reasonWhenSecondaryUsed = reasonWhenSecondaryUsed
    }

    public func read() async -> ScreenContent? {
        if let content = await primary.read() { return content }
        // `.notice` persists in the unified log; this is the line that
        // explains a permanently degraded feature after the fact. It
        // names no window and no text.
        log.notice("screen context primary source produced nothing; using the fallback source")
        return await secondary.read()?.marked(asFallback: reasonWhenSecondaryUsed)
    }

    /// The alternate shape IS the secondary: the caller could not
    /// consume the primary's reading, and the secondary is by
    /// construction the other way of reading this window.
    ///
    /// Deliberately NOT marked with `reasonWhenSecondaryUsed` — that
    /// reason describes the primary failing to read, which is not what
    /// happened. The caller knows why it rejected the reading and
    /// stamps that instead.
    public func readAlternate() async -> ScreenContent? {
        await secondary.read()
    }
}
