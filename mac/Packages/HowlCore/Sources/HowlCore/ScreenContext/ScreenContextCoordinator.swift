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
    private let extract: @Sendable (String) async -> ScreenKeywordExtraction?
    private let apply: @Sendable ([String]) async -> Void
    /// Fires once per `refresh()` outcome, carrying the full diagnostic
    /// record for the "before/after" inspector. Follows the same
    /// injected-closure pattern as every other dependency here — see
    /// the type header comment — so the policy (including what counts
    /// as `.superseded`) stays testable without a live UI store.
    private let onActivity: @Sendable (ScreenContextActivity) async -> Void

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
        extract: @escaping @Sendable (String) async -> ScreenKeywordExtraction?,
        apply: @escaping @Sendable ([String]) async -> Void,
        onActivity: @escaping @Sendable (ScreenContextActivity) async -> Void
    ) {
        self.reader = reader
        self.cache = cache
        self.denylist = denylist
        self.isEnabled = isEnabled
        self.frontmostBundleID = frontmostBundleID
        self.extract = extract
        self.apply = apply
        self.onActivity = onActivity
    }

    /// Re-derive keywords for whatever window is focused right now.
    /// Never throws and never blocks a dictation: every failure path
    /// ends in dictionary-only behaviour.
    public func refresh(now: Date = Date()) async {
        generation &+= 1
        let myGeneration = generation

        // Disabled must CLEAR any previously-applied keywords, not just
        // skip applying new ones — mirroring the denylist path four
        // lines below. Returning bare here would stop the reading but
        // not the effect: whatever was applied before the user unticked
        // the setting would keep biasing whisper on every subsequent
        // dictation until the app relaunches, since `howl_start_capture`
        // applies the engine's last-set `screenKeywords` unconditionally
        // on every capture and nothing else ever clears them.
        guard isEnabled() else {
            await recordAndApply([], myGeneration: myGeneration, now: now, bundleID: nil, outcome: .disabled)
            return
        }

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
        let frontID = await frontmostBundleID()
        if denylist().shouldSkip(bundleID: frontID) {
            log.notice("screen context skipped for denylisted app")
            await recordAndApply([], myGeneration: myGeneration, now: now, bundleID: frontID, outcome: .skippedPreReadDenylist)
            return
        }

        guard let snapshot = await reader.read() else {
            // No readable window — clear rather than leave the previous
            // window's keywords armed.
            await recordAndApply([], myGeneration: myGeneration, now: now, bundleID: frontID, outcome: .noReadableWindowText)
            return
        }

        // Second, authoritative gate: the snapshot's own bundle ID.
        // The frontmost-app lookup above and this read aren't atomic
        // with each other, so re-check against the ID the text
        // actually came from — defence in depth, not redundant.
        //
        // The activity recorded here deliberately omits the captured
        // text even though a read may already have happened — see
        // `ScreenContextActivity.capturedText`'s doc comment: this gate
        // is the actual guarantee, and leaking the text into an
        // in-memory diagnostic would defeat it.
        if denylist().shouldSkip(bundleID: snapshot.bundleID) {
            log.notice("screen context skipped for denylisted app")
            await recordAndApply([], myGeneration: myGeneration, now: now, bundleID: snapshot.bundleID, outcome: .skippedPostReadDenylist)
            return
        }

        let key = cache.key(
            bundleID: snapshot.bundleID,
            windowTitle: snapshot.windowTitle,
            text: snapshot.text
        )
        if let cached = cache.value(for: key, now: now) {
            await recordAndApply(
                cached, myGeneration: myGeneration, now: now, bundleID: snapshot.bundleID, outcome: .cacheHit,
                capturedText: snapshot.text, capturedTextSource: snapshot.source, capturedTextLength: snapshot.text.count
            )
            return
        }

        guard let extraction = await extract(snapshot.text) else {
            // Extraction FAILED (provider unreachable, rate-limited,
            // timed out, malformed response) — distinct from "the LLM
            // ran and found nothing". Never cache a failure: doing so
            // would disable screen context for this exact window
            // content for the full cache TTL over one transient blip.
            // Still clear rather than leave a stale window's keywords
            // armed for the next dictation.
            log.notice("screen context extraction failed")
            await recordAndApply(
                [], myGeneration: myGeneration, now: now, bundleID: snapshot.bundleID, outcome: .extractionFailed,
                capturedText: snapshot.text, capturedTextSource: snapshot.source, capturedTextLength: snapshot.text.count
            )
            return
        }
        cache.store(extraction.keywords, for: key, now: now)
        let applied = await recordAndApply(
            extraction.keywords, myGeneration: myGeneration, now: now, bundleID: snapshot.bundleID, outcome: .extractionSucceeded,
            capturedText: snapshot.text, capturedTextSource: snapshot.source, capturedTextLength: snapshot.text.count,
            rawResponse: extraction.raw, dropped: extraction.dropped
        )
        if applied {
            // Deliberately logs the COUNT, never the terms or window text.
            log.notice("screen context applied \(extraction.keywords.count, privacy: .public) keyword(s)")
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

    /// Applies `keywords` via `applyIfCurrent`, then emits exactly one
    /// `ScreenContextActivity` recording what actually happened.
    ///
    /// `outcome` is the caller's intended outcome, but the RECORDED
    /// outcome is `.superseded` whenever the apply itself didn't run —
    /// whether because a newer `refresh` already bumped `generation`,
    /// or because `scheduleRefresh` cancelled this call's Task. Either
    /// way nothing was actually applied, so reporting the caller's
    /// original outcome would misrepresent what the user's dictation
    /// actually saw; `.superseded` is the truthful record. Returns
    /// whether the apply ran, exactly like `applyIfCurrent`.
    @discardableResult
    private func recordAndApply(
        _ keywords: [String],
        myGeneration: UInt64,
        now: Date,
        bundleID: String?,
        outcome: ScreenContextActivity.Outcome,
        capturedText: String? = nil,
        capturedTextSource: WindowTextSource? = nil,
        capturedTextLength: Int? = nil,
        rawResponse: String? = nil,
        dropped: [ScreenContextDroppedTerm] = []
    ) async -> Bool {
        let applied = await applyIfCurrent(keywords, myGeneration: myGeneration)
        let activity = ScreenContextActivity(
            timestamp: now,
            bundleID: bundleID,
            outcome: applied ? outcome : .superseded,
            capturedText: capturedText,
            capturedTextSource: capturedTextSource,
            capturedTextLength: capturedTextLength,
            rawResponse: rawResponse,
            dropped: dropped,
            appliedKeywords: applied ? keywords : []
        )
        await onActivity(activity)
        return applied
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
