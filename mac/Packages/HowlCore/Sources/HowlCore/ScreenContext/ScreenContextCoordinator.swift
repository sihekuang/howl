import Foundation
import OSLog

/// Orchestrates enabled gate → denylist → capture → denylist (again)
/// → cache → extract → apply.
///
/// The primary path sends a screenshot of the focused window to a
/// vision model. Whenever pixels are unavailable this falls back — for
/// that refresh — to the Accessibility text path. Two things make
/// pixels unavailable, and both take the fallback: the configured
/// provider+model rejects images (Go reports `no_vision`), or no
/// screenshot could be taken at all. Which one it was is recorded as
/// the activity's `fallbackReason`. Nothing else in the chain differs:
/// both paths produce the same term list and feed the same sanitize →
/// prompt → apply chain.
///
/// Dependencies arrive as closures so the whole policy is testable
/// without AppKit, ScreenCaptureKit, a live engine, or a network.
public actor ScreenContextCoordinator {
    private let capturer: any WindowImageCapturing
    /// The no-pixels fallback. See `AXWindowTextReader` for why it is
    /// still here and must stay healthy.
    private let textReader: any WindowTextReader
    private let cache: ScreenContextCache
    private let denylist: @Sendable () -> ScreenContextDenylist
    private let isEnabled: @Sendable () -> Bool
    private let frontmostBundleID: @Sendable () async -> String?
    private let extractImage: @Sendable (Data) async -> ScreenImageExtractionResult
    private let extractText: @Sendable (String) async -> ScreenKeywordExtraction?
    private let apply: @Sendable ([String]) async -> Void
    /// Fires once per `refresh()` outcome, carrying the full diagnostic
    /// record for the "before/after" inspector. Follows the same
    /// injected-closure pattern as every other dependency here — see
    /// the type header comment — so the policy (including what counts
    /// as `.superseded`) stays testable without a live UI store.
    private let onActivity: @Sendable (ScreenContextActivity) async -> Void

    // `.notice` and above persist in the unified log; `.debug`/`.info` do
    // not survive past the live stream. These log lines are the entire
    // diagnostic trail for "is screen context working, and if not why",
    // so they must be readable after the fact from a user's machine:
    //   /usr/bin/log show --predicate 'subsystem == "com.howl.app"' --last 10m
    // They carry only counts and fixed strings — never window text, never
    // image bytes, never a provider error body. Anything below is
    // internals and stays at .debug.
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
        capturer: any WindowImageCapturing,
        textReader: any WindowTextReader,
        cache: ScreenContextCache,
        denylist: @escaping @Sendable () -> ScreenContextDenylist,
        isEnabled: @escaping @Sendable () -> Bool,
        frontmostBundleID: @escaping @Sendable () async -> String?,
        extractImage: @escaping @Sendable (Data) async -> ScreenImageExtractionResult,
        extractText: @escaping @Sendable (String) async -> ScreenKeywordExtraction?,
        apply: @escaping @Sendable ([String]) async -> Void,
        onActivity: @escaping @Sendable (ScreenContextActivity) async -> Void
    ) {
        self.capturer = capturer
        self.textReader = textReader
        self.cache = cache
        self.denylist = denylist
        self.isEnabled = isEnabled
        self.frontmostBundleID = frontmostBundleID
        self.extractImage = extractImage
        self.extractText = extractText
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
        // lines below. Returning bare here would stop the capture but
        // not the effect: whatever was applied before the user unticked
        // the setting would keep biasing whisper on every subsequent
        // dictation until the app relaunches, since `howl_start_capture`
        // applies the engine's last-set `screenKeywords` unconditionally
        // on every capture and nothing else ever clears them.
        guard isEnabled() else {
            await recordAndApply([], myGeneration: myGeneration, now: now, bundleID: nil, outcome: .disabled)
            return
        }

        // Gate BEFORE anything is captured. `frontmostBundleID` is
        // queried from the OS directly (no screenshot, no AX walk) so a
        // denylisted app's window is never touched at all — and, since
        // this precedes every ScreenCaptureKit call, never triggers the
        // Screen Recording prompt either. `shouldSkip` fails closed on
        // nil, so "we don't know what's focused" also skips.
        //
        // `async` because `NSWorkspace.frontmostApplication` has to be
        // read on the main actor (see `defaultFrontmostApp`, whose hop
        // is documented as NOT removable), and `refresh` runs on this
        // actor rather than the main one — so the caller needs
        // somewhere to put that hop. A synchronous closure would leave
        // the wiring no option but a bare off-main `NSWorkspace` read.
        //
        // The suspension means the frontmost app can change before the
        // capture below, so this gate is a best-effort early-out, not
        // the authoritative one. It always was: the capturer performs
        // its own frontmost lookup, so the two observations were never
        // atomic even when this call was synchronous. The
        // authoritative check is `resolveReadableFrontmostApp` inside
        // the capturer — which resolves identity and applies the
        // denylist with no suspension in between — backed by the
        // post-capture gate on the capture's own bundle ID.
        let frontID = await frontmostBundleID()
        if denylist().shouldSkip(bundleID: frontID) {
            log.notice("screen context skipped for denylisted app")
            await recordAndApply([], myGeneration: myGeneration, now: now, bundleID: frontID, outcome: .skippedPreReadDenylist)
            return
        }

        guard let capture = await capturer.capture() else {
            // No screenshot — Screen Recording denied, no on-screen
            // window, or the window vanished mid-capture.
            //
            // RULE: no pixels means the AX text path, not a dead end.
            // The AX path is the no-pixels fallback, and "the model
            // cannot see" and "there is nothing to show it" are the
            // same situation from the pipeline's point of view.
            //
            // This deliberately reverses an earlier rule that cleared
            // and returned here rather than "silently giving a user who
            // denied Screen Recording a different, differently-priced
            // pipeline than the one they think is off". That reasoning
            // does not survive contact with the permissions: Screen
            // Recording denial is a statement about screenshots, not
            // about screen context — what turns the feature off is its
            // own Settings toggle, which this user left on — while
            // Accessibility is a separate permission Howl already holds
            // for paste injection. The image → text direction is also
            // cheaper, not pricier. Against that, clearing here costs a
            // silent, total, permanent loss of the feature on a very
            // likely path: "a dictation app wants to record your
            // screen" is exactly the prompt people decline.
            //
            // What answers the original worry is visibility, not
            // refusal: one persisted `.notice` below, and
            // `fallbackReason` on every record this path produces, so
            // the inspector can say "the screenshot failed, so this
            // came from accessibility text".
            //
            // Both denylist gates still apply on this path:
            // `AXWindowTextReader.read()` enforces the denylist
            // internally via `resolveReadableFrontmostApp`, and
            // `refreshFromAccessibilityText` re-gates on the snapshot's
            // own bundle ID afterwards.
            log.notice("screen context screenshot unavailable; using accessibility text")
            await refreshFromAccessibilityText(
                myGeneration: myGeneration, now: now, frontID: frontID,
                reason: .screenshotUnavailable
            )
            return
        }

        // Second, authoritative gate: the capture's own bundle ID.
        // The frontmost-app lookup above and this capture aren't atomic
        // with each other, so re-check against the ID the pixels
        // actually came from — defence in depth, not redundant.
        //
        // The activity recorded here deliberately omits every trace of
        // what was captured — see `ScreenContextActivity.capturedText`'s
        // doc comment: this gate is the actual guarantee, and leaking
        // the payload into an in-memory diagnostic would defeat it.
        if denylist().shouldSkip(bundleID: capture.bundleID) {
            log.notice("screen context skipped for denylisted app")
            await recordAndApply([], myGeneration: myGeneration, now: now, bundleID: capture.bundleID, outcome: .skippedPostReadDenylist)
            return
        }

        let imageBytes = capture.pngData.count
        let imagePixels = capture.pixelSize
        let key = cache.key(
            bundleID: capture.bundleID,
            windowTitle: capture.windowTitle,
            imageData: capture.pngData
        )
        if let cached = cache.value(for: key, now: now) {
            await recordAndApply(
                cached, myGeneration: myGeneration, now: now, bundleID: capture.bundleID, outcome: .cacheHit,
                source: .screenshot, capturedImageBytes: imageBytes, capturedImagePixelSize: imagePixels
            )
            return
        }

        switch await extractImage(capture.pngData) {
        case .success(let extraction):
            cache.store(extraction.keywords, for: key, now: now)
            let applied = await recordAndApply(
                extraction.keywords, myGeneration: myGeneration, now: now, bundleID: capture.bundleID,
                outcome: .extractionSucceeded, source: .screenshot, capturedImageBytes: imageBytes,
                capturedImagePixelSize: imagePixels,
                rawResponse: extraction.raw, dropped: extraction.dropped
            )
            if applied {
                // Deliberately logs the COUNT, never the terms.
                log.notice("screen context applied \(extraction.keywords.count, privacy: .public) keyword(s)")
            }

        case .failed:
            // Extraction FAILED (provider unreachable, rate-limited,
            // timed out, malformed response) — distinct from "the model
            // ran and found nothing". Never cache a failure: doing so
            // would disable screen context for this exact screenshot
            // for the full cache TTL over one transient blip. Still
            // clear rather than leave a stale window's keywords armed
            // for the next dictation.
            log.notice("screen context extraction failed")
            await recordAndApply(
                [], myGeneration: myGeneration, now: now, bundleID: capture.bundleID,
                outcome: .extractionFailed, source: .screenshot, capturedImageBytes: imageBytes,
                capturedImagePixelSize: imagePixels
            )

        case .noVision:
            // This provider+model cannot accept images. Go has cached
            // that verdict for the session (keyed on provider+model, so
            // a settings change re-probes), which is why this is not
            // also cached here: a Swift-side latch would survive a
            // model change that Go correctly re-probes, and would be
            // wrong for the rest of the session. The screenshot we just
            // took is wasted, but only the encode — no round trip.
            log.notice("screen context vision unavailable; using accessibility text")
            await refreshFromAccessibilityText(
                myGeneration: myGeneration, now: now, frontID: frontID, reason: .noVision
            )
        }
    }

    /// The no-pixels fallback: read the focused window's text through
    /// the Accessibility API and extract from that instead. Reached
    /// either because the model cannot accept images (`.noVision`) or
    /// because no screenshot could be taken (`.screenshotUnavailable`).
    ///
    /// Runs the same gate → cache → extract → apply shape as the image
    /// path, with its own reader-enforced denylist check inside
    /// `AXWindowTextReader.read()` and its own post-read gate here, so
    /// the fallback is no weaker a guarantee than the primary path.
    ///
    /// `reason` is threaded onto every record this produces rather than
    /// replacing the outcome: the AX read's own result is what the
    /// outcome describes, and why the image path was skipped is a
    /// second, independent fact the inspector needs. Losing it would
    /// leave a user unable to tell "change your model" from "grant
    /// Screen Recording".
    private func refreshFromAccessibilityText(
        myGeneration: UInt64, now: Date, frontID: String?, reason: ScreenContextFallbackReason
    ) async {
        guard let snapshot = await textReader.read() else {
            await recordAndApply(
                [], myGeneration: myGeneration, now: now, bundleID: frontID,
                outcome: .noReadableWindowText, fallbackReason: reason
            )
            return
        }

        if denylist().shouldSkip(bundleID: snapshot.bundleID) {
            log.notice("screen context skipped for denylisted app")
            await recordAndApply(
                [], myGeneration: myGeneration, now: now, bundleID: snapshot.bundleID,
                outcome: .skippedPostReadDenylist, fallbackReason: reason
            )
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
                source: .accessibility, fallbackReason: reason,
                capturedText: snapshot.text, capturedTextLength: snapshot.text.count
            )
            return
        }

        guard let extraction = await extractText(snapshot.text) else {
            log.notice("screen context extraction failed")
            await recordAndApply(
                [], myGeneration: myGeneration, now: now, bundleID: snapshot.bundleID, outcome: .extractionFailed,
                source: .accessibility, fallbackReason: reason,
                capturedText: snapshot.text, capturedTextLength: snapshot.text.count
            )
            return
        }
        cache.store(extraction.keywords, for: key, now: now)
        let applied = await recordAndApply(
            extraction.keywords, myGeneration: myGeneration, now: now, bundleID: snapshot.bundleID,
            outcome: .extractionSucceeded, source: .accessibility, fallbackReason: reason,
            capturedText: snapshot.text, capturedTextLength: snapshot.text.count,
            rawResponse: extraction.raw, dropped: extraction.dropped
        )
        if applied {
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
        source: ScreenContextSource? = nil,
        fallbackReason: ScreenContextFallbackReason? = nil,
        capturedText: String? = nil,
        capturedTextLength: Int? = nil,
        capturedImageBytes: Int? = nil,
        capturedImagePixelSize: ScreenContextPixelSize? = nil,
        rawResponse: String? = nil,
        dropped: [ScreenContextDroppedTerm] = []
    ) async -> Bool {
        let applied = await applyIfCurrent(keywords, myGeneration: myGeneration)
        let activity = ScreenContextActivity(
            timestamp: now,
            bundleID: bundleID,
            outcome: applied ? outcome : .superseded,
            source: source,
            capturedText: capturedText,
            capturedTextLength: capturedTextLength,
            capturedImageBytes: capturedImageBytes,
            capturedImagePixelSize: capturedImagePixelSize,
            fallbackReason: fallbackReason,
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
