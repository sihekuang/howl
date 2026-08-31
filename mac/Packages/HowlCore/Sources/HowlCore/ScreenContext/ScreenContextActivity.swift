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

/// Which path actually fed the model on a given refresh — the answer
/// to "did the vision model see my screen, or did we fall back to
/// reading text?", which is otherwise unrecoverable from the record.
public enum ScreenContextSource: String, Equatable, Sendable {
    /// The primary path: a PNG screenshot of the focused window went
    /// straight to the provider's vision model.
    case screenshot
    /// The fallback path: the Accessibility API's text, used only
    /// after the provider reported that this model cannot accept
    /// images (`no_vision`). See `AXWindowTextReader`.
    case accessibility
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

    /// The window text actually read. Populated only on the
    /// `.accessibility` fallback path, and only for `.cacheHit`,
    /// `.extractionSucceeded`, and `.extractionFailed` — the three
    /// outcomes reached only after a real read succeeded.
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
        /// Nothing usable to send: the screenshot could not be taken
        /// (no Screen Recording permission, no on-screen window, the
        /// window vanished mid-capture), or — on the no-vision
        /// fallback — the AX read came up empty.
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
        self.rawResponse = rawResponse
        self.dropped = dropped
        self.appliedKeywords = appliedKeywords
    }
}
