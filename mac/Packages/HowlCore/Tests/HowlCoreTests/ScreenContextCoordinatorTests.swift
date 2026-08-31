import Foundation
import Testing
@testable import HowlCore

private final class SpyEngine: @unchecked Sendable {
    var extractCalls = 0
    var lastExtractText = ""
    var setCalls: [[String]] = []
    // nil simulates an extraction FAILURE (provider unreachable,
    // rate-limited, timed out); [] simulates a successful call that
    // genuinely found nothing.
    var stubbedKeywords: [String]? = ["SpeakerGate"]
    var stubbedRaw = "SpeakerGate, DeepFilterNet"
    var stubbedDropped: [ScreenContextDroppedTerm] = []

    func extract(_ text: String) async -> ScreenKeywordExtraction? {
        extractCalls += 1
        lastExtractText = text
        guard let keywords = stubbedKeywords else { return nil }
        return ScreenKeywordExtraction(raw: stubbedRaw, keywords: keywords, dropped: stubbedDropped)
    }
    func set(_ keywords: [String]) async {
        setCalls.append(keywords)
    }
}

/// Collects every `ScreenContextActivity` an `onActivity` closure is
/// called with, in order. An `actor` (rather than an NSLock-guarded
/// class like the other spies here) since nothing about it needs to be
/// synchronous — `onActivity` is itself `async`.
private actor ActivityRecorder {
    private(set) var activities: [ScreenContextActivity] = []
    func record(_ activity: ScreenContextActivity) {
        activities.append(activity)
    }
}

private final class StubReader: WindowTextReader, @unchecked Sendable {
    let snapshot: WindowSnapshot?
    private let lock = NSLock()
    private var _readCount = 0
    var readCount: Int { withLock { _readCount } }

    init(snapshot: WindowSnapshot?) { self.snapshot = snapshot }

    func read() async -> WindowSnapshot? {
        recordRead()
        return snapshot
    }

    // NSLock's lock()/unlock() are unavailable directly from an async
    // context in this toolchain; hop through a plain sync method.
    private func recordRead() {
        withLock { _readCount += 1 }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Returns a fixed sequence of snapshots, one per `read()` call, then
/// nil. Simulates focus moving between windows across successive
/// coordinator refreshes — `StubReader` can't do this since it always
/// returns the same snapshot.
private final class SequenceReader: WindowTextReader, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [WindowSnapshot?]
    init(_ snapshots: [WindowSnapshot?]) { self.snapshots = snapshots }
    func read() async -> WindowSnapshot? { pop() }
    private func pop() -> WindowSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard !snapshots.isEmpty else { return nil }
        return snapshots.removeFirst()
    }
}

/// One-shot signal so a test can deterministically wait for something
/// to actually happen inside a concurrently-running Task, instead of
/// assuming it happened via a fixed sleep — a fixed-sleep assumption
/// is exactly the kind of scheduling-latency race that made the first
/// version of `scheduleRefresh_supersedes_a_slower_earlier_extraction`
/// flaky (Task creation-to-first-run latency is not bounded by wall
/// clock time in any way a test may assume).
private actor Signal {
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSet { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func set() {
        isSet = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Engine whose extraction blocks on a `Signal` (simulating a real,
/// uncancellable, slow LLM call) so a test can reliably create the
/// overlap window `scheduleRefresh`'s supersede guarantee exists to
/// handle, without depending on sleep-based timing assumptions.
private final class SlowExtractEngine: @unchecked Sendable {
    let started = Signal()
    let proceed = Signal()
    // Fires every time `set` (the coordinator's `apply` closure) is
    // called — lets a test deterministically know a refresh actually
    // applied, without a fixed sleep. One-shot per `Signal`, so it
    // only usefully pins the FIRST apply; that's exactly the one these
    // tests need to wait for (the winning window's).
    let applied = Signal()

    private let lock = NSLock()
    private var _setCalls: [[String]] = []
    var setCalls: [[String]] { withLock { _setCalls } }

    func extract(_ text: String) async -> ScreenKeywordExtraction? {
        await started.set()
        // `wait()` (not a raw sleep) blocks here until the test
        // releases it, matching the real C call: the Go side is
        // uncancellable and runs to completion regardless of whether
        // the wrapping Task was cancelled.
        await proceed.wait()
        return ScreenKeywordExtraction(raw: "X raw", keywords: ["X"], dropped: [])
    }
    func set(_ keywords: [String]) async {
        withLock { _setCalls.append(keywords) }
        await applied.set()
    }
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// - Parameter frontmostBundleID: what the (fake) frontmost-app lookup
///   reports, checked BEFORE `reader.read()` is ever called. Passed
///   explicitly (no default) since it now gates a privacy guarantee —
///   an accidental default here would be exactly how Finding 1 (read
///   precedes the denylist check) went unnoticed the first time.
private func makeCoordinator(
    engine: SpyEngine,
    snapshot: WindowSnapshot?,
    frontmostBundleID: String?,
    enabled: Bool = true,
    denylist: [String] = [],
    cache: ScreenContextCache = ScreenContextCache(),
    activityRecorder: ActivityRecorder = ActivityRecorder()
) -> (ScreenContextCoordinator, StubReader) {
    let reader = StubReader(snapshot: snapshot)
    let coordinator = ScreenContextCoordinator(
        reader: reader,
        cache: cache,
        denylist: { ScreenContextDenylist(userAdditions: denylist) },
        isEnabled: { enabled },
        frontmostBundleID: { frontmostBundleID },
        extract: { await engine.extract($0) },
        apply: { await engine.set($0) },
        onActivity: { await activityRecorder.record($0) }
    )
    return (coordinator, reader)
}

private let t0 = Date(timeIntervalSince1970: 2_000_000)

@Suite("ScreenContextCoordinator")
struct ScreenContextCoordinatorTests {

    @Test func extracts_and_applies_keywords_on_refresh() async {
        let engine = SpyEngine()
        let (c, _) = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "SpeakerGate lives here"),
            frontmostBundleID: "com.a"
        )
        await c.refresh(now: t0)
        #expect(engine.extractCalls == 1)
        #expect(engine.setCalls == [["SpeakerGate"]])
    }

    @Test func does_nothing_when_disabled() async {
        // Disabled must clear any previously-applied keywords, not just
        // skip reapplying new ones — otherwise turning the feature off
        // stops the READING but not the biasing: whatever was applied
        // before the toggle flip keeps affecting every dictation until
        // the app relaunches. `setCalls == [[]]` (an explicit clear),
        // not `.isEmpty` (no call at all).
        let engine = SpyEngine()
        let (c, _) = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "text"),
            frontmostBundleID: "com.a",
            enabled: false
        )
        await c.refresh(now: t0)
        #expect(engine.extractCalls == 0)
        #expect(engine.setCalls == [[]])
    }

    @Test func denylisted_app_is_never_read_or_extracted() async {
        // The bundle ID the (fake) frontmost-app lookup reports is
        // ALSO the denylisted one, so the pre-read gate must catch
        // this before `reader.read()` is ever called — not just
        // before `extract`. `readCount` is the assertion that
        // actually distinguishes "never read" from "read, then
        // discarded", which `extractCalls == 0` alone does not.
        let engine = SpyEngine()
        let (c, reader) = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.1password.1password", windowTitle: "Vault", text: "hunter2"),
            frontmostBundleID: "com.1password.1password",
            denylist: []
        )
        await c.refresh(now: t0)
        #expect(engine.extractCalls == 0)
        #expect(reader.readCount == 0)
    }

    @Test func denylisted_app_clears_stale_keywords() async {
        // Focusing a denylisted app must not leave the previous
        // window's keywords armed for the next dictation.
        let engine = SpyEngine()
        let (c, _) = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.1password.1password", windowTitle: "Vault", text: "hunter2"),
            frontmostBundleID: "com.1password.1password",
            denylist: []
        )
        await c.refresh(now: t0)
        #expect(engine.setCalls == [[]])
    }

    @Test func post_read_gate_still_catches_a_denylisted_snapshot_even_when_the_frontmost_lookup_disagrees() async {
        // Defence in depth: the frontmost-app lookup and the window
        // read aren't atomic with each other, so even when the
        // pre-read gate sees a benign app, the snapshot's own
        // (authoritative) bundle ID must still be checked and must
        // still clear rather than extract.
        let engine = SpyEngine()
        let (c, reader) = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.1password.1password", windowTitle: "Vault", text: "hunter2"),
            frontmostBundleID: "com.a"
        )
        await c.refresh(now: t0)
        #expect(reader.readCount == 1)          // pre-read gate passed, so the read DID happen
        #expect(engine.extractCalls == 0)       // but the post-read gate still caught it
        #expect(engine.setCalls == [[]])
    }

    @Test func second_refresh_of_unchanged_window_hits_cache() async {
        let engine = SpyEngine()
        let cache = ScreenContextCache()
        let snapshot = WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "unchanged text")
        let (c, _) = makeCoordinator(engine: engine, snapshot: snapshot, frontmostBundleID: "com.a", cache: cache)

        await c.refresh(now: t0)
        await c.refresh(now: t0)

        #expect(engine.extractCalls == 1)          // no second network call
        #expect(engine.setCalls.count == 2)        // but keywords re-applied
    }

    @Test func nil_snapshot_clears_keywords_without_extracting() async {
        // frontmostBundleID reports a benign app so the PRE-read gate
        // passes and the read genuinely happens (and genuinely
        // returns nil) — this test is about the "no readable window"
        // path, not the denylist path.
        let engine = SpyEngine()
        let (c, reader) = makeCoordinator(engine: engine, snapshot: nil, frontmostBundleID: "com.a")
        await c.refresh(now: t0)
        #expect(reader.readCount == 1)
        #expect(engine.extractCalls == 0)
        #expect(engine.setCalls == [[]])
    }

    @Test func window_text_is_forwarded_verbatim_to_the_extractor() async {
        let engine = SpyEngine()
        let (c, _) = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "the exact text"),
            frontmostBundleID: "com.a"
        )
        await c.refresh(now: t0)
        #expect(engine.lastExtractText == "the exact text")
    }

    @Test func failed_extraction_clears_keywords_without_caching_the_failure() async {
        let engine = SpyEngine()
        engine.stubbedKeywords = nil   // simulates a provider failure, not "found nothing"
        let cache = ScreenContextCache()
        let snapshot = WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "flaky text")
        let (c, _) = makeCoordinator(engine: engine, snapshot: snapshot, frontmostBundleID: "com.a", cache: cache)

        await c.refresh(now: t0)
        #expect(engine.extractCalls == 1)
        #expect(engine.setCalls == [[]])   // cleared, never left stale

        // The failure must NOT have been cached: refocusing the exact
        // same window content must retry extraction rather than
        // silently reusing a cached miss for the rest of the TTL.
        engine.stubbedKeywords = ["SpeakerGate"]
        await c.refresh(now: t0)
        #expect(engine.extractCalls == 2)
        #expect(engine.setCalls == [[], ["SpeakerGate"]])
    }

    @Test func scheduleRefresh_supersedes_a_slower_earlier_extraction() async throws {
        // Focus X (uncached — extraction starts and is slow) then
        // focus Y (cache hit — applies almost immediately) before X's
        // extraction finishes. X's late result must never overwrite
        // Y's already-applied keywords.
        let engine = SlowExtractEngine()
        let cache = ScreenContextCache()
        let snapshotX = WindowSnapshot(bundleID: "com.x", windowTitle: "X", text: "x text")
        let snapshotY = WindowSnapshot(bundleID: "com.y", windowTitle: "Y", text: "y text")

        // `scheduleRefresh()` -> `refresh()` uses its default `now:
        // Date()` (real wall-clock time), NOT the fixed `t0` used
        // elsewhere in this file — so the cache must be primed with a
        // real "now" too, or the TTL check below sees a ~56-year-old
        // entry as expired and Y falls through to `extract` as well,
        // masking which window actually won.
        let yKey = cache.key(bundleID: snapshotY.bundleID, windowTitle: snapshotY.windowTitle, text: snapshotY.text)
        cache.store(["Y"], for: yKey, now: Date())

        let activityRecorder = ActivityRecorder()
        let coordinator = ScreenContextCoordinator(
            reader: SequenceReader([snapshotX, snapshotY]),
            cache: cache,
            denylist: { ScreenContextDenylist(userAdditions: []) },
            isEnabled: { true },
            frontmostBundleID: { "com.test" },   // any non-denylisted id; both snapshots pass the post-read gate too
            extract: { await engine.extract($0) },
            apply: { await engine.set($0) },
            onActivity: { await activityRecorder.record($0) }
        )

        await coordinator.scheduleRefresh()   // starts X: read -> miss -> extract() blocks on `proceed`
        await engine.started.wait()           // deterministic: X's refresh() has now stamped its generation
        await coordinator.scheduleRefresh()   // starts Y: read -> cache hit -> applies almost immediately

        // Deterministic, not a sleep: waits for Y's OWN `apply` call,
        // which cannot happen until Y's refresh() has itself stamped a
        // newer generation than X's (that stamp is the first thing
        // `refresh()` does, strictly before the cache lookup that
        // leads here). By the time this returns, X's later generation
        // check is therefore GUARANTEED to already see a newer
        // `generation` than the one it captured — releasing X below
        // can no longer race with Y's generation stamp.
        await engine.applied.wait()

        await engine.proceed.set()            // let X's (already-losing) extraction finish
        // X's tail after `extract` returns is cache.store (sync) then
        // `await applyIfCurrent(...)` (ScreenContextCoordinator.swift)
        // — that IS an await, but on the losing path it's a same-actor
        // call whose guard fails immediately, with no real suspension
        // inside it. So this wait is still a genuine, not-fully-
        // eliminated race: nothing pins the exact moment X's resumed
        // continuation actually reaches and finishes that awaited (if
        // non-suspending) call relative to this line. It's a real (if
        // low-risk) sleep-based assumption, called out honestly rather
        // than papered over: on an extremely loaded machine, checking
        // too early could observe `setCalls` before X's tail has run,
        // which would only produce a false PASS on a regression, never
        // a false failure on correct code (X can only ever append a
        // second entry, never replace or remove Y's).
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(engine.setCalls == [["Y"]])

        // X's late-arriving result must be recorded as `.superseded` —
        // NOT as `.extractionSucceeded`, which would misrepresent a
        // result that never actually reached the engine. Y's own
        // refresh (the one that won) recorded a normal `.cacheHit`.
        let activities = await activityRecorder.activities
        #expect(activities.contains { $0.bundleID == "com.x" && $0.outcome == .superseded })
        #expect(activities.contains { $0.bundleID == "com.y" && $0.outcome == .cacheHit })
        // A superseded result must never carry the keywords it would
        // otherwise have applied — they never actually reached the
        // engine, so surfacing them here would be misleading.
        #expect(activities.first { $0.bundleID == "com.x" }?.appliedKeywords == [])
    }

    @Test func overlapping_direct_refresh_calls_are_ordered_by_generation_not_cancellation() async throws {
        // Same scenario as `scheduleRefresh_supersedes_a_slower_earlier_extraction`,
        // but drives `refresh()` DIRECTLY instead of through
        // `scheduleRefresh()`, so neither Task is ever `.cancel()`ed —
        // `Task.isCancelled` stays false for both throughout. This
        // isolates the generation-counter half of `applyIfCurrent`'s
        // guard: deleting only the `myGeneration == generation` clause
        // (leaving `!Task.isCancelled` in place) must turn this RED,
        // proving the counter itself is load-bearing rather than being
        // covered incidentally by scheduleRefresh's own cancellation
        // (see progress.md Ruling 26 / fix round 2 finding 2).
        let engine = SlowExtractEngine()
        let cache = ScreenContextCache()
        let snapshotX = WindowSnapshot(bundleID: "com.x", windowTitle: "X", text: "x text")
        let snapshotY = WindowSnapshot(bundleID: "com.y", windowTitle: "Y", text: "y text")

        let yKey = cache.key(bundleID: snapshotY.bundleID, windowTitle: snapshotY.windowTitle, text: snapshotY.text)
        cache.store(["Y"], for: yKey, now: Date())

        let coordinator = ScreenContextCoordinator(
            reader: SequenceReader([snapshotX, snapshotY]),
            cache: cache,
            denylist: { ScreenContextDenylist(userAdditions: []) },
            isEnabled: { true },
            frontmostBundleID: { "com.test" },
            extract: { await engine.extract($0) },
            apply: { await engine.set($0) },
            onActivity: { _ in }
        )

        // Direct `refresh()` calls, each wrapped in a Task we hold and
        // await ourselves — NOT `scheduleRefresh()`. Nothing ever
        // calls `.cancel()` on either Task.
        let xTask = Task { await coordinator.refresh() }
        await engine.started.wait()             // X has stamped its generation and is blocked in extract()

        let yTask = Task { await coordinator.refresh() }
        await engine.applied.wait()             // Y has stamped a newer generation and applied

        await engine.proceed.set()              // let X's (already-losing-by-generation) extraction finish
        await xTask.value                        // deterministic: X's refresh() has now fully returned
        await yTask.value

        #expect(engine.setCalls == [["Y"]])
    }
}

/// One `@Test` per `refresh()` outcome, verifying `ScreenContextActivity`
/// carries the right `outcome` and the right (or deliberately absent)
/// payload for that path.
@Suite("ScreenContextCoordinator activity")
struct ScreenContextCoordinatorActivityTests {

    @Test func disabled_records_disabled_outcome_with_no_bundle_id() async {
        let engine = SpyEngine()
        let recorder = ActivityRecorder()
        let (c, _) = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "text"),
            frontmostBundleID: "com.a",
            enabled: false,
            activityRecorder: recorder
        )
        await c.refresh(now: t0)
        let activities = await recorder.activities
        #expect(activities.count == 1)
        #expect(activities.first?.outcome == .disabled)
        #expect(activities.first?.bundleID == nil)
        #expect(activities.first?.capturedText == nil)
    }

    @Test func pre_read_denylist_skip_records_bundle_id_but_no_captured_text() async {
        let engine = SpyEngine()
        let recorder = ActivityRecorder()
        let (c, reader) = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.1password.1password", windowTitle: "Vault", text: "hunter2"),
            frontmostBundleID: "com.1password.1password",
            activityRecorder: recorder
        )
        await c.refresh(now: t0)
        #expect(reader.readCount == 0)   // the read never happened at all
        let activities = await recorder.activities
        #expect(activities.count == 1)
        #expect(activities.first?.outcome == .skippedPreReadDenylist)
        #expect(activities.first?.bundleID == "com.1password.1password")
        #expect(activities.first?.capturedText == nil)
    }

    @Test func post_read_denylist_skip_records_bundle_id_but_never_the_text_it_read() async {
        // Mirrors `post_read_gate_still_catches_a_denylisted_snapshot_even_when_the_frontmost_lookup_disagrees`:
        // the pre-read gate sees a benign app, so the read genuinely
        // happens and genuinely returns a denylisted app's text — but
        // that text must never reach the activity record. Recording it
        // here, even in memory, would defeat the one guarantee this
        // gate exists to provide.
        let engine = SpyEngine()
        let recorder = ActivityRecorder()
        let (c, reader) = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.1password.1password", windowTitle: "Vault", text: "hunter2"),
            frontmostBundleID: "com.a",
            activityRecorder: recorder
        )
        await c.refresh(now: t0)
        #expect(reader.readCount == 1)   // the read DID happen this time
        let activities = await recorder.activities
        #expect(activities.count == 1)
        #expect(activities.first?.outcome == .skippedPostReadDenylist)
        #expect(activities.first?.bundleID == "com.1password.1password")
        #expect(activities.first?.capturedText == nil)
        #expect(activities.first?.capturedTextLength == nil)
        #expect(activities.first?.capturedTextSource == nil)
    }

    @Test func no_readable_window_text_records_the_pre_read_bundle_id() async {
        let engine = SpyEngine()
        let recorder = ActivityRecorder()
        let (c, reader) = makeCoordinator(
            engine: engine, snapshot: nil, frontmostBundleID: "com.a", activityRecorder: recorder
        )
        await c.refresh(now: t0)
        #expect(reader.readCount == 1)
        let activities = await recorder.activities
        #expect(activities.count == 1)
        #expect(activities.first?.outcome == .noReadableWindowText)
        #expect(activities.first?.bundleID == "com.a")
        #expect(activities.first?.capturedText == nil)
    }

    @Test func cache_hit_records_captured_text_and_applied_keywords_but_no_raw_or_dropped() async {
        let engine = SpyEngine()
        let cache = ScreenContextCache()
        let recorder = ActivityRecorder()
        let snapshot = WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "unchanged text", source: .ocr)
        let (c, _) = makeCoordinator(engine: engine, snapshot: snapshot, frontmostBundleID: "com.a", cache: cache, activityRecorder: recorder)

        await c.refresh(now: t0)   // primes the cache (extraction)
        await c.refresh(now: t0)   // cache hit

        let activities = await recorder.activities
        #expect(activities.count == 2)
        let hit = activities[1]
        #expect(hit.outcome == .cacheHit)
        #expect(hit.bundleID == "com.a")
        #expect(hit.capturedText == "unchanged text")
        #expect(hit.capturedTextSource == .ocr)
        #expect(hit.capturedTextLength == "unchanged text".count)
        #expect(hit.appliedKeywords == ["SpeakerGate"])
        #expect(hit.rawResponse == nil)
        #expect(hit.dropped.isEmpty)
    }

    @Test func extraction_succeeded_records_raw_response_and_drops() async {
        let engine = SpyEngine()
        engine.stubbedRaw = "SpeakerGate, 123, DeepFilterNet"
        engine.stubbedKeywords = ["SpeakerGate", "DeepFilterNet"]
        engine.stubbedDropped = [ScreenContextDroppedTerm(term: "123", reason: "numeric")]
        let recorder = ActivityRecorder()
        let (c, _) = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "SpeakerGate 123 DeepFilterNet"),
            frontmostBundleID: "com.a",
            activityRecorder: recorder
        )
        await c.refresh(now: t0)
        let activities = await recorder.activities
        #expect(activities.count == 1)
        let a = activities[0]
        #expect(a.outcome == .extractionSucceeded)
        #expect(a.rawResponse == "SpeakerGate, 123, DeepFilterNet")
        #expect(a.dropped == [ScreenContextDroppedTerm(term: "123", reason: "numeric")])
        #expect(a.appliedKeywords == ["SpeakerGate", "DeepFilterNet"])
        #expect(a.capturedTextSource == .accessibility)
    }

    @Test func extraction_failed_records_captured_text_but_no_raw_response() async {
        let engine = SpyEngine()
        engine.stubbedKeywords = nil   // simulates a provider failure
        let recorder = ActivityRecorder()
        let (c, _) = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "flaky text"),
            frontmostBundleID: "com.a",
            activityRecorder: recorder
        )
        await c.refresh(now: t0)
        let activities = await recorder.activities
        #expect(activities.count == 1)
        #expect(activities.first?.outcome == .extractionFailed)
        #expect(activities.first?.capturedText == "flaky text")
        #expect(activities.first?.rawResponse == nil)
        #expect(activities.first?.appliedKeywords == [])
    }
}
