import Foundation
import Testing
@testable import HowlCore

@Suite("Screen text similarity — normalization")
struct ScreenTextNormalizationTests {
    @Test("splits on non-alphanumerics and lowercases")
    func splits_and_lowercases() {
        #expect(ScreenTextSimilarity.tokens(in: "SpeakerGate, DeepFilterNet!") == ["speakergate", "deepfilternet"])
    }

    @Test("collapses repeats into a set — frequency carries no signal")
    func collapses_repeats() {
        // The whole reason this is a SET and not a count vector: the
        // consumer is a keyword list, where a term is present or
        // absent and saying it thirty times means nothing more than
        // saying it once.
        #expect(ScreenTextSimilarity.tokens(in: "alpha alpha alpha beta") == ["alpha", "beta"])
    }

    @Test("drops pure-digit tokens so clocks and counters are invisible")
    func drops_pure_digits() {
        // THE highest-frequency noise source on a periodic scan: a
        // clock, an unread badge, a progress percentage, a word count.
        // Every one of them is digits only, and every one of them
        // would otherwise force a re-extract on every single tick.
        let a = ScreenTextSimilarity.tokens(in: "Inbox 12 unread — 3:04 PM")
        let b = ScreenTextSimilarity.tokens(in: "Inbox 47 unread — 9:21 PM")
        #expect(a == b)
    }

    @Test("keeps alphanumeric identifiers that merely contain digits")
    func keeps_mixed_identifiers() {
        // Only PURE digits are noise. `utf8`, `sha256` and `v2` are
        // exactly the kind of term this feature exists to bias
        // whisper toward, and dropping them would defeat the point.
        let tokens = ScreenTextSimilarity.tokens(in: "sha256 utf8 v2 1234")
        #expect(tokens == ["sha256", "utf8", "v2"])
    }

    @Test("drops single characters, which are punctuation debris more often than terms")
    func drops_single_characters() {
        #expect(ScreenTextSimilarity.tokens(in: "a b go to") == ["go", "to"])
    }

    @Test("empty and whitespace-only text yields no tokens")
    func empty_text() {
        #expect(ScreenTextSimilarity.tokens(in: "").isEmpty)
        #expect(ScreenTextSimilarity.tokens(in: "   \n\t  ").isEmpty)
    }
}

@Suite("Screen text similarity — Jaccard")
struct ScreenTextJaccardTests {
    @Test("identical sets are 1.0")
    func identical() {
        let s: Set<String> = ["alpha", "beta"]
        #expect(ScreenTextSimilarity.jaccard(s, s) == 1.0)
    }

    @Test("disjoint sets are 0.0")
    func disjoint() {
        #expect(ScreenTextSimilarity.jaccard(["alpha"], ["beta"]) == 0.0)
    }

    @Test("partial overlap is intersection over union")
    func partial_overlap() {
        // {a,b,c} vs {b,c,d}: intersection 2, union 4.
        let value = ScreenTextSimilarity.jaccard(["a1", "b1", "c1"], ["b1", "c1", "d1"])
        #expect(abs(value - 0.5) < 1e-9)
    }

    @Test("two empty sets are identical, not undefined")
    func both_empty() {
        // 0/0. Defining this as 1.0 matters: two consecutive reads
        // that both came back empty ARE unchanged, and returning 0
        // would report a total content change and force a pointless
        // re-extract on every tick of a blank window.
        #expect(ScreenTextSimilarity.jaccard([], []) == 1.0)
    }

    @Test("one empty set against a populated one is a total change")
    func one_empty() {
        #expect(ScreenTextSimilarity.jaccard([], ["alpha"]) == 0.0)
        #expect(ScreenTextSimilarity.jaccard(["alpha"], []) == 0.0)
    }

    @Test("is symmetric")
    func symmetric() {
        let a: Set<String> = ["alpha", "beta", "gamma"]
        let b: Set<String> = ["beta", "delta"]
        #expect(ScreenTextSimilarity.jaccard(a, b) == ScreenTextSimilarity.jaccard(b, a))
    }

    @Test("a growing chat thread stays above a 0.95 gate until it has really moved on")
    func growing_thread_end_to_end() {
        // The motivating case for the whole gate, run end to end
        // through normalization: one new short message arriving in a
        // long thread must NOT trigger a re-extract.
        let base = (1...200).map { "term\($0)" }.joined(separator: " ")
        let plusOne = base + " acknowledged"
        #expect(ScreenTextSimilarity.jaccard(
            ScreenTextSimilarity.tokens(in: base),
            ScreenTextSimilarity.tokens(in: plusOne)
        ) > 0.99)

        // ...while scrolling to an entirely different section must.
        let elsewhere = (500...700).map { "term\($0)" }.joined(separator: " ")
        #expect(ScreenTextSimilarity.jaccard(
            ScreenTextSimilarity.tokens(in: base),
            ScreenTextSimilarity.tokens(in: elsewhere)
        ) < 0.05)
    }
}

@Suite("Screen context similarity cache")
struct ScreenContextSimilarityCacheTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("returns nothing for a window it has never seen")
    func unseen_window() {
        let cache = ScreenContextSimilarityCache()
        #expect(cache.hit(bundleID: "com.a", windowTitle: "T", tokens: ["alpha"], now: t0, threshold: 0.95) == nil)
    }

    @Test("returns the stored keywords when the content is similar enough")
    func near_hit() {
        let cache = ScreenContextSimilarityCache()
        cache.store(tokens: ["alpha", "beta"], keywords: ["Alpha"], bundleID: "com.a", windowTitle: "T", now: t0)
        let hit = cache.hit(bundleID: "com.a", windowTitle: "T", tokens: ["alpha", "beta"], now: t0, threshold: 0.95)
        #expect(hit?.keywords == ["Alpha"])
        #expect(hit?.similarity == 1.0)
    }

    @Test("returns nothing when the content has moved past the threshold")
    func past_threshold() {
        let cache = ScreenContextSimilarityCache()
        cache.store(tokens: ["alpha", "beta"], keywords: ["Alpha"], bundleID: "com.a", windowTitle: "T", now: t0)
        #expect(cache.hit(bundleID: "com.a", windowTitle: "T", tokens: ["gamma", "delta"], now: t0, threshold: 0.95) == nil)
    }

    @Test("the threshold boundary is inclusive")
    func boundary_inclusive() {
        let cache = ScreenContextSimilarityCache()
        // {a,b,c,d} vs {a,b,c} — intersection 3, union 4, exactly 0.75.
        cache.store(tokens: ["aa", "bb", "cc", "dd"], keywords: ["K"], bundleID: "com.a", windowTitle: "T", now: t0)
        #expect(cache.hit(bundleID: "com.a", windowTitle: "T", tokens: ["aa", "bb", "cc"], now: t0, threshold: 0.75) != nil)
        #expect(cache.hit(bundleID: "com.a", windowTitle: "T", tokens: ["aa", "bb", "cc"], now: t0, threshold: 0.76) == nil)
    }

    @Test("a different window of the same app is a different entry")
    func distinct_windows() {
        let cache = ScreenContextSimilarityCache()
        cache.store(tokens: ["alpha"], keywords: ["Alpha"], bundleID: "com.a", windowTitle: "One", now: t0)
        #expect(cache.hit(bundleID: "com.a", windowTitle: "Two", tokens: ["alpha"], now: t0, threshold: 0.95) == nil)
    }

    @Test("entries expire on the TTL, inclusive at the boundary")
    func ttl() {
        let cache = ScreenContextSimilarityCache(ttl: 600)
        cache.store(tokens: ["alpha"], keywords: ["Alpha"], bundleID: "com.a", windowTitle: "T", now: t0)
        let atTTL = t0.addingTimeInterval(600)
        #expect(cache.hit(bundleID: "com.a", windowTitle: "T", tokens: ["alpha"], now: atTTL, threshold: 0.95) != nil)
        let pastTTL = t0.addingTimeInterval(600.001)
        #expect(cache.hit(bundleID: "com.a", windowTitle: "T", tokens: ["alpha"], now: pastTTL, threshold: 0.95) == nil)
    }

    @Test("storing re-anchors the reference, so slow drift still crosses the threshold")
    func anchored_to_last_extraction() {
        // THE bug this design exists to avoid. Compare each tick
        // against the PREVIOUS TICK and a window drifting a little at
        // a time never re-extracts, however far it wanders. Anchoring
        // to the content that produced the current keywords makes
        // those small deltas accumulate against a fixed reference.
        let cache = ScreenContextSimilarityCache()
        var tokens = Set((1...100).map { "term\($0)" })
        cache.store(tokens: tokens, keywords: ["K"], bundleID: "com.a", windowTitle: "T", now: t0)

        // Drift by five terms per tick. Each individual step is a ~5%
        // change — under the gate on its own.
        var crossedAt: Int?
        for tick in 1...20 {
            for i in 0..<5 {
                tokens.remove("term\(tick * 5 - i)")
                tokens.insert("new\(tick * 5 - i)")
            }
            if cache.hit(bundleID: "com.a", windowTitle: "T", tokens: tokens, now: t0, threshold: 0.95) == nil {
                crossedAt = tick
                break
            }
        }
        // It must cross, and early — not "eventually" and not never.
        #expect(crossedAt != nil)
        #expect((crossedAt ?? .max) <= 3)
    }

    @Test("evicts least-recently-used entries past the limit")
    func lru_eviction() {
        let cache = ScreenContextSimilarityCache(limit: 2)
        cache.store(tokens: ["alpha"], keywords: ["A"], bundleID: "com.a", windowTitle: "One", now: t0)
        cache.store(tokens: ["beta"], keywords: ["B"], bundleID: "com.a", windowTitle: "Two", now: t0)
        // Touch "One" so "Two" becomes the least recently used.
        _ = cache.hit(bundleID: "com.a", windowTitle: "One", tokens: ["alpha"], now: t0, threshold: 0.95)
        cache.store(tokens: ["gamma"], keywords: ["C"], bundleID: "com.a", windowTitle: "Three", now: t0)

        #expect(cache.hit(bundleID: "com.a", windowTitle: "One", tokens: ["alpha"], now: t0, threshold: 0.95) != nil)
        #expect(cache.hit(bundleID: "com.a", windowTitle: "Three", tokens: ["gamma"], now: t0, threshold: 0.95) != nil)
        #expect(cache.hit(bundleID: "com.a", windowTitle: "Two", tokens: ["beta"], now: t0, threshold: 0.95) == nil)
    }
}
