import Foundation

/// Runs an action once the caller has stopped scheduling it for
/// `interval` seconds — with a backstop: if `schedule` keeps being
/// called faster than `interval`, the action still fires no later
/// than `maxDelay` seconds after the FIRST schedule of the current
/// run. Extracted from the focus observer so the collapse-rapid-
/// events behaviour is testable without AppKit.
///
/// The backstop exists because a pure trailing debounce can be
/// starved forever by a sustained stream of schedules — a media
/// player retitling with a live timecode, a terminal retitling per
/// command, an animating page title, or a downloader's progress title
/// can all retitle faster than `interval`, and without a cap the
/// action would simply never fire while that keeps happening. This is
/// the standard debounce-with-maxWait shape.
public final class Debouncer: @unchecked Sendable {
    private let interval: TimeInterval
    private let maxDelay: TimeInterval
    private let lock = NSLock()
    private var pending: Task<Void, Never>?
    // When the current run's FIRST `schedule` call arrived. Reset to
    // nil once the action actually STARTS firing (not when it
    // finishes) or is cancelled, so the next `schedule` call starts a
    // fresh maxDelay window rather than inheriting a stale one. See
    // `beginRun` for why fire time and not finish time, and for how
    // an epoch inherited across that same boundary is retired.
    private var runStartedAt: Date?
    // Identifies the current run. Every `schedule` (and `cancel`)
    // stamps a new id, so a task that reaches its own bookkeeping
    // AFTER a newer `schedule` has superseded it can tell that it is
    // stale and leave the newer run's state alone. Without this, a
    // finishing run nils out `pending` unconditionally and orphans the
    // task that replaced it: `cancel()` can then no longer reach that
    // task, and the action fires after the caller cancelled — which
    // for `ScreenContextObserver` means firing after `stop()`.
    // `&+=` wraps rather than traps; UInt64 will not wrap in practice,
    // and equality (never ordering) is all that's compared.
    private var runID: UInt64 = 0

    public init(interval: TimeInterval, maxDelay: TimeInterval = 5.0) {
        self.interval = interval
        self.maxDelay = maxDelay
    }

    /// Schedule `action`, superseding any run not yet started. Fires
    /// after `interval` seconds of quiet, or after `maxDelay` seconds
    /// since the first call in this run, whichever comes first.
    public func schedule(_ action: @escaping @Sendable () async -> Void) {
        lock.lock()
        pending?.cancel()

        runID &+= 1
        let myRun = runID

        let now = Date()
        let startedAt = runStartedAt ?? now
        runStartedAt = startedAt

        let trailingDeadline = now.addingTimeInterval(interval)
        let capDeadline = startedAt.addingTimeInterval(maxDelay)
        let fireAt = min(trailingDeadline, capDeadline)
        let seconds = max(0, fireAt.timeIntervalSince(now))

        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            // Second supersede check, and the one that actually
            // decides whether to fire. `Task.isCancelled` above can be
            // passed a moment before a newer `schedule` lands, so on
            // its own it lets a superseded run execute its action
            // anyway — a double fire. `beginRun` re-checks under the
            // lock, so exactly one of the two runs proceeds.
            //
            // No fire is lost by bailing here: `id != runID` means
            // either a newer run exists (and will fire) or `cancel()`
            // happened (and nothing should fire).
            //
            // A deallocated `self` deliberately does NOT fire either.
            // With the debouncer gone there is nothing left that could
            // supersede or cancel this run, so letting it through
            // would be an action escaping its own scheduler's
            // lifetime — the exact "fires after teardown" shape this
            // type exists to prevent, and what `deinit`'s
            // `pending?.cancel()` already asks for.
            guard self?.beginRun(myRun, epoch: startedAt) == true else { return }
            await action()
            self?.finishRun(myRun)
        }
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        pending?.cancel()
        pending = nil
        runStartedAt = nil
        // Supersede any run already past its cancellation check, so
        // its bookkeeping can't resurrect state after this cancel.
        runID &+= 1
        lock.unlock()
    }

    /// Closes the maxDelay window at FIRE time, not at finish time.
    ///
    /// The window belongs to the run that is *waiting* to fire; once
    /// the action has started, the wait is over. Clearing it only
    /// after `await action()` returns would let a `schedule` arriving
    /// mid-action inherit this run's epoch — and once the action has
    /// outlived `maxDelay` (5s by default; an LLM-backed refresh does
    /// that routinely), the inherited cap deadline is already in the
    /// past, `seconds` collapses to 0, and the next schedule fires
    /// immediately with no debounce at all.
    ///
    /// Guarded on `runID` because a newer `schedule` may have landed
    /// between this task's cancellation check and here; that newer run
    /// owns `runStartedAt` now, and its fresh epoch must survive.
    ///
    /// The `runStartedAt == epoch` arm closes the residual window in
    /// that guard. A `schedule` landing between this task's
    /// cancellation check and this lock acquisition *inherits* this
    /// run's epoch (nothing has cleared it yet) and bumps `runID`, so
    /// the id check alone fails and the epoch is never consumed —
    /// leaving every subsequent `schedule` to keep inheriting an epoch
    /// whose cap deadline is already in the past, i.e. firing with no
    /// debounce at all, until some run's own `beginRun` finally
    /// matches. Matching on the epoch value retires it immediately
    /// instead. A superseded run that inherited a *fresh* epoch won't
    /// match and correctly leaves it alone. (Two runs could in
    /// principle carry byte-identical `Date`s; they would then denote
    /// the same instant and the same cap, so clearing either is
    /// equivalent.)
    ///
    /// Returns whether this run is still the current one — see the
    /// call site for why that gates the action.
    private func beginRun(_ id: UInt64, epoch: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let isCurrent = (id == runID)
        if isCurrent || runStartedAt == epoch { runStartedAt = nil }
        return isCurrent
    }

    /// Clears the run state only if this run is still the current one.
    /// A `schedule` arriving during `await action()` supersedes this
    /// run and installs its own task in `pending`; wiping that
    /// unconditionally would orphan it (see `runID`). `pending` is
    /// deliberately left pointing at this task for the duration of the
    /// action, so a `cancel()` mid-action still propagates
    /// cancellation into a cancellation-aware action.
    private func finishRun(_ id: UInt64) {
        lock.lock()
        if id == runID {
            pending = nil
            runStartedAt = nil
        }
        lock.unlock()
    }

    deinit { pending?.cancel() }
}
