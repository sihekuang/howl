import Foundation
import Testing
@testable import HowlCore

private final class SpyEngine: @unchecked Sendable {
    var extractCalls = 0
    var lastExtractText = ""
    var setCalls: [[String]] = []
    var stubbedKeywords: [String] = ["SpeakerGate"]

    func extract(_ text: String) async -> [String] {
        extractCalls += 1
        lastExtractText = text
        return stubbedKeywords
    }
    func set(_ keywords: [String]) async {
        setCalls.append(keywords)
    }
}

private struct StubReader: WindowTextReader {
    let snapshot: WindowSnapshot?
    func read() async -> WindowSnapshot? { snapshot }
}

private func makeCoordinator(
    engine: SpyEngine,
    snapshot: WindowSnapshot?,
    enabled: Bool = true,
    denylist: [String] = [],
    cache: ScreenContextCache = ScreenContextCache()
) -> ScreenContextCoordinator {
    ScreenContextCoordinator(
        reader: StubReader(snapshot: snapshot),
        cache: cache,
        denylist: { ScreenContextDenylist(userAdditions: denylist) },
        isEnabled: { enabled },
        extract: { await engine.extract($0) },
        apply: { await engine.set($0) }
    )
}

private let t0 = Date(timeIntervalSince1970: 2_000_000)

@Suite("ScreenContextCoordinator")
struct ScreenContextCoordinatorTests {

    @Test func extracts_and_applies_keywords_on_refresh() async {
        let engine = SpyEngine()
        let c = makeCoordinator(engine: engine, snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "SpeakerGate lives here"))
        await c.refresh(now: t0)
        #expect(engine.extractCalls == 1)
        #expect(engine.setCalls == [["SpeakerGate"]])
    }

    @Test func does_nothing_when_disabled() async {
        let engine = SpyEngine()
        let c = makeCoordinator(engine: engine, snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "text"), enabled: false)
        await c.refresh(now: t0)
        #expect(engine.extractCalls == 0)
        #expect(engine.setCalls.isEmpty)
    }

    @Test func denylisted_app_is_never_read_or_extracted() async {
        let engine = SpyEngine()
        let c = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.1password.1password", windowTitle: "Vault", text: "hunter2"),
            denylist: []
        )
        await c.refresh(now: t0)
        #expect(engine.extractCalls == 0)
    }

    @Test func denylisted_app_clears_stale_keywords() async {
        // Focusing a denylisted app must not leave the previous
        // window's keywords armed for the next dictation.
        let engine = SpyEngine()
        let c = makeCoordinator(
            engine: engine,
            snapshot: WindowSnapshot(bundleID: "com.1password.1password", windowTitle: "Vault", text: "hunter2"),
            denylist: []
        )
        await c.refresh(now: t0)
        #expect(engine.setCalls == [[]])
    }

    @Test func second_refresh_of_unchanged_window_hits_cache() async {
        let engine = SpyEngine()
        let cache = ScreenContextCache()
        let snapshot = WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "unchanged text")
        let c = makeCoordinator(engine: engine, snapshot: snapshot, cache: cache)

        await c.refresh(now: t0)
        await c.refresh(now: t0)

        #expect(engine.extractCalls == 1)          // no second network call
        #expect(engine.setCalls.count == 2)        // but keywords re-applied
    }

    @Test func nil_snapshot_clears_keywords_without_extracting() async {
        let engine = SpyEngine()
        let c = makeCoordinator(engine: engine, snapshot: nil)
        await c.refresh(now: t0)
        #expect(engine.extractCalls == 0)
        #expect(engine.setCalls == [[]])
    }

    @Test func window_text_is_forwarded_verbatim_to_the_extractor() async {
        let engine = SpyEngine()
        let c = makeCoordinator(engine: engine, snapshot: WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "the exact text"))
        await c.refresh(now: t0)
        #expect(engine.lastExtractText == "the exact text")
    }
}
