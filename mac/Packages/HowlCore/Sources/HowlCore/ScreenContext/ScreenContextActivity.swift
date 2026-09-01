import Foundation

/// Byte/token limits the whisper-biasing chain applies, mirrored here
/// purely so the diagnostic inspector can explain its own numbers
/// without hardcoding them a second time.
public enum ScreenContextLimits {
    /// Mirrors `screenctx.MaxWindowTextBytes`
    /// (`core/internal/screenctx/extract.go`): window text is
    /// truncated to this many UTF-8 bytes before it is ever sent to
    /// the LLM. A capture longer than this is what the inspector's
    /// "truncated" note is about.
    public static let maxWindowTextBytesForExtraction = 8192
}

/// Which read actually produced what the model saw on a given refresh
/// — the answer to "was my screen read, or did we fall back to the
/// accessibility tree?", which is otherwise unrecoverable from the
/// record.
///
/// Set by the `ScreenContentSource` that did the reading, never
/// inferred: the coordinator deliberately cannot tell which strategy is
/// installed.
public enum ScreenContextSource: String, Equatable, Sendable {
    /// The focused window was photographed. Either Vision OCR read
    /// those pixels locally (`OCRScreenContentSource`, the default) or
    /// the PNG went to the provider's vision model
    /// (`VisionModelScreenContentSource`) — `capturedText` is present
    /// for the first and `capturedImageBytes` for the second.
    case screenshot
    /// The Accessibility API's text, from `AXScreenContentSource`.
    /// Usually a fallback — `ScreenContextFallbackReason` says why —
    /// but it is also a strategy in its own right. See
    /// `AXWindowTextReader`.
    case accessibility
}

/// Why a refresh took the Accessibility text path instead of the
/// primary screenshot path.
///
/// Recorded ALONGSIDE the outcome, never instead of it: the outcome
/// describes what the AX read then produced, and this describes why
/// the image path was skipped before it. Both facts are needed and
/// neither substitutes for the other — a record reading
/// "no readable text" is a different diagnosis depending on whether
/// the screenshot failed or the model simply cannot see, and the two
/// call for opposite fixes (grant Screen Recording vs change model).
///
/// nil on the primary path: no fallback happened.
public enum ScreenContextFallbackReason: String, Equatable, Sendable {
    /// The configured provider+model rejected the image, or silently
    /// dropped it (Go's canary catches that). Go caches the verdict
    /// for the session, keyed on provider+model.
    case noVision
    /// No screenshot existed to send: Screen Recording denied, no
    /// on-screen window, or the window vanished mid-capture.
    ///
    /// Falling through to AX here is deliberate. Screen Recording
    /// denial is a statement about screenshots, not about the feature
    /// — the feature's own toggle is what turns it off, and the user
    /// left that on. Accessibility is a separate permission Howl
    /// already holds for paste injection, and the image → text
    /// direction is cheaper, not pricier. The alternative (clear and
    /// return) silently and permanently kills screen context for
    /// everyone who declines "a dictation app wants to record your
    /// screen", which is a very likely path.
    case screenshotUnavailable
}

/// Pixel dimensions of a captured screenshot.
///
/// Two integers, never the pixels themselves — see
/// `ScreenContextActivity.capturedImageBytes` for why the image never
/// travels into the record.
public struct ScreenContextPixelSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// One outcome of `ScreenContextCoordinator.refresh()`, captured for
/// the diagnostic inspector.
///
/// This is diagnostic-only, in-memory state: nothing here is written
/// to disk or to the unified log (see `ScreenContextCoordinator`'s own
/// logging comment on why its four log lines carry only counts, never
/// window text or a provider response). `ScreenContextActivity` is the
/// deliberate exception — it exists specifically so raw window text
/// and raw LLM responses ARE visible, live, to the user who asked to
/// see them, without ever persisting past the app's lifetime.
public struct ScreenContextActivity: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    /// The app the refresh concerned, when known. nil only for
    /// `.disabled` — every other outcome has at least attempted a
    /// frontmost-app lookup before reaching its early-return.
    public let bundleID: String?
    public let outcome: Outcome

    /// Which path produced the payload the model saw. Populated for
    /// `.cacheHit`, `.extractionSucceeded` and `.extractionFailed` —
    /// the outcomes reached only after a capture or read succeeded.
    public let source: ScreenContextSource?

    /// The window text actually read — Vision OCR's output on the
    /// `.screenshot` path, the accessibility tree's on the
    /// `.accessibility` one. Either way it is exactly the string sent
    /// to the LLM, which is the whole point of showing it. Populated
    /// for `.cacheHit`, `.extractionSucceeded`, and `.extractionFailed`
    /// — the three outcomes reached only after a real read succeeded —
    /// and never on the vision-model path, which sends no text at all.
    ///
    /// Deliberately NOT populated for `.skippedPostReadDenylist`, even
    /// though a read may have already happened by the time that gate
    /// fires: that gate is the authoritative guarantee that a
    /// denylisted app's content goes no further, and recording its
    /// text here — even in memory, even for the user's own eyes —
    /// would quietly defeat the one guarantee that gate exists to
    /// provide.
    public let capturedText: String?
    public let capturedTextLength: Int?

    /// Size of the PNG handed to the vision model, in bytes.
    /// Populated only on the `.screenshot` path.
    ///
    /// The byte count and nothing more, on purpose. The image itself
    /// is the user's screen; unlike window text, there is no version
    /// of showing it in a diagnostic panel that is worth the risk of
    /// it being retained, screenshotted or pasted onward — so the
    /// bytes are never held past the extraction call, here or
    /// anywhere.
    public let capturedImageBytes: Int?

    /// Dimensions of that same PNG, in pixels, after the long-edge
    /// downscale — so the inspector can say whether the model was
    /// shown something legible. Carried as two integers the capturer
    /// already had; no pixel data moves to produce it. Populated
    /// wherever `capturedImageBytes` is.
    public let capturedImagePixelSize: ScreenContextPixelSize?

    /// Why this refresh fell back to the Accessibility text path, when
    /// it did. nil whenever the screenshot path ran to completion.
    ///
    /// Orthogonal to `outcome`, which reports what the fallback then
    /// produced. See `ScreenContextFallbackReason`.
    public let fallbackReason: ScreenContextFallbackReason?

    /// The LLM's raw response, verbatim. Populated only for
    /// `.extractionSucceeded` — the whole reason this field exists is
    /// telling "the model found nothing" apart from "the model found
    /// plenty and the sanitizer rejected all of it".
    public let rawResponse: String?
    /// Every sanitizer rejection for this extraction, term + reason.
    /// Populated only for `.extractionSucceeded`.
    public let dropped: [ScreenContextDroppedTerm]
    /// The keywords actually applied to the engine by this refresh.
    /// Empty for every outcome that clears (or never sets) keywords,
    /// including `.superseded` — a superseded refresh's keywords, by
    /// definition, never reached the engine.
    public let appliedKeywords: [String]

    public enum Outcome: Equatable, Sendable {
        /// Screen context is off. Keywords were cleared, not merely
        /// left un-set.
        case disabled
        /// The frontmost-app lookup, made BEFORE any read, found this
        /// app on the denylist — its window was never touched at all,
        /// not even by AX. This is the guarantee that a password
        /// manager is never read.
        case skippedPreReadDenylist
        /// The read already happened (the pre-read lookup and the
        /// read itself aren't atomic with each other), but the
        /// snapshot's own, authoritative bundle ID turned out to be
        /// denylisted. Defense in depth, not redundant with the
        /// pre-read gate.
        case skippedPostReadDenylist
        /// The window was read and came up empty: OCR recognized
        /// nothing in the screenshot, the Accessibility read found no
        /// text at all, or the installed strategy could not read the
        /// window by any route it has. `source` says which read it was,
        /// and is nil in the last case because no read got far enough
        /// to have a source.
        case noReadableWindowText
        /// This window's content was already in cache; no LLM call.
        case cacheHit
        /// The LLM round trip succeeded (whether or not it found any
        /// usable keywords).
        case extractionSucceeded
        /// The LLM round trip failed outright — provider unreachable,
        /// rate-limited, timed out, or a malformed response. Distinct
        /// from `extractionSucceeded` with zero keywords.
        case extractionFailed
        /// A newer focus event started (and, in most cases, finished)
        /// before this refresh's own apply could land — its result,
        /// whatever it would have been, was correctly discarded.
        case superseded
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        bundleID: String?,
        outcome: Outcome,
        source: ScreenContextSource? = nil,
        capturedText: String? = nil,
        capturedTextLength: Int? = nil,
        capturedImageBytes: Int? = nil,
        capturedImagePixelSize: ScreenContextPixelSize? = nil,
        fallbackReason: ScreenContextFallbackReason? = nil,
        rawResponse: String? = nil,
        dropped: [ScreenContextDroppedTerm] = [],
        appliedKeywords: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.bundleID = bundleID
        self.outcome = outcome
        self.source = source
        self.capturedText = capturedText
        self.capturedTextLength = capturedTextLength
        self.capturedImageBytes = capturedImageBytes
        self.capturedImagePixelSize = capturedImagePixelSize
        self.fallbackReason = fallbackReason
        self.rawResponse = rawResponse
        self.dropped = dropped
        self.appliedKeywords = appliedKeywords
    }
}
