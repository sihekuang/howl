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
