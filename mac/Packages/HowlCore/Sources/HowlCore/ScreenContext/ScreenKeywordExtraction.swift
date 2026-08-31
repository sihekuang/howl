import Foundation

/// One term the sanitizer rejected, and why. Shared shape between
/// `ScreenKeywordExtraction.dropped` (what one extraction round trip
/// reported) and `ScreenContextActivity.dropped` (what the coordinator
/// recorded for display) — same source of truth, so they can't drift.
///
/// Mirrors Go's `screenctx.DroppedTerm`. `reason` is one of
/// `screenctx.Drop*` — `"empty" | "too_long" | "numeric" | "duplicate"
/// | "keyword_cap"` — but kept as a plain `String` rather than an enum
/// so an unrecognized future reason still decodes instead of failing
/// the whole response.
public struct ScreenContextDroppedTerm: Equatable, Sendable {
    public let term: String
    public let reason: String

    public init(term: String, reason: String) {
        self.term = term
        self.reason = reason
    }
}

/// The full result of one `CoreEngine.extractScreenKeywords` round
/// trip: the sanitized keywords the coordinator actually uses, plus
/// the diagnostic payload needed to explain them — the LLM's raw
/// response verbatim and every candidate the sanitizer rejected.
///
/// A nil `ScreenKeywordExtraction?` at the call site means the round
/// trip itself FAILED (provider unreachable, rate-limited, timed out,
/// malformed response) — distinct from a successful call that found
/// nothing (`keywords == []`). Mirrors Go's `screenctx.ExtractResult`.
public struct ScreenKeywordExtraction: Equatable, Sendable {
    /// The provider's response exactly as received. Never logged or
    /// written to disk anywhere in the shipped pipeline — this exists
    /// purely for the live diagnostic inspector.
    public let raw: String
    /// The sanitized, deduped, cap-bounded keywords — identical to
    /// what the previous (pre-diagnostic) `extractScreenKeywords`
    /// returned on success.
    public let keywords: [String]
    /// Every candidate the sanitizer rejected, and why.
    public let dropped: [ScreenContextDroppedTerm]

    public init(raw: String, keywords: [String], dropped: [ScreenContextDroppedTerm]) {
        self.raw = raw
        self.keywords = keywords
        self.dropped = dropped
    }
}

/// The outcome of one `CoreEngine.extractScreenKeywords(image:)` round
/// trip. Three-way rather than the text path's `ScreenKeywordExtraction?`
/// because the image path has a third answer that changes which path
/// the coordinator uses next, not merely whether this attempt worked.
///
/// Mirrors the `no_vision` key Go adds to the shared envelope — see
/// `core/cmd/libhowl/screenctx_image_export.go`.
public enum ScreenImageExtractionResult: Equatable, Sendable {
    /// The vision model answered. Payload is identical in shape and
    /// meaning to the text path's, so both converge on the same
    /// sanitize → prompt → apply chain.
    case success(ScreenKeywordExtraction)

    /// An ordinary failure — timeout, rate limit, auth, unreachable
    /// provider, malformed response, a bad image. Nothing is cached on
    /// either side of the ABI, so the caller keeps using the image
    /// path and simply gets no keywords this time.
    case failed

    /// This provider+model rejected the image, or silently dropped it
    /// (Go plants a canary token to catch backends that accept an
    /// `images` field and ignore it). Go caches that verdict in memory
    /// for the session, keyed on provider+model, so a settings change
    /// re-probes and a restart forgets.
    ///
    /// The caller's response is to fall back to the Accessibility text
    /// path for this refresh. NEVER returned for a timeout, rate limit
    /// or auth failure — those are `.failed`.
    case noVision
}
