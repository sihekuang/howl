import Foundation
import OSLog

/// Orchestrates frontmost-app gate → denylist → read → denylist (again)
/// → cache → extract → apply.
///
/// Dependencies arrive as closures so the whole policy is testable
/// without AppKit, a live engine, or a network.
public actor ScreenContextCoordinator {
    private let reader: any WindowTextReader
    private let cache: ScreenContextCache
    private let denylist: @Sendable () -> ScreenContextDenylist
    private let isEnabled: @Sendable () -> Bool
    private let frontmostBundleID: @Sendable () async -> String?
    private let extract: @Sendable (String) async -> [String]?
    private let apply: @Sendable ([String]) async -> Void

    // `.notice` and above persist in the unified log; `.debug`/`.info` do
    // not survive past the live stream. These four lines are the entire
    // diagnostic trail for "is screen context working, and if not why",
    // so they must be readable after the fact from a user's machine:
    //   /usr/bin/log show --predicate 'subsystem == "com.howl.app"' --last 10m
    // They carry only counts and fixed strings — never window text, never a
    // provider error body. Anything below is internals and stays at .debug.
    private let log = Logger(subsystem: "com.howl.app", category: "screencontext")
    private var inFlight: Task<Void, Never>?

    // Monotonic generation counter. Stamped at entry to every `refresh`
    // and re-checked immediately before every `apply` call: if a newer
    // refresh has started since this one began, this one's result is
    // stale and must be dropped rather than clobbering the newer
    // window's already-applied keywords. `Task.isCancelled` alone is
    // not enough — cancelling a Task is cooperative and the blocking
    // C call inside `extract` can't observe it, so a "cancelled"
    // extraction still runs to completion and would still apply its
    // (now stale) result without this check.
    private var generation: UInt64 = 0

    public init(
        reader: any WindowTextReader,
        cache: ScreenContextCache,
        denylist: @escaping @Sendable () -> ScreenContextDenylist,
        isEnabled: @escaping @Sendable () -> Bool,
        frontmostBundleID: @escaping @Sendable () async -> String?,
        extract: @escaping @Sendable (String) async -> [String]?,
        apply: @escaping @Sendable ([String]) async -> Void
    ) {
        self.reader = reader
        self.cache = cache
        self.denylist = denylist
        self.isEnabled = isEnabled
        self.frontmostBundleID = frontmostBundleID
        self.extract = extract
        self.apply = apply
    }

    /// Re-derive keywords for whatever window is focused right now.
    /// Never throws and never blocks a dictation: every failure path
    /// ends in dictionary-only behaviour.
    public func refresh(now: Date = Date()) async {
        generation &+= 1
        let myGeneration = generation

        guard isEnabled() else { return }

        // Gate BEFORE any read happens. `frontmostBundleID` is queried
        // from the OS directly (no AX walk, no screenshot) so a
        // denylisted app's window is never touched at all — not by AX,
        // and never falls through to OCR. `shouldSkip` fails closed on
        // nil, so "we don't know what's focused" also skips.
        //
        // `async` because `NSWorkspace.frontmostApplication` has to be
        // read on the main actor (see `AXWindowTextReader.read()`, whose
        // hop is documented as NOT removable), and `refresh` runs on
        // this actor rather than the main one — so the caller needs
        // somewhere to put that hop. A synchronous closure would leave
        // the wiring no option but a bare off-main `NSWorkspace` read.
        //
        // The suspension means the frontmost app can change before the
        // read below, so this gate is a best-effort early-out, not the
        // authoritative one. It always was: the reader performs its own
        // frontmost lookup, so the two observations were never atomic
        // even when this call was synchronous. The authoritative check
        // is the post-read gate on the snapshot's own bundle ID.
        if denylist().shouldSkip(bundleID: await frontmostBundleID()) {
            log.notice("screen context skipped for denylisted app")
            await applyIfCurrent([], myGeneration: myGeneration)
            return
        }

        guard let snapshot = await reader.read() else {
            // No readable window — clear rather than leave the previous
            // window's keywords armed.
            await applyIfCurrent([], myGeneration: myGeneration)
            return
        }

        // Second, authoritative gate: the snapshot's own bundle ID.
        // The frontmost-app lookup above and this read aren't atomic
        // with each other, so re-check against the ID the text
        // actually came from — defence in depth, not redundant.
        if denylist().shouldSkip(bundleID: snapshot.bundleID) {
            log.notice("screen context skipped for denylisted app")
            await applyIfCurrent([], myGeneration: myGeneration)
            return
        }

        let key = cache.key(
            bundleID: snapshot.bundleID,
            windowTitle: snapshot.windowTitle,
            text: snapshot.text
        )
        if let cached = cache.value(for: key, now: now) {
            await applyIfCurrent(cached, myGeneration: myGeneration)
            return
        }

        guard let keywords = await extract(snapshot.text) else {
            // Extraction FAILED (provider unreachable, rate-limited,
            // timed out, malformed response) — distinct from "the LLM
            // ran and found nothing". Never cache a failure: doing so
            // would disable screen context for this exact window
            // content for the full cache TTL over one transient blip.
            // Still clear rather than leave a stale window's keywords
            // armed for the next dictation.
            log.notice("screen context extraction failed")
            await applyIfCurrent([], myGeneration: myGeneration)
            return
        }
        cache.store(keywords, for: key, now: now)
        if await applyIfCurrent(keywords, myGeneration: myGeneration) {
            // Deliberately logs the COUNT, never the terms or window text.
            log.notice("screen context applied \(keywords.count, privacy: .public) keyword(s)")
        }
    }

    /// Applies `keywords` only if no newer `refresh` has started since
    /// this call began (see `generation`) and this call's own Task
    /// hasn't been cancelled. Returns whether the apply actually ran.
    @discardableResult
    private func applyIfCurrent(_ keywords: [String], myGeneration: UInt64) async -> Bool {
        guard myGeneration == generation, !Task.isCancelled else { return false }
        await apply(keywords)
        return true
    }

    /// Schedule a refresh, superseding any still running — a newer
    /// window's context always wins over a stale in-flight extraction.
    public func scheduleRefresh() {
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            await self?.refresh()
        }
    }
}
