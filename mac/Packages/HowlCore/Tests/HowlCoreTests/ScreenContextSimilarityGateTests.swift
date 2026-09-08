import Foundation
import Testing
@testable import HowlCore

/// A source whose reading can be changed between refreshes — which the
/// shared `StubSource` deliberately cannot do, since it exists to prove
/// routing rather than to simulate a window whose content moves.
private final class MutableSource: ScreenContentSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _text: String
    private let bundleID: String
    private let windowTitle: String
    private var _readCount = 0
    var readCount: Int { withLock { _readCount } }

    init(bundleID: String = "com.a", windowTitle: String = "Doc", text: String) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self._text = text
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func setText(_ text: String) {
        withLock { _text = text }
    }

    /// Synchronous so the lock is never held across a suspension —
    /// `NSLock` is unavailable from async contexts for exactly that
    /// reason.
    private func nextReading() -> ScreenContent {
        withLock {
            _readCount += 1
            return .text(WindowSnapshot(
                bundleID: bundleID, windowTitle: windowTitle, text: _text, source: .screenshot
            ))
        }
    }

    func read() async -> ScreenContent? { nextReading() }
}

private final class CountingExtractor: @unchecked Sendable {
    private let lock = NSLock()
    private var _textCalls = 0
    private var _applied: [[String]] = []
    var textCalls: Int { withLock { _textCalls } }
    var applied: [[String]] { withLock { _applied } }
    var stubbedKeywords: [String] = ["Alpha"]

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func recordExtract() -> ScreenKeywordExtraction {
        withLock {
            _textCalls += 1
            return ScreenKeywordExtraction(
                raw: stubbedKeywords.joined(separator: ", "), keywords: stubbedKeywords, dropped: []
            )
        }
    }

    func extractText(_ text: String) async -> ScreenKeywordExtraction? { recordExtract() }

    func apply(_ keywords: [String]) async {
        withLock { _applied.append(keywords) }
    }
}

private actor Recorder {
    private(set) var activities: [ScreenContextActivity] = []
    func record(_ a: ScreenContextActivity) { activities.append(a) }
}

private func makeGatedCoordinator(
    source: MutableSource,
    extractor: CountingExtractor,
    recorder: Recorder,
    threshold: Double = ScreenContextLimits.defaultSimilarityThreshold,
    // Off by default: these tests refresh one window seconds apart to
    // exercise the GATE, and the per-window rate limit would answer
    // first. It has its own suite (ScreenContextExtractionLoadTests).
    minExtractionInterval: TimeInterval = 0
) -> ScreenContextCoordinator {
    ScreenContextCoordinator(
        source: source,
        cache: ScreenContextCache(),
        similarityCache: ScreenContextSimilarityCache(),
        similarityThreshold: { threshold },
        minExtractionInterval: minExtractionInterval,
        denylist: { ScreenContextDenylist(userAdditions: []) },
        isEnabled: { true },
        frontmostBundleID: { "com.a" },
        extractImage: { _ in .failed },
        extractText: { await extractor.extractText($0) },
        apply: { await extractor.apply($0) },
        onActivity: { await recorder.record($0) }
    )
}

/// A long body of text plus `extra` distinct tokens appended — the
/// shape of "the same document with a bit more in it".
private func body(_ terms: Int, extra: [String] = []) -> String {
    ((1...terms).map { "term\($0)" } + extra).joined(separator: " ")
}

private let t0 = Date(timeIntervalSince1970: 3_000_000)

@Suite("Screen context similarity gate — in the refresh pipeline")
struct ScreenContextSimilarityGateTests {

    @Test("a trivially changed window is not re-extracted")
    func near_hit_skips_extraction() async {
        let source = MutableSource(text: body(200))
        let extractor = CountingExtractor()
        let recorder = Recorder()
        let c = makeGatedCoordinator(source: source, extractor: extractor, recorder: recorder)

        await c.refresh(now: t0)
        #expect(extractor.textCalls == 1)

        // One new word in a 200-term window: ~0.5% of the token set.
        source.setText(body(200, extra: ["acknowledged"]))
        await c.refresh(now: t0)

        // The window WAS read again — the gate is not a read cache —
        // but no LLM call was made.
        #expect(source.readCount == 2)
        #expect(extractor.textCalls == 1)

        let activities = await recorder.activities
        #expect(activities.last?.outcome == .unchangedContent)
        #expect((activities.last?.similarity ?? 0) > 0.99)
    }

    @Test("a near-hit still re-applies the keywords to the engine")
    func near_hit_reapplies() async {
        // Not a no-op: `refresh` is also reached by focusing back onto
        // this window, where the engine may currently hold some other
        // app's keywords. Skipping the extraction must not mean
        // skipping the apply.
        let source = MutableSource(text: body(200))
        let extractor = CountingExtractor()
        let c = makeGatedCoordinator(source: source, extractor: extractor, recorder: Recorder())

        await c.refresh(now: t0)
        source.setText(body(200, extra: ["acknowledged"]))
        await c.refresh(now: t0)

        #expect(extractor.applied == [["Alpha"], ["Alpha"]])
    }

    @Test("a substantially changed window is re-extracted")
    func real_change_re_extracts() async {
        let source = MutableSource(text: body(200))
        let extractor = CountingExtractor()
        let recorder = Recorder()
        let c = makeGatedCoordinator(source: source, extractor: extractor, recorder: recorder)

        await c.refresh(now: t0)
        // Scrolled somewhere else entirely.
        source.setText((500...700).map { "term\($0)" }.joined(separator: " "))
        extractor.stubbedKeywords = ["Beta"]
        await c.refresh(now: t0)

        #expect(extractor.textCalls == 2)
        let activities = await recorder.activities
        #expect(activities.last?.outcome == .extractionSucceeded)
        #expect(extractor.applied.last == ["Beta"])
    }

    @Test("the score is recorded on the re-extract too, not only on the skip")
    func score_recorded_below_threshold() async {
        // Both halves of the distribution have to be visible or the
        // threshold cannot be tuned from real windows — you would only
        // ever see the scores that were already above it.
        let source = MutableSource(text: body(200))
        let extractor = CountingExtractor()
        let recorder = Recorder()
        let c = makeGatedCoordinator(source: source, extractor: extractor, recorder: recorder)

        await c.refresh(now: t0)
        source.setText((500...700).map { "term\($0)" }.joined(separator: " "))
        await c.refresh(now: t0)

        let activities = await recorder.activities
        // First sight of a window has nothing to compare against.
        #expect(activities.first?.similarity == nil)
        let last = activities.last
        #expect(last?.outcome == .extractionSucceeded)
        #expect(last?.similarity != nil)
        #expect((last?.similarity ?? 1) < ScreenContextLimits.defaultSimilarityThreshold)
    }

    @Test("slow drift accumulates against the anchor and eventually re-extracts")
    func drift_crosses_the_threshold() async {
        // The ratchet bug, at the pipeline level. Each tick changes
        // the window by only ~2% — under the gate in isolation — so a
        // gate anchored to the PREVIOUS TICK would never fire, however
        // far the window wandered. Anchored to the last EXTRACTION,
        // the deltas accumulate.
        let source = MutableSource(text: body(200))
        let extractor = CountingExtractor()
        let c = makeGatedCoordinator(source: source, extractor: extractor, recorder: Recorder())

        await c.refresh(now: t0)
        #expect(extractor.textCalls == 1)

        var replaced = 0
        for tick in 1...12 {
            replaced += 4
            // Drop 4 of the original terms, add 4 new ones.
            let kept = (replaced + 1...200).map { "term\($0)" }
            let added = (1...replaced).map { "fresh\($0)" }
            source.setText((kept + added).joined(separator: " "))
            await c.refresh(now: t0)
            if extractor.textCalls == 2 {
                // Crossed. It must take more than one tick (otherwise
                // the gate is not gating) and not many (otherwise it
                // is a ratchet).
                #expect(tick > 1)
                #expect(tick <= 6)
                return
            }
        }
        Issue.record("drifted 12 ticks without ever re-extracting — the gate is a ratchet")
    }

    @Test("an exact repeat is a cache hit, not a similarity hit")
    func exact_repeat_prefers_the_exact_cache() async {
        // The similarity layer is a SECOND chance. An unchanged window
        // must still take the existing exact-hash path, so the
        // inspector keeps telling the two apart.
        let source = MutableSource(text: body(200))
        let extractor = CountingExtractor()
        let recorder = Recorder()
        let c = makeGatedCoordinator(source: source, extractor: extractor, recorder: recorder)

        await c.refresh(now: t0)
        await c.refresh(now: t0)

        #expect(extractor.textCalls == 1)
        let activities = await recorder.activities
        #expect(activities.last?.outcome == .cacheHit)
        #expect(activities.last?.similarity == nil)
    }

    @Test("a failed extraction does not re-anchor the gate")
    func failure_does_not_anchor() async {
        // Anchoring on failure would be the worst of both worlds: no
        // keywords applied, but the next tick compares against content
        // that never produced any, so the gate could suppress the
        // retry that would have fixed it.
        let source = MutableSource(text: body(200))
        let extractor = CountingExtractor()
        let recorder = Recorder()
        let c = ScreenContextCoordinator(
            source: source,
            cache: ScreenContextCache(),
            similarityCache: ScreenContextSimilarityCache(),
            similarityThreshold: { ScreenContextLimits.defaultSimilarityThreshold },
            denylist: { ScreenContextDenylist(userAdditions: []) },
            isEnabled: { true },
            frontmostBundleID: { "com.a" },
            extractImage: { _ in .failed },
            // Always fails.
            extractText: { _ in
                await extractor.apply([])
                return nil
            },
            apply: { _ in },
            onActivity: { await recorder.record($0) }
        )

        await c.refresh(now: t0)
        source.setText(body(200, extra: ["acknowledged"]))
        await c.refresh(now: t0)

        let activities = await recorder.activities
        // Second refresh must have tried again rather than been
        // silenced by a gate anchored on the failure.
        #expect(activities.count == 2)
        #expect(activities.allSatisfy { $0.outcome == .extractionFailed })
    }

    @Test("a different window of the same app is judged on its own content")
    func per_window_anchor() async {
        let source = MutableSource(windowTitle: "One", text: body(200))
        let extractor = CountingExtractor()
        let c = makeGatedCoordinator(source: source, extractor: extractor, recorder: Recorder())
        await c.refresh(now: t0)

        // Same app, same text, DIFFERENT window. Nothing is anchored
        // for it, so it must extract rather than inherit its sibling's
        // keywords.
        let other = MutableSource(windowTitle: "Two", text: body(200))
        let c2 = makeGatedCoordinator(source: other, extractor: extractor, recorder: Recorder())
        await c2.refresh(now: t0)
        #expect(extractor.textCalls == 2)
    }
}

@Suite("Screen context activity coalescing")
struct ScreenContextSkipCoalescingTests {

    /// A source that must never be read — every test here denylists
    /// the frontmost app, so reaching this is itself the failure.
    private final class NeverReadSource: ScreenContentSource, @unchecked Sendable {
        func read() async -> ScreenContent? { nil }
    }

    private func denylistedCoordinator(recorder: Recorder) -> ScreenContextCoordinator {
        ScreenContextCoordinator(
            source: NeverReadSource(),
            cache: ScreenContextCache(),
            denylist: { ScreenContextDenylist(userAdditions: ["com.howl.app"]) },
            isEnabled: { true },
            frontmostBundleID: { "com.howl.app" },
            extractImage: { _ in .failed },
            extractText: { _ in nil },
            apply: { _ in },
            onActivity: { await recorder.record($0) }
        )
    }

    @Test("a repeating denylist skip for the same app records once, not once per tick")
    func repeated_skip_coalesces() async {
        // Without this, sitting on the Screen Context tab — a Howl
        // window, and Howl is denylisted — would evict the entire
        // 50-entry inspector history in about twelve minutes of
        // periodic scanning and fill it with identical rows.
        let recorder = Recorder()
        let c = denylistedCoordinator(recorder: recorder)
        for _ in 1...10 { await c.refresh(now: t0) }
        let activities = await recorder.activities
        #expect(activities.count == 1)
        #expect(activities.first?.outcome == .skippedPreReadDenylist)
    }

    @Test("a skip records again once something else has happened in between")
    func skip_records_again_after_other_activity() async {
        // Coalescing must not swallow the SECOND visit to a
        // denylisted app — only an unbroken run of identical ones.
        let recorder = Recorder()
        let denylisted = ScreenContextDenylist(userAdditions: ["com.howl.app"])
        let frontmost = FrontmostBox(bundleID: "com.howl.app")
        let source = MutableSource(bundleID: "com.other", windowTitle: "Doc", text: body(200))
        let extractor = CountingExtractor()
        let c = ScreenContextCoordinator(
            source: source,
            cache: ScreenContextCache(),
            denylist: { denylisted },
            isEnabled: { true },
            frontmostBundleID: { frontmost.value },
            extractImage: { _ in .failed },
            extractText: { await extractor.extractText($0) },
            apply: { await extractor.apply($0) },
            onActivity: { await recorder.record($0) }
        )

        await c.refresh(now: t0)          // skip (recorded)
        await c.refresh(now: t0)          // skip (coalesced away)
        frontmost.value = "com.other"
        await c.refresh(now: t0)          // real extraction
        frontmost.value = "com.howl.app"
        await c.refresh(now: t0)          // skip again — must record

        let outcomes = await recorder.activities.map(\.outcome)
        #expect(outcomes == [.skippedPreReadDenylist, .extractionSucceeded, .skippedPreReadDenylist])
    }

    @Test("consecutive unchanged-content ticks are NOT coalesced")
    func unchanged_content_still_records_each_tick() async {
        // Each one carries its own similarity score, and that
        // distribution is exactly what the threshold gets tuned from —
        // collapsing them would destroy the data the row exists for.
        let source = MutableSource(text: body(200))
        let extractor = CountingExtractor()
        let recorder = Recorder()
        let c = makeGatedCoordinator(source: source, extractor: extractor, recorder: recorder)

        await c.refresh(now: t0)
        for i in 1...4 {
            source.setText(body(200, extra: ["extra\(i)"]))
            await c.refresh(now: t0)
        }
        let outcomes = await recorder.activities.map(\.outcome)
        #expect(outcomes == [.extractionSucceeded, .unchangedContent, .unchangedContent,
                             .unchangedContent, .unchangedContent])
    }
}

/// Mutable frontmost-app stand-in for the coalescing tests.
private final class FrontmostBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    init(bundleID: String?) { _value = bundleID }
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
