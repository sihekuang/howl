import Foundation
import Testing
@testable import HowlCore

// The periodic scan turned a cheap trigger into a stream of LLM calls
// (83 Ollama round-trips in 31 minutes, up to three in flight at once,
// six of them timing out at 60s — see docs/decisions.md 2026-09-08).
// Two rules fix that, and these tests pin both:
//
//  1. At most ONE extraction is ever in flight. A refresh for the same
//     window joins it; a refresh for a different window cancels it —
//     on the Go side too, since the C call cannot observe Swift's
//     cooperative cancellation.
//  2. A window is re-extracted at most once per `minExtractionInterval`,
//     however much its content moved. Keywords that are a minute old
//     are still the right keywords for a window the user is reading.

private final class SwitchableSource: ScreenContentSource, @unchecked Sendable {
    private let lock = NSLock()
    private var bundleID: String
    private var windowTitle: String
    private var windowID: UInt32?
    private var text: String

    init(bundleID: String = "com.a", windowTitle: String = "Doc", windowID: UInt32? = nil, text: String) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.text = text
    }

    func set(bundleID: String? = nil, windowTitle: String? = nil, windowID: UInt32?? = nil, text: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let bundleID { self.bundleID = bundleID }
        if let windowTitle { self.windowTitle = windowTitle }
        if let windowID { self.windowID = windowID }
        if let text { self.text = text }
    }

    private func snapshot() -> ScreenContent {
        lock.lock(); defer { lock.unlock() }
        return .text(WindowSnapshot(
            bundleID: bundleID, windowTitle: windowTitle, windowID: windowID, text: text, source: .screenshot
        ))
    }

    func read() async -> ScreenContent? { snapshot() }
}

/// An extractor that does not answer until the test lets it, so a
/// second refresh can be started while the first is mid-LLM-call.
/// `cancel()` mirrors what the Go side does when its context is
/// cancelled: the blocked call returns nil, immediately.
private final class GatedExtractor: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<ScreenKeywordExtraction?, Never>] = []
    private var _calls = 0
    private var _cancels = 0
    private var _applied: [[String]] = []
    var keywords: [String] = ["Alpha"]

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var cancels: Int { lock.lock(); defer { lock.unlock() }; return _cancels }
    var applied: [[String]] { lock.lock(); defer { lock.unlock() }; return _applied }

    func extractText(_ text: String) async -> ScreenKeywordExtraction? {
        await withCheckedContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            _calls += 1
            pending.append(continuation)
        }
    }

    /// Answer every blocked call with the stubbed keywords.
    func release() {
        lock.lock()
        let waiting = pending
        pending = []
        let keywords = self.keywords
        lock.unlock()
        for c in waiting {
            c.resume(returning: ScreenKeywordExtraction(raw: keywords.joined(separator: ", "), keywords: keywords, dropped: []))
        }
    }

    /// What the coordinator calls to abort the Go-side request.
    func cancel() {
        lock.lock()
        _cancels += 1
        let waiting = pending
        pending = []
        lock.unlock()
        for c in waiting { c.resume(returning: nil) }
    }

    private func recordApply(_ keywords: [String]) {
        lock.lock(); defer { lock.unlock() }
        _applied.append(keywords)
    }

    func apply(_ keywords: [String]) async { recordApply(keywords) }

    func waitForCalls(_ n: Int) async {
        for _ in 0..<200 {
            if calls >= n { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func waitForCancels(_ n: Int) async {
        for _ in 0..<200 {
            if cancels >= n { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor Recorder {
    private(set) var activities: [ScreenContextActivity] = []
    func record(_ a: ScreenContextActivity) { activities.append(a) }
}

private final class FrontmostBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: String? = "com.a"
    var id: String? {
        get { lock.lock(); defer { lock.unlock() }; return _id }
        set { lock.lock(); defer { lock.unlock() }; _id = newValue }
    }
}

private func makeCoordinator(
    source: SwitchableSource,
    extractor: GatedExtractor,
    recorder: Recorder,
    frontmost: FrontmostBox = FrontmostBox(),
    minExtractionInterval: TimeInterval = ScreenContextLimits.minExtractionInterval
) -> ScreenContextCoordinator {
    ScreenContextCoordinator(
        source: source,
        cache: ScreenContextCache(),
        similarityCache: ScreenContextSimilarityCache(),
        similarityThreshold: { ScreenContextLimits.defaultSimilarityThreshold },
        minExtractionInterval: minExtractionInterval,
        denylist: { ScreenContextDenylist(userAdditions: ["com.denied"]) },
        isEnabled: { true },
        frontmostBundleID: { frontmost.id },
        extractImage: { _ in .failed },
        extractText: { await extractor.extractText($0) },
        cancelExtraction: { extractor.cancel() },
        apply: { await extractor.apply($0) },
        onActivity: { await recorder.record($0) }
    )
}

private func body(_ terms: Int, prefix: String = "term") -> String {
    (1...terms).map { "\(prefix)\($0)" }.joined(separator: " ")
}

private let t0 = Date(timeIntervalSince1970: 4_000_000)

@Suite("Screen context — one extraction in flight")
struct ScreenContextExtractionOverlapTests {

    @Test func a_tick_for_the_same_window_joins_the_extraction_already_in_flight() async {
        let source = SwitchableSource(text: body(100))
        let extractor = GatedExtractor()
        let recorder = Recorder()
        let coordinator = makeCoordinator(source: source, extractor: extractor, recorder: recorder)

        let first = Task { await coordinator.refresh(now: t0) }
        await extractor.waitForCalls(1)
        // The periodic tick lands while the LLM is still thinking.
        let second = Task { await coordinator.refresh(now: t0.addingTimeInterval(15)) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        extractor.release()
        await first.value
        await second.value

        #expect(extractor.calls == 1, "the tick must ride the in-flight call, not start another")
        #expect(extractor.cancels == 0)
        #expect(extractor.applied.contains(["Alpha"]), "the joined result still reaches the engine")
        let outcomes = await recorder.activities.map(\.outcome)
        #expect(outcomes.contains(.extractionSucceeded))
    }

    @Test func a_refresh_for_a_different_window_cancels_the_in_flight_extraction() async {
        let source = SwitchableSource(text: body(100))
        let extractor = GatedExtractor()
        let recorder = Recorder()
        let coordinator = makeCoordinator(source: source, extractor: extractor, recorder: recorder)

        let first = Task { await coordinator.refresh(now: t0) }
        await extractor.waitForCalls(1)
        source.set(windowTitle: "Other", text: body(100, prefix: "other"))
        let second = Task { await coordinator.refresh(now: t0.addingTimeInterval(2)) }
        await extractor.waitForCalls(2)
        extractor.release()
        await first.value
        await second.value

        #expect(extractor.cancels == 1, "the stale window's request must be aborted on the Go side")
        #expect(extractor.calls == 2)
        let outcomes = await recorder.activities.map(\.outcome)
        #expect(outcomes.contains(.extractionCancelled), "a cancelled extraction is not a failure")
        #expect(!outcomes.contains(.extractionFailed))
    }

    @Test func a_refresh_that_ends_without_extracting_cancels_a_stale_in_flight_extraction() async {
        let source = SwitchableSource(text: body(100))
        let extractor = GatedExtractor()
        let recorder = Recorder()
        let frontmost = FrontmostBox()
        let coordinator = makeCoordinator(source: source, extractor: extractor, recorder: recorder, frontmost: frontmost)

        let first = Task { await coordinator.refresh(now: t0) }
        await extractor.waitForCalls(1)
        // Focus moves to a denylisted app: this refresh stops before
        // any read, but the LLM is still burning GPU on a window the
        // user has left.
        frontmost.id = "com.denied"
        await coordinator.refresh(now: t0.addingTimeInterval(2))
        await extractor.waitForCancels(1)
        await first.value

        #expect(extractor.cancels == 1)
        #expect(extractor.calls == 1)
    }
}

@Suite("Screen context — extraction rate limit")
struct ScreenContextExtractionRateLimitTests {

    @Test func a_window_is_not_re_extracted_within_the_minimum_interval_however_much_it_changed() async {
        let source = SwitchableSource(text: body(100))
        let extractor = GatedExtractor()
        let recorder = Recorder()
        let coordinator = makeCoordinator(source: source, extractor: extractor, recorder: recorder, minExtractionInterval: 60)

        let first = Task { await coordinator.refresh(now: t0) }
        await extractor.waitForCalls(1)
        extractor.release()
        await first.value
        #expect(extractor.calls == 1)

        // Entirely different content, well under the threshold.
        source.set(text: body(100, prefix: "moved"))
        await coordinator.refresh(now: t0.addingTimeInterval(30))

        #expect(extractor.calls == 1, "30s after an extraction the window is not re-read")
        let last = await recorder.activities.last
        #expect(last?.outcome == .extractionRateLimited)
        #expect(last?.appliedKeywords == ["Alpha"], "the minute-old keywords are re-applied")
        #expect((last?.similarity ?? 1) < 0.1, "the score is still recorded for tuning")
    }

    @Test func the_interval_expiring_lets_the_changed_window_extract_again() async {
        let source = SwitchableSource(text: body(100))
        let extractor = GatedExtractor()
        let recorder = Recorder()
        let coordinator = makeCoordinator(source: source, extractor: extractor, recorder: recorder, minExtractionInterval: 60)

        let first = Task { await coordinator.refresh(now: t0) }
        await extractor.waitForCalls(1)
        extractor.release()
        await first.value

        source.set(text: body(100, prefix: "moved"))
        await coordinator.refresh(now: t0.addingTimeInterval(30))
        #expect(extractor.calls == 1)

        let third = Task { await coordinator.refresh(now: t0.addingTimeInterval(61)) }
        await extractor.waitForCalls(2)
        extractor.release()
        await third.value
        #expect(extractor.calls == 2, "once the interval has passed the moved content is read")
    }

    @Test func a_rate_limited_refresh_does_not_move_the_similarity_anchor() async {
        let source = SwitchableSource(text: body(100))
        let extractor = GatedExtractor()
        let recorder = Recorder()
        let coordinator = makeCoordinator(source: source, extractor: extractor, recorder: recorder, minExtractionInterval: 60)

        let first = Task { await coordinator.refresh(now: t0) }
        await extractor.waitForCalls(1)
        extractor.release()
        await first.value

        let moved = body(100, prefix: "moved")
        source.set(text: moved)
        await coordinator.refresh(now: t0.addingTimeInterval(30))
        #expect(extractor.calls == 1)

        // Same moved content again, past the interval. Had the
        // rate-limited pass re-anchored to `moved`, this would score
        // 1.0 and be waved through as unchanged — with keywords that
        // were extracted from the ORIGINAL text.
        let third = Task { await coordinator.refresh(now: t0.addingTimeInterval(61)) }
        await extractor.waitForCalls(2)
        extractor.release()
        await third.value
        #expect(extractor.calls == 2)
        let last = await recorder.activities.last
        #expect(last?.outcome == .extractionSucceeded)
    }

    @Test func a_different_window_extracts_immediately_regardless_of_the_interval() async {
        let source = SwitchableSource(text: body(100))
        let extractor = GatedExtractor()
        let recorder = Recorder()
        let coordinator = makeCoordinator(source: source, extractor: extractor, recorder: recorder, minExtractionInterval: 60)

        let first = Task { await coordinator.refresh(now: t0) }
        await extractor.waitForCalls(1)
        extractor.release()
        await first.value

        source.set(windowTitle: "Other", text: body(100, prefix: "other"))
        let second = Task { await coordinator.refresh(now: t0.addingTimeInterval(5)) }
        await extractor.waitForCalls(2)
        extractor.release()
        await second.value
        #expect(extractor.calls == 2, "the limit is per window, never global")
    }
}

// Terminals retitle on every command and browsers on every tab, so a
// title is a poor name for "the same window". Where the reader can
// supply the CGWindowID, that is the identity the caches, the rate
// limit and the in-flight join key on — and a retitle is just content
// moving inside one window, which is the case the gate exists for.
@Suite("Screen context — window identity")
struct ScreenContextWindowIdentityTests {

    @Test func a_retitled_window_with_the_same_id_is_still_rate_limited() async {
        let source = SwitchableSource(windowTitle: "make build — ~/howl", windowID: 4242, text: body(100))
        let extractor = GatedExtractor()
        let recorder = Recorder()
        let coordinator = makeCoordinator(source: source, extractor: extractor, recorder: recorder, minExtractionInterval: 60)

        let first = Task { await coordinator.refresh(now: t0) }
        await extractor.waitForCalls(1)
        extractor.release()
        await first.value

        // Same terminal, next command: new title, new content.
        source.set(windowTitle: "go test ./... — ~/howl", text: body(100, prefix: "moved"))
        await coordinator.refresh(now: t0.addingTimeInterval(15))

        #expect(extractor.calls == 1, "a retitle is not a new window")
        let last = await recorder.activities.last
        #expect(last?.outcome == .extractionRateLimited)
    }

    @Test func a_retitled_window_with_the_same_id_joins_the_in_flight_extraction() async {
        let source = SwitchableSource(windowTitle: "A", windowID: 4242, text: body(100))
        let extractor = GatedExtractor()
        let recorder = Recorder()
        let coordinator = makeCoordinator(source: source, extractor: extractor, recorder: recorder)

        let first = Task { await coordinator.refresh(now: t0) }
        await extractor.waitForCalls(1)
        source.set(windowTitle: "B")
        let second = Task { await coordinator.refresh(now: t0.addingTimeInterval(2)) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        extractor.release()
        await first.value
        await second.value

        #expect(extractor.calls == 1)
        #expect(extractor.cancels == 0)
    }

    @Test func without_a_window_id_the_title_still_tells_windows_apart() async {
        let source = SwitchableSource(windowTitle: "A", windowID: nil, text: body(100))
        let extractor = GatedExtractor()
        let recorder = Recorder()
        let coordinator = makeCoordinator(source: source, extractor: extractor, recorder: recorder, minExtractionInterval: 60)

        let first = Task { await coordinator.refresh(now: t0) }
        await extractor.waitForCalls(1)
        extractor.release()
        await first.value

        source.set(windowTitle: "B", text: body(100, prefix: "other"))
        let second = Task { await coordinator.refresh(now: t0.addingTimeInterval(15)) }
        await extractor.waitForCalls(2)
        extractor.release()
        await second.value
        #expect(extractor.calls == 2)
    }

    @Test func the_window_key_prefers_the_id_over_the_title() {
        let byID = WindowSnapshot(bundleID: "com.a", windowTitle: "x", windowID: 7, text: "t", source: .accessibility)
        let retitled = WindowSnapshot(bundleID: "com.a", windowTitle: "y", windowID: 7, text: "t", source: .accessibility)
        let byTitle = WindowSnapshot(bundleID: "com.a", windowTitle: "x", text: "t", source: .accessibility)
        #expect(byID.windowKey == retitled.windowKey)
        #expect(byID.windowKey != byTitle.windowKey)
        #expect(byTitle.windowKey != WindowSnapshot(bundleID: "com.a", windowTitle: "y", text: "t", source: .accessibility).windowKey)
    }
}
