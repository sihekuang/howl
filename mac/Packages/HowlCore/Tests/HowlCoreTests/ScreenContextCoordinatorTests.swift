import Foundation
import Testing
@testable import HowlCore

private final class SpyEngine: @unchecked Sendable {
    var imageExtractCalls = 0
    var lastExtractImage = Data()
    var textExtractCalls = 0
    var lastExtractText = ""
    var setCalls: [[String]] = []

    // The image path's three-way answer. `.success` is the norm;
    // `.failed` is a transient provider problem; `.noVision` is the
    // verdict that this provider+model cannot see, and is the ONLY
    // thing that may reach the text path below.
    var stubbedImageResult: ScreenImageExtractionResult = .success(
        ScreenKeywordExtraction(raw: "SpeakerGate, DeepFilterNet", keywords: ["SpeakerGate"], dropped: [])
    )
    // nil simulates a text extraction FAILURE (provider unreachable,
    // rate-limited, timed out); [] simulates a successful call that
    // genuinely found nothing.
    var stubbedTextKeywords: [String]? = ["AXKeyword"]
    var stubbedTextRaw = "AXKeyword"
    var stubbedTextDropped: [ScreenContextDroppedTerm] = []

    func extractImage(_ png: Data) async -> ScreenImageExtractionResult {
        imageExtractCalls += 1
        lastExtractImage = png
        return stubbedImageResult
    }
    func extractText(_ text: String) async -> ScreenKeywordExtraction? {
        textExtractCalls += 1
        lastExtractText = text
        guard let keywords = stubbedTextKeywords else { return nil }
        return ScreenKeywordExtraction(raw: stubbedTextRaw, keywords: keywords, dropped: stubbedTextDropped)
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

private final class StubCapturer: WindowImageCapturing, @unchecked Sendable {
    let capture_: WindowImageCapture?
    private let lock = NSLock()
    private var _captureCount = 0
    var captureCount: Int { withLock { _captureCount } }

    init(_ capture: WindowImageCapture?) { self.capture_ = capture }

    func capture() async -> WindowImageCapture? {
        recordCapture()
        return capture_
    }

    // NSLock's lock()/unlock() are unavailable directly from an async
    // context in this toolchain; hop through a plain sync method.
    private func recordCapture() { withLock { _captureCount += 1 } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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

    private func recordRead() { withLock { _readCount += 1 } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Returns a fixed sequence of captures, one per `capture()` call, then
/// nil. Simulates focus moving between windows across successive
/// coordinator refreshes — `StubCapturer` can't do this since it always
/// returns the same capture.
private final class SequenceCapturer: WindowImageCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [WindowImageCapture?]
    init(_ captures: [WindowImageCapture?]) { self.captures = captures }
    func capture() async -> WindowImageCapture? { pop() }
    private func pop() -> WindowImageCapture? {
        lock.lock()
        defer { lock.unlock() }
        guard !captures.isEmpty else { return nil }
        return captures.removeFirst()
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

/// Engine whose image extraction blocks on a `Signal` (simulating a
/// real, uncancellable, slow vision call) so a test can reliably create
/// the overlap window `scheduleRefresh`'s supersede guarantee exists to
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

    func extractImage(_ png: Data) async -> ScreenImageExtractionResult {
        await started.set()
        // `wait()` (not a raw sleep) blocks here until the test
        // releases it, matching the real C call: the Go side is
        // uncancellable and runs to completion regardless of whether
        // the wrapping Task was cancelled.
        await proceed.wait()
        return .success(ScreenKeywordExtraction(raw: "X raw", keywords: ["X"], dropped: []))
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

private func png(_ marker: String) -> Data { Data(marker.utf8) }

private func shot(
    _ bundleID: String, _ title: String, _ marker: String,
    pixels: ScreenContextPixelSize = ScreenContextPixelSize(width: 1568, height: 980)
) -> WindowImageCapture {
    WindowImageCapture(bundleID: bundleID, windowTitle: title, pngData: png(marker), pixelSize: pixels)
}

/// - Parameter frontmostBundleID: what the (fake) frontmost-app lookup
///   reports, checked BEFORE `capturer.capture()` is ever called. Passed
///   explicitly (no default) since it now gates a privacy guarantee —
///   an accidental default here would be exactly how Finding 1 (capture
///   precedes the denylist check) went unnoticed the first time.
private func makeCoordinator(
    engine: SpyEngine,
    capture: WindowImageCapture?,
    snapshot: WindowSnapshot? = nil,
    frontmostBundleID: String?,
    enabled: Bool = true,
    denylist: [String] = [],
    cache: ScreenContextCache = ScreenContextCache(),
    activityRecorder: ActivityRecorder = ActivityRecorder()
) -> (ScreenContextCoordinator, StubCapturer, StubReader) {
    let capturer = StubCapturer(capture)
    let reader = StubReader(snapshot: snapshot)
    let coordinator = ScreenContextCoordinator(
        capturer: capturer,
        textReader: reader,
        cache: cache,
        denylist: { ScreenContextDenylist(userAdditions: denylist) },
        isEnabled: { enabled },
        frontmostBundleID: { frontmostBundleID },
        extractImage: { await engine.extractImage($0) },
        extractText: { await engine.extractText($0) },
        apply: { await engine.set($0) },
        onActivity: { await activityRecorder.record($0) }
    )
    return (coordinator, capturer, reader)
}

private let t0 = Date(timeIntervalSince1970: 2_000_000)

@Suite("ScreenContextCoordinator")
struct ScreenContextCoordinatorTests {

    @Test func extracts_and_applies_keywords_from_the_screenshot() async {
        let engine = SpyEngine()
        let (c, _, reader) = makeCoordinator(
            engine: engine,
            capture: shot("com.a", "Doc", "png-bytes"),
            frontmostBundleID: "com.a"
        )
        await c.refresh(now: t0)
        #expect(engine.imageExtractCalls == 1)
        #expect(engine.setCalls == [["SpeakerGate"]])
        // The AX reader is the no-vision fallback ONLY — a healthy
        // vision path must never touch it.
        #expect(reader.readCount == 0)
        #expect(engine.textExtractCalls == 0)
    }

    @Test func image_bytes_are_forwarded_verbatim_to_the_extractor() async {
        let engine = SpyEngine()
        let (c, _, _) = makeCoordinator(
            engine: engine,
            capture: shot("com.a", "Doc", "the exact bytes"),
            frontmostBundleID: "com.a"
        )
        await c.refresh(now: t0)
        #expect(engine.lastExtractImage == png("the exact bytes"))
    }

    @Test func does_nothing_when_disabled() async {
        // Disabled must clear any previously-applied keywords, not just
        // skip reapplying new ones — otherwise turning the feature off
        // stops the CAPTURE but not the biasing: whatever was applied
        // before the toggle flip keeps affecting every dictation until
        // the app relaunches. `setCalls == [[]]` (an explicit clear),
        // not `.isEmpty` (no call at all).
        let engine = SpyEngine()
        let (c, capturer, _) = makeCoordinator(
            engine: engine,
            capture: shot("com.a", "Doc", "bytes"),
            frontmostBundleID: "com.a",
            enabled: false
        )
        await c.refresh(now: t0)
        #expect(engine.imageExtractCalls == 0)
        #expect(capturer.captureCount == 0)
        #expect(engine.setCalls == [[]])
    }

    @Test func denylisted_app_is_never_captured_or_extracted() async {
        // The bundle ID the (fake) frontmost-app lookup reports is
        // ALSO the denylisted one, so the pre-capture gate must catch
        // this before `capturer.capture()` is ever called — not just
        // before `extract`. `captureCount` is the assertion that
        // actually distinguishes "never photographed" from
        // "photographed, then discarded", which `imageExtractCalls == 0`
        // alone does not — and it is also what keeps a denylisted app
        // from triggering the Screen Recording prompt.
        let engine = SpyEngine()
        let (c, capturer, reader) = makeCoordinator(
            engine: engine,
            capture: shot("com.1password.1password", "Vault", "secret pixels"),
            snapshot: WindowSnapshot(bundleID: "com.1password.1password", windowTitle: "Vault", text: "hunter2"),
            frontmostBundleID: "com.1password.1password",
            denylist: []
        )
        await c.refresh(now: t0)
        #expect(capturer.captureCount == 0)
        #expect(reader.readCount == 0)
        #expect(engine.imageExtractCalls == 0)
        #expect(engine.textExtractCalls == 0)
    }

    @Test func denylisted_app_clears_stale_keywords() async {
        // Focusing a denylisted app must not leave the previous
        // window's keywords armed for the next dictation.
        let engine = SpyEngine()
        let (c, _, _) = makeCoordinator(
            engine: engine,
            capture: shot("com.1password.1password", "Vault", "secret pixels"),
            frontmostBundleID: "com.1password.1password",
            denylist: []
        )
        await c.refresh(now: t0)
        #expect(engine.setCalls == [[]])
    }

    @Test func post_capture_gate_still_catches_a_denylisted_window_even_when_the_frontmost_lookup_disagrees() async {
        // Defence in depth: the frontmost-app lookup and the capture
        // aren't atomic with each other, so even when the pre-capture
        // gate sees a benign app, the capture's own (authoritative)
        // bundle ID must still be checked and must still clear rather
        // than send the pixels anywhere.
        let engine = SpyEngine()
        let (c, capturer, _) = makeCoordinator(
            engine: engine,
            capture: shot("com.1password.1password", "Vault", "secret pixels"),
            frontmostBundleID: "com.a"
        )
        await c.refresh(now: t0)
        #expect(capturer.captureCount == 1)     // pre-capture gate passed, so the capture DID happen
        #expect(engine.imageExtractCalls == 0)  // but the post-capture gate still caught it
        #expect(engine.setCalls == [[]])
    }

    @Test func second_refresh_of_an_identical_screenshot_hits_cache() async {
        let engine = SpyEngine()
        let cache = ScreenContextCache()
        let (c, _, _) = makeCoordinator(
            engine: engine,
            capture: shot("com.a", "Doc", "unchanged pixels"),
            frontmostBundleID: "com.a",
            cache: cache
        )

        await c.refresh(now: t0)
        await c.refresh(now: t0)

        #expect(engine.imageExtractCalls == 1)     // no second network call
        #expect(engine.setCalls.count == 2)        // but keywords re-applied
    }

    @Test func a_changed_screenshot_of_the_same_window_misses_cache() async {
        // The cache is keyed on image CONTENT, not window identity —
        // scrolling or editing must re-extract rather than serve the
        // previous screen's keywords.
        let engine = SpyEngine()
        let cache = ScreenContextCache()
        let capturer = SequenceCapturer([shot("com.a", "Doc", "pixels v1"), shot("com.a", "Doc", "pixels v2")])
        let c = ScreenContextCoordinator(
            capturer: capturer,
            textReader: StubReader(snapshot: nil),
            cache: cache,
            denylist: { ScreenContextDenylist(userAdditions: []) },
            isEnabled: { true },
            frontmostBundleID: { "com.a" },
            extractImage: { await engine.extractImage($0) },
            extractText: { await engine.extractText($0) },
            apply: { await engine.set($0) },
            onActivity: { _ in }
        )

        await c.refresh(now: t0)
        await c.refresh(now: t0)
        #expect(engine.imageExtractCalls == 2)
    }

    @Test func nil_capture_falls_back_to_the_accessibility_text_path() async {
        // frontmostBundleID reports a benign app so the pre-capture
        // gate passes and the capture genuinely happens (and genuinely
        // returns nil) — Screen Recording denied, no on-screen window,
        // or the window vanished mid-capture.
        //
        // No pixels means the AX path, not a dead end. An earlier rule
        // cleared and returned here; that silently and permanently
        // killed screen context for everyone who declines the Screen
        // Recording prompt, while the feature's own toggle — the thing
        // that actually says "off" — was still on.
        let engine = SpyEngine()
        let (c, capturer, reader) = makeCoordinator(
            engine: engine,
            capture: nil,
            snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "AX text instead"),
            frontmostBundleID: "com.a"
        )
        await c.refresh(now: t0)
        #expect(capturer.captureCount == 1)
        #expect(reader.readCount == 1)
        // No screenshot exists, so the image extractor is never called;
        // the text one is, with the AX text verbatim.
        #expect(engine.imageExtractCalls == 0)
        #expect(engine.textExtractCalls == 1)
        #expect(engine.lastExtractText == "AX text instead")
        #expect(engine.setCalls == [["AXKeyword"]])
    }

    @Test func nil_capture_fallback_still_clears_when_ax_has_nothing_either() async {
        // Both paths dry: keywords are cleared rather than left armed
        // from the previous window.
        let engine = SpyEngine()
        let (c, capturer, reader) = makeCoordinator(
            engine: engine, capture: nil, snapshot: nil, frontmostBundleID: "com.a"
        )
        await c.refresh(now: t0)
        #expect(capturer.captureCount == 1)
        #expect(reader.readCount == 1)
        #expect(engine.textExtractCalls == 0)
        #expect(engine.setCalls == [[]])
    }

    @Test func nil_capture_fallback_never_extracts_from_a_denylisted_app() async {
        // The screenshot-unavailable route must be no weaker a
        // guarantee than the no-vision one. `AXWindowTextReader.read()`
        // enforces the denylist internally (via
        // `resolveReadableFrontmostApp`, so identity and judgement are
        // one main-actor hop); this covers the coordinator's own
        // post-read gate, the second of the two, using a stub reader
        // that deliberately hands back a denylisted snapshot the way a
        // mid-flight app switch would.
        let engine = SpyEngine()
        let (c, _, reader) = makeCoordinator(
            engine: engine,
            capture: nil,
            snapshot: WindowSnapshot(bundleID: "com.1password.1password", windowTitle: "Vault", text: "hunter2"),
            frontmostBundleID: "com.a"
        )
        await c.refresh(now: t0)
        #expect(reader.readCount == 1)
        #expect(engine.textExtractCalls == 0)
        #expect(engine.lastExtractText == "")
        #expect(engine.setCalls == [[]])
    }

    @Test func failed_extraction_clears_keywords_without_caching_the_failure() async {
        let engine = SpyEngine()
        engine.stubbedImageResult = .failed   // a provider blip, not "found nothing"
        let cache = ScreenContextCache()
        let (c, _, _) = makeCoordinator(
            engine: engine,
            capture: shot("com.a", "Doc", "flaky pixels"),
            frontmostBundleID: "com.a",
            cache: cache
        )

        await c.refresh(now: t0)
        #expect(engine.imageExtractCalls == 1)
        #expect(engine.setCalls == [[]])   // cleared, never left stale

        // The failure must NOT have been cached: refocusing the exact
        // same window content must retry extraction rather than
        // silently reusing a cached miss for the rest of the TTL.
        engine.stubbedImageResult = .success(
            ScreenKeywordExtraction(raw: "SpeakerGate", keywords: ["SpeakerGate"], dropped: [])
        )
        await c.refresh(now: t0)
        #expect(engine.imageExtractCalls == 2)
        #expect(engine.setCalls == [[], ["SpeakerGate"]])
    }

    @Test func an_ordinary_failure_never_falls_back_to_the_accessibility_path() async {
        // `.failed` is a timeout / rate limit / auth problem. Nothing
        // is cached on either side of the ABI, so the image path stays
        // in use — falling back here would silently switch a
        // vision-capable setup onto the text pipeline over one blip.
        let engine = SpyEngine()
        engine.stubbedImageResult = .failed
        let (c, _, reader) = makeCoordinator(
            engine: engine,
            capture: shot("com.a", "Doc", "flaky pixels"),
            snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "AX text"),
            frontmostBundleID: "com.a"
        )
        await c.refresh(now: t0)
        #expect(reader.readCount == 0)
        #expect(engine.textExtractCalls == 0)
        #expect(engine.setCalls == [[]])
    }

    @Test func no_vision_falls_back_to_the_accessibility_text_path() async {
        // The one case that may reach the AX reader: the provider says
        // this model cannot accept images at all.
        let engine = SpyEngine()
        engine.stubbedImageResult = .noVision
        let (c, capturer, reader) = makeCoordinator(
            engine: engine,
            capture: shot("com.a", "Doc", "pixels"),
            snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "the exact text"),
            frontmostBundleID: "com.a"
        )
        await c.refresh(now: t0)
        #expect(capturer.captureCount == 1)
        #expect(engine.imageExtractCalls == 1)
        #expect(reader.readCount == 1)
        #expect(engine.textExtractCalls == 1)
        #expect(engine.lastExtractText == "the exact text")
        #expect(engine.setCalls == [["AXKeyword"]])
    }

    @Test func no_vision_fallback_still_clears_when_ax_has_nothing_to_read() async {
        let engine = SpyEngine()
        engine.stubbedImageResult = .noVision
        let (c, _, reader) = makeCoordinator(
            engine: engine,
            capture: shot("com.a", "Doc", "pixels"),
            snapshot: nil,
            frontmostBundleID: "com.a"
        )
        await c.refresh(now: t0)
        #expect(reader.readCount == 1)
        #expect(engine.textExtractCalls == 0)
        #expect(engine.setCalls == [[]])
    }

    @Test func no_vision_fallback_still_honours_the_post_read_denylist_gate() async {
        // The fallback must be no weaker a guarantee than the primary
        // path: an AX snapshot whose own bundle ID is denylisted is
        // dropped, not extracted, even though the pre-capture gate saw
        // a benign app.
        let engine = SpyEngine()
        engine.stubbedImageResult = .noVision
        let (c, _, reader) = makeCoordinator(
            engine: engine,
            capture: shot("com.a", "Doc", "pixels"),
            snapshot: WindowSnapshot(bundleID: "com.1password.1password", windowTitle: "Vault", text: "hunter2"),
            frontmostBundleID: "com.a"
        )
        await c.refresh(now: t0)
        #expect(reader.readCount == 1)
        #expect(engine.textExtractCalls == 0)
        #expect(engine.setCalls == [[]])
    }

    @Test func no_vision_fallback_caches_on_the_text_key() async {
        // Two refreshes of the same unchanged window: the fallback's
        // own cache entry must hit, so a text-only model costs one
        // round trip, not one per focus event.
        let engine = SpyEngine()
        engine.stubbedImageResult = .noVision
        let cache = ScreenContextCache()
        let (c, _, _) = makeCoordinator(
            engine: engine,
            capture: shot("com.a", "Doc", "pixels"),
            snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "unchanged text"),
            frontmostBundleID: "com.a",
            cache: cache
        )
        await c.refresh(now: t0)
        await c.refresh(now: t0)
        #expect(engine.textExtractCalls == 1)
        #expect(engine.setCalls == [["AXKeyword"], ["AXKeyword"]])
    }

    @Test func scheduleRefresh_supersedes_a_slower_earlier_extraction() async throws {
        // Focus X (uncached — extraction starts and is slow) then
        // focus Y (cache hit — applies almost immediately) before X's
        // extraction finishes. X's late result must never overwrite
        // Y's already-applied keywords.
        let engine = SlowExtractEngine()
        let cache = ScreenContextCache()
        let captureX = shot("com.x", "X", "x pixels")
        let captureY = shot("com.y", "Y", "y pixels")

        // `scheduleRefresh()` -> `refresh()` uses its default `now:
        // Date()` (real wall-clock time), NOT the fixed `t0` used
        // elsewhere in this file — so the cache must be primed with a
        // real "now" too, or the TTL check below sees a ~56-year-old
        // entry as expired and Y falls through to `extract` as well,
        // masking which window actually won.
        let yKey = cache.key(bundleID: captureY.bundleID, windowTitle: captureY.windowTitle, imageData: captureY.pngData)
        cache.store(["Y"], for: yKey, now: Date())

        let activityRecorder = ActivityRecorder()
        let coordinator = ScreenContextCoordinator(
            capturer: SequenceCapturer([captureX, captureY]),
            textReader: StubReader(snapshot: nil),
            cache: cache,
            denylist: { ScreenContextDenylist(userAdditions: []) },
            isEnabled: { true },
            frontmostBundleID: { "com.test" },   // any non-denylisted id; both captures pass the post-capture gate too
            extractImage: { await engine.extractImage($0) },
            extractText: { _ in nil },
            apply: { await engine.set($0) },
            onActivity: { await activityRecorder.record($0) }
        )

        await coordinator.scheduleRefresh()   // starts X: capture -> miss -> extract() blocks on `proceed`
        await engine.started.wait()           // deterministic: X's refresh() has now stamped its generation
        await coordinator.scheduleRefresh()   // starts Y: capture -> cache hit -> applies almost immediately

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
        let captureX = shot("com.x", "X", "x pixels")
        let captureY = shot("com.y", "Y", "y pixels")

        let yKey = cache.key(bundleID: captureY.bundleID, windowTitle: captureY.windowTitle, imageData: captureY.pngData)
        cache.store(["Y"], for: yKey, now: Date())

        let coordinator = ScreenContextCoordinator(
            capturer: SequenceCapturer([captureX, captureY]),
            textReader: StubReader(snapshot: nil),
            cache: cache,
            denylist: { ScreenContextDenylist(userAdditions: []) },
            isEnabled: { true },
            frontmostBundleID: { "com.test" },
            extractImage: { await engine.extractImage($0) },
            extractText: { _ in nil },
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
        let (c, _, _) = makeCoordinator(
            engine: engine,
            capture: shot("com.a", "Doc", "pixels"),
            frontmostBundleID: "com.a",
            enabled: false,
            activityRecorder: recorder
        )
        await c.refresh(now: t0)
        let activities = await recorder.activities
        #expect(activities.count == 1)
        #expect(activities.first?.outcome == .disabled)
        #expect(activities.first?.bundleID == nil)
        #expect(activities.first?.source == nil)
        #expect(activities.first?.capturedImageBytes == nil)
    }

    @Test func pre_capture_denylist_skip_records_bundle_id_but_nothing_captured() async {
        let engine = SpyEngine()
        let recorder = ActivityRecorder()
        let (c, capturer, _) = makeCoordinator(
            engine: engine,
            capture: shot("com.1password.1password", "Vault", "secret pixels"),
            frontmostBundleID: "com.1password.1password",
            activityRecorder: recorder
        )
        await c.refresh(now: t0)
        #expect(capturer.captureCount == 0)   // the capture never happened at all
        let activities = await recorder.activities
        #expect(activities.count == 1)
        #expect(activities.first?.outcome == .skippedPreReadDenylist)
        #expect(activities.first?.bundleID == "com.1password.1password")
        #expect(activities.first?.capturedImageBytes == nil)
        #expect(activities.first?.capturedText == nil)
    }

    @Test func post_capture_denylist_skip_records_bundle_id_but_never_what_it_captured() async {
        // Mirrors `post_capture_gate_still_catches_a_denylisted_window_even_when_the_frontmost_lookup_disagrees`:
        // the pre-capture gate sees a benign app, so the capture
        // genuinely happens and genuinely returns a denylisted app's
        // pixels — but nothing about them may reach the activity
        // record. Recording even the byte count here would leak that
        // the window was photographed at all.
        let engine = SpyEngine()
        let recorder = ActivityRecorder()
        let (c, capturer, _) = makeCoordinator(
            engine: engine,
            capture: shot("com.1password.1password", "Vault", "secret pixels"),
            frontmostBundleID: "com.a",
            activityRecorder: recorder
        )
        await c.refresh(now: t0)
        #expect(capturer.captureCount == 1)   // the capture DID happen this time
        let activities = await recorder.activities
        #expect(activities.count == 1)
        #expect(activities.first?.outcome == .skippedPostReadDenylist)
        #expect(activities.first?.bundleID == "com.1password.1password")
        #expect(activities.first?.source == nil)
        #expect(activities.first?.capturedImageBytes == nil)
        #expect(activities.first?.capturedText == nil)
        #expect(activities.first?.capturedTextLength == nil)
    }

    @Test func no_capture_and_no_ax_text_records_both_facts_separately() async {
        // The record must distinguish "no screenshot" from "no text":
        // the outcome is the AX read's own result, and why the image
        // path was skipped rides alongside it as `fallbackReason`.
        // Collapsing them into one case is what makes an inspector
        // unable to tell "grant Screen Recording" from "this app
        // exposes no AX text".
        let engine = SpyEngine()
        let recorder = ActivityRecorder()
        let (c, capturer, reader) = makeCoordinator(
            engine: engine, capture: nil, snapshot: nil,
            frontmostBundleID: "com.a", activityRecorder: recorder
        )
        await c.refresh(now: t0)
        #expect(capturer.captureCount == 1)
        #expect(reader.readCount == 1)
        let activities = await recorder.activities
        #expect(activities.count == 1)
        #expect(activities.first?.outcome == .noReadableWindowText)
        #expect(activities.first?.fallbackReason == .screenshotUnavailable)
        #expect(activities.first?.bundleID == "com.a")
        #expect(activities.first?.capturedImageBytes == nil)
        #expect(activities.first?.capturedImagePixelSize == nil)
    }

    @Test func no_capture_fallback_records_the_accessibility_source_and_why() async {
        // Exactly one record for the refresh, saying where the keywords
        // came from (AX text) and why the image path was skipped
        // (no screenshot) — the two together are what lets the
        // inspector say "the screenshot failed, so this came from
        // accessibility text".
        let engine = SpyEngine()
        let recorder = ActivityRecorder()
        let (c, _, _) = makeCoordinator(
            engine: engine,
            capture: nil,
            snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "AX window text"),
            frontmostBundleID: "com.a",
            activityRecorder: recorder
        )
        await c.refresh(now: t0)
        let activities = await recorder.activities
        #expect(activities.count == 1)
        let a = activities[0]
        #expect(a.outcome == .extractionSucceeded)
        #expect(a.source == .accessibility)
        #expect(a.fallbackReason == .screenshotUnavailable)
        #expect(a.capturedText == "AX window text")
        #expect(a.capturedImageBytes == nil)
        #expect(a.appliedKeywords == ["AXKeyword"])
    }

    @Test func cache_hit_records_the_image_size_and_applied_keywords_but_no_raw_or_dropped() async {
        let engine = SpyEngine()
        let cache = ScreenContextCache()
        let recorder = ActivityRecorder()
        let capture = shot("com.a", "Doc", "unchanged pixels")
        let (c, _, _) = makeCoordinator(
            engine: engine, capture: capture, frontmostBundleID: "com.a", cache: cache, activityRecorder: recorder
        )

        await c.refresh(now: t0)   // primes the cache (extraction)
        await c.refresh(now: t0)   // cache hit

        let activities = await recorder.activities
        #expect(activities.count == 2)
        let hit = activities[1]
        #expect(hit.outcome == .cacheHit)
        #expect(hit.bundleID == "com.a")
        #expect(hit.source == .screenshot)
        #expect(hit.capturedImageBytes == capture.pngData.count)
        // The screenshot path has no window text at all — nothing here
        // may pretend otherwise.
        #expect(hit.capturedText == nil)
        #expect(hit.capturedTextLength == nil)
        #expect(hit.appliedKeywords == ["SpeakerGate"])
        #expect(hit.rawResponse == nil)
        #expect(hit.dropped.isEmpty)
    }

    @Test func extraction_succeeded_records_raw_response_and_drops() async {
        let engine = SpyEngine()
        engine.stubbedImageResult = .success(ScreenKeywordExtraction(
            raw: "SpeakerGate, 123, DeepFilterNet",
            keywords: ["SpeakerGate", "DeepFilterNet"],
            dropped: [ScreenContextDroppedTerm(term: "123", reason: "numeric")]
        ))
        let recorder = ActivityRecorder()
        let (c, _, _) = makeCoordinator(
            engine: engine,
            capture: shot("com.a", "Doc", "pixels"),
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
        #expect(a.source == .screenshot)
    }

    @Test func extraction_failed_records_the_image_size_but_no_raw_response() async {
        let engine = SpyEngine()
        engine.stubbedImageResult = .failed
        let recorder = ActivityRecorder()
        let capture = shot("com.a", "Doc", "flaky pixels")
        let (c, _, _) = makeCoordinator(
            engine: engine, capture: capture, frontmostBundleID: "com.a", activityRecorder: recorder
        )
        await c.refresh(now: t0)
        let activities = await recorder.activities
        #expect(activities.count == 1)
        #expect(activities.first?.outcome == .extractionFailed)
        #expect(activities.first?.source == .screenshot)
        #expect(activities.first?.capturedImageBytes == capture.pngData.count)
        #expect(activities.first?.rawResponse == nil)
        #expect(activities.first?.appliedKeywords == [])
    }

    @Test func no_vision_fallback_records_the_accessibility_source_and_its_text() async {
        // Exactly one activity for the whole refresh, describing where
        // the keywords actually came from — the fallback must not
        // emit a second, contradictory record for the image attempt.
        let engine = SpyEngine()
        engine.stubbedImageResult = .noVision
        let recorder = ActivityRecorder()
        let (c, _, _) = makeCoordinator(
            engine: engine,
            capture: shot("com.a", "Doc", "pixels"),
            snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "AX window text"),
            frontmostBundleID: "com.a",
            activityRecorder: recorder
        )
        await c.refresh(now: t0)
        let activities = await recorder.activities
        #expect(activities.count == 1)
        let a = activities[0]
        #expect(a.outcome == .extractionSucceeded)
        #expect(a.source == .accessibility)
        #expect(a.capturedText == "AX window text")
        #expect(a.capturedTextLength == "AX window text".count)
        #expect(a.capturedImageBytes == nil)
        #expect(a.appliedKeywords == ["AXKeyword"])
        // Same fallback, different reason — this one is the model's
        // fault, not the screenshot's.
        #expect(a.fallbackReason == .noVision)
    }

    @Test func the_screenshot_path_records_the_pixel_dimensions_and_no_fallback_reason() async {
        let engine = SpyEngine()
        let recorder = ActivityRecorder()
        let capture = shot("com.a", "Doc", "pixels", pixels: ScreenContextPixelSize(width: 1568, height: 902))
        let (c, _, _) = makeCoordinator(
            engine: engine, capture: capture, frontmostBundleID: "com.a", activityRecorder: recorder
        )
        await c.refresh(now: t0)
        let activities = await recorder.activities
        #expect(activities.count == 1)
        #expect(activities.first?.source == .screenshot)
        #expect(activities.first?.capturedImageBytes == capture.pngData.count)
        #expect(activities.first?.capturedImagePixelSize == ScreenContextPixelSize(width: 1568, height: 902))
        // Nothing fell back, so there is no reason to report.
        #expect(activities.first?.fallbackReason == nil)
    }
}
