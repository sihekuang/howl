import CryptoKit
import Foundation

/// How much a window's readable content has changed since the reading
/// that produced its current keywords.
///
/// This exists because of the periodic scan. `ScreenContextCache` keys
/// on an exact SHA256 of the captured text, which is the right answer
/// for a focus-driven refresh — you either returned to the same window
/// unchanged or you didn't. Under a timer it is close to useless: a
/// clock, an unread badge, a caret, a word count or one arriving chat
/// message all change the hash, so every tick would miss and every
/// miss is an LLM call.
///
/// The metric is EXACT Jaccard overlap of the normalized token set,
/// deliberately not a locality-sensitive hash. SimHash and MinHash
/// exist to avoid all-pairs comparison when searching a large corpus;
/// here N is one — a single fresh capture against a single stored
/// value for that window — so an LSH buys no search speedup and costs
/// the one thing this needs, since it reports "probably above
/// threshold" rather than the score itself. See
/// `docs/decisions.md` (2026-09-02).
///
/// A SET rather than a count vector, equally deliberately: the
/// consumer is a keyword list for whisper's `initial_prompt`, where a
/// term is present or absent. A word appearing thirty times instead of
/// three says nothing extra about which keywords the window deserves,
/// so weighting by frequency would only add noise — and set
/// intersection is cheaper than a cosine's two norms.
public enum ScreenTextSimilarity {
    /// The comparable content of a capture: distinct, lowercased,
    /// alphanumeric tokens.
    ///
    /// Three normalization rules, each earning its place against a
    /// specific source of spurious change:
    ///
    /// - **Lowercased** so a heading that renders in small-caps in one
    ///   theme and title-case in another is not a content change.
    /// - **Pure-digit tokens dropped.** This is the big one. Clocks,
    ///   unread counts, progress percentages, line numbers, view
    ///   counters and timestamps are the highest-frequency movers on
    ///   any real screen, they are digits and nothing else, and none
    ///   of them ever becomes a keyword. Tokens that merely *contain*
    ///   digits (`utf8`, `sha256`, `v2`) are kept — those are exactly
    ///   the identifiers this feature exists to bias whisper toward.
    /// - **Single characters dropped**, which after splitting are
    ///   punctuation debris and list bullets far more often than
    ///   words.
    public static func tokens(in text: String) -> Set<String> {
        var out: Set<String> = []
        // `unicodeScalars` + an explicit alphanumeric test rather than
        // `components(separatedBy:)`: OCR output is full of box-drawing
        // characters, arrows and emoji, and enumerating a fixed
        // separator set would have to anticipate all of them.
        var current = String.UnicodeScalarView()
        func flush() {
            defer { current = String.UnicodeScalarView() }
            guard current.count > 1 else { return }
            let token = String(current).lowercased()
            guard token.contains(where: { !$0.isNumber }) else { return }
            out.insert(token)
        }
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// Intersection over union: 1.0 for identical content, 0.0 for
    /// wholly disjoint.
    ///
    /// Two empty sets are 1.0, not undefined. That case is reached by
    /// consecutive reads of a window with nothing legible in it, and
    /// they genuinely are unchanged — answering 0 would report a total
    /// change and re-extract a blank window on every single tick.
    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1.0 }
        let intersection = a.intersection(b).count
        guard intersection > 0 else { return 0.0 }
        let union = a.count + b.count - intersection
        return Double(intersection) / Double(union)
    }
}

/// The second-chance layer behind `ScreenContextCache`: per window,
/// the token set of the content that produced the keywords currently
/// in force, and those keywords.
///
/// The reference is the content of the last EXTRACTION, never the last
/// capture, and that distinction is the whole design. Comparing each
/// tick against the previous tick means a window drifting a few
/// percent at a time never re-extracts — every individual step sits
/// under the gate while the content wanders arbitrarily far from what
/// the keywords describe. Anchoring to the reading that produced the
/// current keywords makes those small deltas accumulate against a
/// fixed point and cross the threshold on schedule. `store` is
/// therefore called only on a real extraction, and a near-hit
/// deliberately does NOT re-anchor.
///
/// Keyed on window identity (bundle ID + title) rather than on
/// content, which is exactly what `ScreenContextCache` warns against
/// doing on its own — serving stale keywords for a document the user
/// has scrolled is the failure that actually hurts dictation. The
/// similarity test is the mechanism that makes identity-keying safe
/// here: it is precisely what detects the scroll.
///
/// Retention note: this holds a set of distinct words from the user's
/// screen, where `ScreenContextCache` holds only a digest. That is a
/// real (if modest) step up in what lives in memory. It is already
/// exceeded by `ScreenContextActivityBuffer`, which holds full raw
/// window text for the inspector, and like that buffer this never
/// touches disk and never leaves the process.
public final class ScreenContextSimilarityCache: @unchecked Sendable {
    /// A near-hit: the keywords still in force, and how close the
    /// fresh capture was to the content that produced them.
    public struct Hit: Equatable, Sendable {
        public let keywords: [String]
        public let similarity: Double
    }

    private struct Entry {
        let tokens: Set<String>
        let keywords: [String]
        let storedAt: Date
        var lastUsedSequence: UInt64
    }

    private let limit: Int
    private let ttl: TimeInterval
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Recency counter. Same reasoning as `ScreenContextCache`'s: the
    /// caller supplies `now`, which tests hold fixed, so wall-clock
    /// time cannot break ties between entries touched at the same
    /// instant.
    private var sequence: UInt64 = 0

    public init(limit: Int = 32, ttl: TimeInterval = 600) {
        self.limit = limit
        self.ttl = ttl
    }

    /// Window identity. Hashed rather than concatenated so a window
    /// title — which can itself carry a document name, a URL or a
    /// customer's name — is not retained as readable text in a
    /// dictionary key.
    private func identity(bundleID: String, windowTitle: String) -> String {
        let digest = SHA256.hash(data: Data("\(bundleID)\u{0}\(windowTitle)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The keywords in force for this window, if the fresh capture is
    /// still within `threshold` of the content they came from.
    ///
    /// `threshold` is inclusive: a similarity exactly equal to it
    /// counts as unchanged.
    public func hit(
        bundleID: String, windowTitle: String, tokens: Set<String>,
        now: Date, threshold: Double
    ) -> Hit? {
        lock.lock()
        defer { lock.unlock() }
        let key = identity(bundleID: bundleID, windowTitle: windowTitle)
        guard var entry = entries[key] else { return nil }
        if now.timeIntervalSince(entry.storedAt) > ttl {
            entries.removeValue(forKey: key)
            return nil
        }
        let similarity = ScreenTextSimilarity.jaccard(entry.tokens, tokens)
        guard similarity >= threshold else { return nil }
        sequence += 1
        entry.lastUsedSequence = sequence
        entries[key] = entry
        return Hit(keywords: entry.keywords, similarity: similarity)
    }

    /// The raw overlap against this window's anchor, with no
    /// threshold applied — nil when there is no anchor yet or it has
    /// expired.
    ///
    /// Separate from `hit` because the two questions differ: `hit`
    /// asks "close enough to skip?", this asks "how close?", and the
    /// answer is wanted precisely when it was NOT close enough. Read
    /// it BEFORE `store`, which moves the anchor this measures
    /// against.
    ///
    /// Deliberately does not touch recency: measuring an entry is not
    /// using it, and letting a measurement count as a use would keep
    /// a window alive in the LRU on the strength of scans that never
    /// reused its keywords.
    public func score(
        bundleID: String, windowTitle: String, tokens: Set<String>, now: Date
    ) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[identity(bundleID: bundleID, windowTitle: windowTitle)] else { return nil }
        guard now.timeIntervalSince(entry.storedAt) <= ttl else { return nil }
        return ScreenTextSimilarity.jaccard(entry.tokens, tokens)
    }

    /// Re-anchor this window to the content that just produced
    /// `keywords`. Called only after a real extraction — see the type
    /// comment on why a near-hit must not call this.
    public func store(
        tokens: Set<String>, keywords: [String],
        bundleID: String, windowTitle: String, now: Date
    ) {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        entries[identity(bundleID: bundleID, windowTitle: windowTitle)] = Entry(
            tokens: tokens, keywords: keywords, storedAt: now, lastUsedSequence: sequence
        )
        guard entries.count > limit else { return }
        let ordered = entries.sorted { $0.value.lastUsedSequence < $1.value.lastUsedSequence }
        for (k, _) in ordered.prefix(entries.count - limit) {
            entries.removeValue(forKey: k)
        }
    }
}
