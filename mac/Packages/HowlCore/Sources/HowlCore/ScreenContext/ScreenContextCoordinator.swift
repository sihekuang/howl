import Foundation
import OSLog

/// Orchestrates enabled gate → denylist → read → denylist (again) →
/// cache → extract → apply.
///
/// It knows NOTHING about how the window is read. A single
/// `ScreenContentSource` — OCR over a screenshot, a screenshot for a
/// vision model, the Accessibility tree, or any composition of them —
/// hands it a `ScreenContent`, and the only thing it decides from that
/// is which Go extractor the shape calls for: text goes to
/// `extractText`, pixels to `extractImage`. Swapping strategies is
/// therefore one expression in `CompositionRoot`, and nothing in here
/// moves.
///
/// The one exception, and it is not a leak: when the image extractor
/// reports that the configured model cannot accept images at all
/// (`.noVision`), the coordinator asks the source for an alternate
/// reading. That verdict is about the extractor, not about the window,
/// so no source could have discovered it — but the coordinator still
/// never learns what the alternate is.
///
/// Dependencies arrive as closures so the whole policy is testable
/// without AppKit, ScreenCaptureKit, Vision, a live engine, or a
/// network.
public actor ScreenContextCoordinator {
    /// THE strategy. See `ScreenContentSource`.
    private let source: any ScreenContentSource
    private let cache: ScreenContextCache
    /// Second chance behind `cache`, consulted only on an exact-hash
    /// miss. See `ScreenContextSimilarityCache`.
    private let similarityCache: ScreenContextSimilarityCache
    /// Jaccard overlap at or above which a fresh reading counts as
    /// unchanged. A closure rather than a stored value so the number
    /// can later be driven from settings without reshaping the graph;
    /// today every caller passes the default constant.
    private let similarityThreshold: @Sendable () -> Double
    /// Floor on how often one window is re-extracted, whatever the
    /// gate says. See `ScreenContextLimits.minExtractionInterval`.
    private let minExtractionInterval: TimeInterval
    /// Aborts the provider request behind `extractText`. Swift's
    /// cancellation is cooperative and the blocking C call cannot see
    /// it, so without this a superseded extraction ran to completion
    /// (or its 60s timeout) while its replacement queued behind it.
    private let cancelExtraction: @Sendable () -> Void
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

    /// The one LLM extraction allowed in flight. Every refresh that
    /// needs an extraction for the SAME window joins this one instead
    /// of starting another — the periodic tick landing mid-call is the
    /// common case — and a refresh for a DIFFERENT window aborts it.
    /// A class, not a struct: refreshes that join need to see the
    /// same `participants`/`cancelled` the starter does.
    private final class InFlightExtraction {
        let identity: String
        let task: Task<ScreenKeywordExtraction?, Never>
        /// The refresh that started this call. A refresh that outranks
        /// it and is not among `participants` has no use for the
        /// result, and says so by cancelling it when it finishes (see
        /// `refresh`). An OLDER refresh finishing late — typically one
        /// whose own extraction this call displaced — must leave it
        /// alone, which is what `startedBy` is compared against.
        let startedBy: UInt64
        /// Generations of every refresh awaiting this call, starter
        /// included.
        var participants: Set<UInt64>
        var cancelled = false

        init(identity: String, task: Task<ScreenKeywordExtraction?, Never>, startedBy generation: UInt64) {
            self.identity = identity
            self.task = task
            self.startedBy = generation
            self.participants = [generation]
        }
    }
    private var inFlightExtraction: InFlightExtraction?

    private enum ExtractionResult {
        case finished(ScreenKeywordExtraction?)
        case cancelled
    }

    /// The (outcome, bundleID) of the last activity actually recorded,
    /// used to coalesce a repeating denylist skip into one entry.
    ///
    /// The periodic scan is what makes this necessary. Howl's own
    /// windows are denylisted, the inspector that shows these records
    /// lives INSIDE a Howl window, and the activity buffer holds 50
    /// entries — so without coalescing, sitting on the Screen Context
    /// tab for twelve minutes would evict the entire history the user
    /// opened it to read and replace it with fifty identical "skipped
    /// (denylist) — Howl" rows. Nothing is lost by collapsing them:
    /// the first one says everything the fiftieth would.
    private var lastRecorded: (outcome: ScreenContextActivity.Outcome, bundleID: String?)?

    public init(
        source: any ScreenContentSource,
        cache: ScreenContextCache,
        similarityCache: ScreenContextSimilarityCache = ScreenContextSimilarityCache(),
        similarityThreshold: @escaping @Sendable () -> Double = { ScreenContextLimits.defaultSimilarityThreshold },
        minExtractionInterval: TimeInterval = ScreenContextLimits.minExtractionInterval,
        denylist: @escaping @Sendable () -> ScreenContextDenylist,
        isEnabled: @escaping @Sendable () -> Bool,
        frontmostBundleID: @escaping @Sendable () async -> String?,
        extractImage: @escaping @Sendable (Data) async -> ScreenImageExtractionResult,
        extractText: @escaping @Sendable (String) async -> ScreenKeywordExtraction?,
        cancelExtraction: @escaping @Sendable () -> Void = {},
        apply: @escaping @Sendable ([String]) async -> Void,
        onActivity: @escaping @Sendable (ScreenContextActivity) async -> Void
    ) {
        self.source = source
        self.similarityCache = similarityCache
        self.similarityThreshold = similarityThreshold
        self.minExtractionInterval = minExtractionInterval
        self.cancelExtraction = cancelExtraction
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
        // Threaded rather than stored, for the same reason
        // `myGeneration` is: `refresh` suspends, so a newer refresh
        // would overwrite a stored instant and every in-flight older
        // one would then report a total measured from the wrong start.
        let startedAt = ContinuousClock().now

        await runRefresh(myGeneration: myGeneration, startedAt: startedAt, now: now)

        // This refresh resolved without needing the extraction that is
        // still running — focus moved to a denylisted app, the feature
        // was switched off, the new window hit a cache. That
        // extraction's result would be dropped by the generation check
        // anyway; stop paying the provider for it.
        if let current = inFlightExtraction,
           current.startedBy < myGeneration,
           !current.participants.contains(myGeneration) {
            abort(current)
        }
    }

    private func runRefresh(myGeneration: UInt64, startedAt: ContinuousClock.Instant, now: Date) async {
        // Disabled must CLEAR any previously-applied keywords, not just
        // skip applying new ones — mirroring the denylist path four
        // lines below. Returning bare here would stop the read but not
        // the effect: whatever was applied before the user unticked
        // the setting would keep biasing whisper on every subsequent
        // dictation until the app relaunches, since `howl_start_capture`
        // applies the engine's last-set `screenKeywords` unconditionally
        // on every capture and nothing else ever clears them.
        guard isEnabled() else {
            await recordAndApply([], myGeneration: myGeneration, startedAt: startedAt, now: now, bundleID: nil, outcome: .disabled)
            return
        }

        // Gate BEFORE anything is read. `frontmostBundleID` is queried
        // from the OS directly (no screenshot, no AX walk) so a
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
        // read below, so this gate is a best-effort early-out, not the
        // authoritative one. It always was: every source performs its
        // own frontmost lookup, so the two observations were never
        // atomic even when this call was synchronous. The
        // authoritative check is `resolveReadableFrontmostApp` inside
        // the source — which resolves identity and applies the denylist
        // with no suspension in between — backed by the post-read gate
        // on the reading's own bundle ID.
        let frontID = await frontmostBundleID()
        if denylist().shouldSkip(bundleID: frontID) {
            log.notice("screen context skipped for denylisted app")
            await recordAndApply([], myGeneration: myGeneration, startedAt: startedAt, now: now, bundleID: frontID, outcome: .skippedPreReadDenylist)
            return
        }

        guard let content = await source.read() else {
            // The installed strategy could not read this window at all
            // — including, for a composed strategy, its fallback. There
            // is nothing left to try and nothing to extract from.
            log.notice("screen context found no readable window content")
            await recordAndApply(
                [], myGeneration: myGeneration, startedAt: startedAt, now: now, bundleID: frontID,
                outcome: .noReadableWindowText
            )
            return
        }
        await extract(content, myGeneration: myGeneration, startedAt: startedAt, now: now, allowAlternate: true)
    }

    /// Gate, cache, extract and apply one reading — whatever shape it
    /// arrived in.
    ///
    /// `allowAlternate` is false for a reading that IS the alternate,
    /// so a source that kept answering `.image` could not loop.
    private func extract(
        _ content: ScreenContent, myGeneration: UInt64,
        startedAt: ContinuousClock.Instant, now: Date, allowAlternate: Bool
    ) async {
        // Second, authoritative gate: the reading's own bundle ID. The
        // frontmost-app lookup in `refresh` and this read aren't atomic
        // with each other, so re-check against the ID the content
        // actually came from — defence in depth, not redundant.
        //
        // The activity recorded here deliberately omits every trace of
        // what was read — see `ScreenContextActivity.capturedText`'s
        // doc comment: this gate is the actual guarantee, and leaking
        // the payload into an in-memory diagnostic would defeat it.
        if denylist().shouldSkip(bundleID: content.bundleID) {
            log.notice("screen context skipped for denylisted app")
            await recordAndApply(
                [], myGeneration: myGeneration, startedAt: startedAt, now: now, bundleID: content.bundleID,
                outcome: .skippedPostReadDenylist, fallbackReason: content.fallbackReason
            )
            return
        }

        // The ONLY thing the coordinator decides from the strategy's
        // output: which extractor its shape calls for.
        switch content {
        case .text(let snapshot):
            await extractFromText(snapshot, myGeneration: myGeneration, startedAt: startedAt, now: now)
        case .image(let capture):
            await extractFromImage(capture, myGeneration: myGeneration, startedAt: startedAt, now: now, allowAlternate: allowAlternate)
        }
    }

    /// Text read on this machine — by OCR over a screenshot, or by the
    /// Accessibility tree. `snapshot.source` says which; the pipeline
    /// from here on is identical, which is the point.
    private func extractFromText(
        _ snapshot: WindowSnapshot, myGeneration: UInt64,
        startedAt: ContinuousClock.Instant, now: Date
    ) async {
        let reason = snapshot.fallbackReason
        guard !snapshot.text.isEmpty else {
            // The window was read successfully and there was nothing
            // legible in it. Not a reason to try anything else: this is
            // an answer, not a missing one.
            await recordAndApply(
                [], myGeneration: myGeneration, startedAt: startedAt, now: now, bundleID: snapshot.bundleID,
                outcome: .noReadableWindowText, source: snapshot.source, fallbackReason: reason,
                capturedImagePixelSize: snapshot.pixelSize,
                timings: snapshot.timings
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
                cached, myGeneration: myGeneration, startedAt: startedAt, now: now, bundleID: snapshot.bundleID, outcome: .cacheHit,
                source: snapshot.source, fallbackReason: reason,
                capturedText: snapshot.text, capturedTextLength: snapshot.text.count,
                capturedImagePixelSize: snapshot.pixelSize,
                timings: snapshot.timings
            )
            return
        }

        // SECOND CHANCE. The exact hash missed, which under the
        // periodic scan usually means something trivial moved — a
        // caret, a hover state, one arriving message — not that the
        // window has genuinely moved on. Ask how much actually changed
        // relative to the reading that produced the keywords currently
        // in force.
        let tokens = ScreenTextSimilarity.tokens(in: snapshot.text)
        let threshold = similarityThreshold()
        // Read BEFORE the extraction below, because a successful one
        // re-anchors this window and this measures against the anchor.
        // nil on the first sight of a window, which is honest: there
        // was nothing to be similar to.
        let priorSimilarity = similarityCache.score(
            bundleID: snapshot.bundleID, windowTitle: snapshot.windowTitle, tokens: tokens, now: now
        )
        if let near = similarityCache.hit(
            bundleID: snapshot.bundleID, windowTitle: snapshot.windowTitle,
            tokens: tokens, now: now, threshold: threshold
        ) {
            // Re-apply rather than leave the engine holding what it
            // has: `refresh` is also reached by a real focus change
            // back to this window, where the engine's current keywords
            // may belong to some other app entirely.
            await recordAndApply(
                near.keywords, myGeneration: myGeneration, startedAt: startedAt, now: now,
                bundleID: snapshot.bundleID, outcome: .unchangedContent,
                source: snapshot.source, fallbackReason: reason,
                capturedText: snapshot.text, capturedTextLength: snapshot.text.count,
                capturedImagePixelSize: snapshot.pixelSize,
                timings: snapshot.timings,
                similarity: near.similarity
            )
            return
        }

        // BACKSTOP. The gate said the content moved, but if this window
        // was extracted less than `minExtractionInterval` ago, the
        // keywords in force are recent enough: re-apply them and record
        // the score. Per window identity, so a real focus change to a
        // new window is never held back by it. Not re-anchored, for
        // the same reason a near-hit is not.
        if let recent = similarityCache.recentKeywords(
            bundleID: snapshot.bundleID, windowTitle: snapshot.windowTitle,
            now: now, within: minExtractionInterval
        ) {
            await recordAndApply(
                recent, myGeneration: myGeneration, startedAt: startedAt, now: now,
                bundleID: snapshot.bundleID, outcome: .extractionRateLimited,
                source: snapshot.source, fallbackReason: reason,
                capturedText: snapshot.text, capturedTextLength: snapshot.text.count,
                capturedImagePixelSize: snapshot.pixelSize,
                timings: snapshot.timings,
                similarity: priorSimilarity
            )
            return
        }

        let extractStart = ContinuousClock().now
        let identity = "\(snapshot.bundleID)\u{0}\(snapshot.windowTitle)"
        let extractionOrNil: ScreenKeywordExtraction?
        switch await runExtraction(text: snapshot.text, identity: identity, myGeneration: myGeneration) {
        case .cancelled:
            log.notice("screen context extraction cancelled; focus moved on")
            await recordAndApply(
                [], myGeneration: myGeneration, startedAt: startedAt, now: now, bundleID: snapshot.bundleID,
                outcome: .extractionCancelled, source: snapshot.source, fallbackReason: reason,
                capturedText: snapshot.text, capturedTextLength: snapshot.text.count,
                capturedImagePixelSize: snapshot.pixelSize,
                timings: snapshot.timings,
                similarity: priorSimilarity
            )
            return
        case .finished(let value):
            extractionOrNil = value
        }
        let extractSeconds = (ContinuousClock().now - extractStart).timeInterval
        // Carried on EVERY outcome below, not just the successful one:
        // a refresh that spent nine seconds in the model and then
        // failed is the case worth seeing.
        let staged = snapshot.timings.addingExtract(extractSeconds)
        guard let extraction = extractionOrNil else {
            // Extraction FAILED (provider unreachable, rate-limited,
            // timed out, malformed response) — distinct from "the model
            // ran and found nothing". Never cache a failure: doing so
            // would disable screen context for this exact window's
            // content for the full cache TTL over one transient blip.
            // Still clear rather than leave a stale window's keywords
            // armed for the next dictation.
            log.notice("screen context extraction failed")
            await recordAndApply(
                [], myGeneration: myGeneration, startedAt: startedAt, now: now, bundleID: snapshot.bundleID, outcome: .extractionFailed,
                source: snapshot.source, fallbackReason: reason,
                capturedText: snapshot.text, capturedTextLength: snapshot.text.count,
                capturedImagePixelSize: snapshot.pixelSize,
                timings: staged
            )
            return
        }
        cache.store(extraction.keywords, for: key, now: now)
        // Re-anchor the similarity reference to THIS reading. Only
        // here, never on a near-hit: the reference has to stay the
        // content the live keywords actually came from, or slow drift
        // never accumulates into a re-extract. See
        // `ScreenContextSimilarityCache`.
        similarityCache.store(
            tokens: tokens, keywords: extraction.keywords,
            bundleID: snapshot.bundleID, windowTitle: snapshot.windowTitle, now: now
        )
        let applied = await recordAndApply(
            extraction.keywords, myGeneration: myGeneration, startedAt: startedAt, now: now, bundleID: snapshot.bundleID,
            outcome: .extractionSucceeded, source: snapshot.source, fallbackReason: reason,
            capturedText: snapshot.text, capturedTextLength: snapshot.text.count,
            capturedImagePixelSize: snapshot.pixelSize,
            rawResponse: extraction.raw, dropped: extraction.dropped,
            timings: staged,
            // The score that sent this reading to the model rather
            // than reusing the last answer — the below-threshold half
            // of the distribution the threshold is tuned from.
            similarity: priorSimilarity
        )
        if applied {
            // Deliberately logs the COUNT, never the terms.
            log.notice("screen context applied \(extraction.keywords.count, privacy: .public) keyword(s)")
        }
    }

    /// Pixels for the provider's vision model, which reads them itself.
    /// The single funnel every text extraction goes through. Same
    /// window as the call in flight: join it. Different window: abort
    /// the stale call — on the Go side too — and start this one.
    private func runExtraction(text: String, identity: String, myGeneration: UInt64) async -> ExtractionResult {
        if let current = inFlightExtraction {
            if current.identity == identity {
                current.participants.insert(myGeneration)
                let value = await current.task.value
                return current.cancelled ? .cancelled : .finished(value)
            }
            abort(current)
        }
        let extractText = self.extractText
        let handle = InFlightExtraction(
            identity: identity,
            task: Task { await extractText(text) },
            startedBy: myGeneration
        )
        inFlightExtraction = handle
        let value = await handle.task.value
        if inFlightExtraction === handle { inFlightExtraction = nil }
        return handle.cancelled ? .cancelled : .finished(value)
    }

    private func abort(_ current: InFlightExtraction) {
        current.cancelled = true
        cancelExtraction()
        current.task.cancel()
        if inFlightExtraction === current { inFlightExtraction = nil }
    }

    private func extractFromImage(
        _ capture: WindowImageCapture, myGeneration: UInt64,
        startedAt: ContinuousClock.Instant, now: Date, allowAlternate: Bool
    ) async {
        let reason = capture.fallbackReason
        let imageBytes = capture.pngData.count
        let imagePixels = capture.pixelSize
        let key = cache.key(
            bundleID: capture.bundleID,
            windowTitle: capture.windowTitle,
            imageData: capture.pngData
        )
        if let cached = cache.value(for: key, now: now) {
            await recordAndApply(
                cached, myGeneration: myGeneration, startedAt: startedAt, now: now, bundleID: capture.bundleID, outcome: .cacheHit,
                source: .screenshot, fallbackReason: reason,
                capturedImageBytes: imageBytes, capturedImagePixelSize: imagePixels,
                timings: capture.timings
            )
            return
        }

        let extractStart = ContinuousClock().now
        let imageResult = await extractImage(capture.pngData)
        let probeSeconds = (ContinuousClock().now - extractStart).timeInterval
        let staged = capture.timings.addingExtract(probeSeconds)
        switch imageResult {
        case .success(let extraction):
            cache.store(extraction.keywords, for: key, now: now)
            let applied = await recordAndApply(
                extraction.keywords, myGeneration: myGeneration, startedAt: startedAt, now: now, bundleID: capture.bundleID,
                outcome: .extractionSucceeded, source: .screenshot, fallbackReason: reason,
                capturedImageBytes: imageBytes, capturedImagePixelSize: imagePixels,
                rawResponse: extraction.raw, dropped: extraction.dropped,
                timings: staged
            )
            if applied {
                log.notice("screen context applied \(extraction.keywords.count, privacy: .public) keyword(s)")
            }

        case .failed:
            // An ordinary blip. Never cached, and never a reason to
            // change strategy — the model can see, it just did not
            // answer this time.
            log.notice("screen context extraction failed")
            await recordAndApply(
                [], myGeneration: myGeneration, startedAt: startedAt, now: now, bundleID: capture.bundleID,
                outcome: .extractionFailed, source: .screenshot, fallbackReason: reason,
                capturedImageBytes: imageBytes, capturedImagePixelSize: imagePixels,
                timings: staged
            )

        case .noVision:
            // This provider+model cannot accept images at all. Go has
            // cached that verdict for the session (keyed on
            // provider+model, so a settings change re-probes), which is
            // why it is not also cached here: a Swift-side latch would
            // survive a model change that Go correctly re-probes.
            //
            // The verdict is about the EXTRACTOR, not the window, so no
            // source could have discovered it — hence asking now for a
            // reading in a shape this model can consume. The
            // coordinator stamps the reason, because it is the only
            // party that knows what just happened.
            log.notice("screen context vision unavailable; asking the source for another reading")
            guard allowAlternate, let alternate = await source.readAlternate() else {
                await recordAndApply(
                    [], myGeneration: myGeneration, startedAt: startedAt, now: now, bundleID: capture.bundleID,
                    outcome: .noReadableWindowText, fallbackReason: .noVision,
                    timings: staged
                )
                return
            }
            await extract(
                // The no-vision probe was a real round trip; carry its
                // cost onto the retry so it is not lost.
                alternate.marked(asFallback: .noVision).addingExtract(probeSeconds),
                myGeneration: myGeneration, startedAt: startedAt, now: now, allowAlternate: false
            )
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
        startedAt: ContinuousClock.Instant,
        now: Date,
        bundleID: String?,
        outcome: ScreenContextActivity.Outcome,
        source: ScreenContextOrigin? = nil,
        fallbackReason: ScreenContextFallbackReason? = nil,
        capturedText: String? = nil,
        capturedTextLength: Int? = nil,
        capturedImageBytes: Int? = nil,
        capturedImagePixelSize: ScreenContextPixelSize? = nil,
        rawResponse: String? = nil,
        dropped: [ScreenContextDroppedTerm] = [],
        timings: ScreenContextTimings = ScreenContextTimings(),
        similarity: Double? = nil
    ) async -> Bool {
        let applied = await applyIfCurrent(keywords, myGeneration: myGeneration)
        // Total is stamped here rather than by the caller so it covers
        // the apply too, and so every outcome gets one — including the
        // early returns, where knowing a refresh was abandoned after
        // 9 seconds is the whole diagnosis.
        let stamped = timings.merging(
            ScreenContextTimings(total: (ContinuousClock().now - startedAt).timeInterval)
        )
        let activity = ScreenContextActivity(
            timestamp: now,
            bundleID: bundleID,
            // A cancelled extraction is by construction never current —
            // something newer displaced it — but "superseded" would hide
            // the fact that matters here: the provider call was aborted,
            // not merely its result discarded.
            outcome: applied || outcome == .extractionCancelled ? outcome : .superseded,
            source: source,
            capturedText: capturedText,
            capturedTextLength: capturedTextLength,
            capturedImageBytes: capturedImageBytes,
            capturedImagePixelSize: capturedImagePixelSize,
            fallbackReason: fallbackReason,
            rawResponse: rawResponse,
            dropped: dropped,
            appliedKeywords: applied ? keywords : [],
            timings: stamped,
            similarity: similarity
        )
        // Coalesce a repeating denylist skip for the same app into a
        // single record. Deliberately narrow: ONLY the two denylist
        // skips, and only when the immediately preceding record was
        // the same skip for the same app. Every other outcome —
        // including a run of `.unchangedContent` ticks — still records
        // every time, because those carry a similarity score that
        // changes tick to tick and is the whole point of the row.
        //
        // The apply above has already happened either way: this
        // suppresses the DIAGNOSTIC, never the behaviour.
        let recordedOutcome = activity.outcome
        let isRepeatedSkip =
            (recordedOutcome == .skippedPreReadDenylist || recordedOutcome == .skippedPostReadDenylist)
            && lastRecorded?.outcome == recordedOutcome
            && lastRecorded?.bundleID == activity.bundleID
        guard !isRepeatedSkip else { return applied }
        lastRecorded = (recordedOutcome, activity.bundleID)
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
