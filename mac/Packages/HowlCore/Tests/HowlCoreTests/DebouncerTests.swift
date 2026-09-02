import Foundation
import Testing
@testable import HowlCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock(); value += 1; lock.unlock()
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

/// One-shot signal so a test can deterministically know an action
/// actually ran, instead of guessing via a fixed sleep-then-check.
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

/// Hands the cooperative executor over repeatedly, so a task that has
/// already been *resumed* (its continuation enqueued) gets to run to
/// completion before the caller continues.
///
/// Deliberately not `Task.sleep`: this waits on scheduler progress,
/// not on wall-clock time, so it can't be starved by a loaded CI box
/// the way a fixed sleep can. Used only where the thing being waited
/// for is already runnable and needs no further suspension.
private func handOffScheduler(_ times: Int = 100) async {
    for _ in 0..<times { await Task.yield() }
}

@Suite("Debouncer")
struct DebouncerTests {

    @Test func runs_the_action_after_the_interval() async throws {
        let c = Counter()
        let d = Debouncer(interval: 0.05)
        d.schedule { c.increment() }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(c.count == 1)
    }

    @Test func rapid_schedules_collapse_to_one_run() async throws {
        let c = Counter()
        // Interval widened to 0.2s (was 0.05s) against a 5ms
        // inter-schedule gap: a 10x margin between the gap and the
        // interval is too tight on a loaded CI box, where the sleep
        // can overshoot and let an intermediate fire slip through.
        // 0.2s keeps the 5ms gap but gives a much wider margin.
        let d = Debouncer(interval: 0.2)
        for _ in 0..<5 {
            d.schedule { c.increment() }
            try await Task.sleep(nanoseconds: 5_000_000)   // faster than the interval
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(c.count == 1)
    }

    @Test func cancel_prevents_a_pending_run() async throws {
        let c = Counter()
        let d = Debouncer(interval: 0.05)
        d.schedule { c.increment() }
        d.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(c.count == 0)
    }

    @Test func separated_schedules_each_run() async throws {
        let c = Counter()
        let d = Debouncer(interval: 0.05)
        d.schedule { c.increment() }
        try await Task.sleep(nanoseconds: 200_000_000)
        d.schedule { c.increment() }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(c.count == 2)
    }

    @Test func sustained_rapid_schedules_still_fire_via_max_delay() async throws {
        // A pure trailing debounce would be starved forever by a
        // stream that never pauses for a full `interval` — exactly
        // what a retitling-every-keystroke terminal or a media
        // player's live timecode does. `maxDelay` is the backstop:
        // the action must fire no later than `maxDelay` seconds after
        // the FIRST schedule of the run, even while rescheduling
        // keeps happening faster than `interval`.
        //
        // interval (0.1s) < maxDelay (0.3s) < the reschedule loop's
        // own duration (25 * 20ms = 500ms), so if the cap works the
        // action fires mid-burst, well before the burst naturally
        // ends — and if the cap is broken, it can only fire AFTER the
        // burst ends (once real quiet finally occurs), which the
        // elapsed-time assertion below distinguishes.
        let fired = Signal()
        let d = Debouncer(interval: 0.1, maxDelay: 0.3)
        let start = Date()

        let burst = Task {
            for _ in 0..<25 {
                d.schedule { await fired.set() }
                try? await Task.sleep(nanoseconds: 20_000_000)   // faster than `interval`
            }
        }

        // Deterministic: returns exactly when the action has actually
        // run, not after a guessed sleep. If `maxDelay` regressed to
        // "no cap", this would only return once the burst above
        // finishes and a genuine `interval`-long gap occurs — i.e.
        // around 500ms+, not ~300ms.
        await fired.wait()
        let elapsed = Date().timeIntervalSince(start)
        burst.cancel()

        #expect(elapsed < 0.45)   // comfortably before the burst's own ~500ms natural end
    }

    @Test func a_finishing_run_does_not_orphan_a_newer_scheduled_run() async throws {
        // A run's completion bookkeeping happens AFTER `await action()`
        // — a real suspension point. A `schedule` arriving during that
        // suspension becomes the new pending run, and the finishing
        // (older) run must not clear the reference to it. If it does,
        // the newer task is orphaned: `cancel()` can no longer reach
        // it, so the action fires after the caller cancelled — which
        // for `ScreenContextObserver` means firing after `stop()`.
        let started = Signal()   // action A has begun and is about to suspend
        let gate = Signal()      // released by the test to let action A return
        let later = Counter()    // incremented by the run that must be cancellable
        let d = Debouncer(interval: 0.1)

        d.schedule {
            await started.set()
            await gate.wait()
        }
        await started.wait()

        // Arrives while A is suspended inside `await action()`. This
        // must become — and stay — the debouncer's pending run.
        d.schedule { later.increment() }

        // Let A return, so its run-completion bookkeeping executes
        // before we cancel. `handOffScheduler` (not a sleep) is what
        // makes that ordering deterministic.
        await gate.set()
        await handOffScheduler()

        d.cancel()

        try await Task.sleep(nanoseconds: 400_000_000)   // well past the 0.1s interval
        #expect(later.count == 0)
    }

    @Test func begin_run_gates_a_superseded_run_and_retires_its_epoch() async throws {
        // The lost-fire guard, and the one assertion in this file that
        // does NOT depend on timing. `beginRun` is a pure function of
        // (id, runID, runStartedAt, epoch), so both of its arms can be
        // pinned by calling it directly.
        //
        // Why this test rather than leaning on the burst tests: those
        // cannot reach the false branch. In
        // `rapid_schedules_collapse_to_one_run` every superseded task
        // is still inside `Task.sleep` when the next `schedule`
        // cancels it, so all of them die at `Task.isCancelled` and
        // never call `beginRun` at all; and
        // `sustained_rapid_schedules_still_fire_via_max_delay` uses an
        // idempotent `Signal`, so it cannot tell one fire from two.
        //
        // Intervals long enough that nothing fires while the test
        // runs — every transition below is driven by hand.
        let d = Debouncer(interval: 30, maxDelay: 30)

        d.schedule { }
        #expect(d.currentRunID == 1)
        let epoch = try #require(d.currentRunEpoch)

        // Run 2 supersedes run 1 and, because run 1 has not fired yet,
        // legitimately inherits its maxDelay epoch.
        d.schedule { }
        #expect(d.currentRunID == 2)
        #expect(d.currentRunEpoch == epoch)

        // Run 1 now reaches `beginRun` anyway — the race this guards.
        // It must report itself superseded, so the call site gates its
        // action off instead of double-firing...
        #expect(d.beginRun(1, epoch: epoch) == false)
        // ...and it must still retire the epoch it was scheduled
        // against, so the next `schedule` starts a fresh maxDelay
        // window instead of inheriting a cap deadline that is already
        // in the past and firing with no debounce.
        #expect(d.currentRunEpoch == nil)

        // The current run reports itself current and fires.
        #expect(d.beginRun(2, epoch: epoch) == true)

        // A superseded run holding a DIFFERENT epoch must leave the
        // live one alone — the epoch arm keys on identity, not on
        // "some run finished".
        d.schedule { }
        let fresh = try #require(d.currentRunEpoch)
        #expect(fresh != epoch)
        #expect(d.beginRun(1, epoch: epoch) == false)
        #expect(d.currentRunEpoch == fresh)

        d.cancel()
    }

    @Test func a_schedule_during_a_long_action_still_gets_a_full_interval() async throws {
        // The maxDelay epoch belongs to the run that is waiting to
        // fire, not to the run that is already executing. If the epoch
        // survives into the action's own (potentially long) execution,
        // a `schedule` arriving while the action is still running
        // inherits it — and once the action has outlived `maxDelay`,
        // the cap deadline is already in the past, the computed delay
        // collapses to 0, and the next schedule fires immediately with
        // no debounce at all. An LLM-backed refresh outliving the
        // default 5s maxDelay is entirely ordinary.
        let started = Signal()
        let gate = Signal()
        let nextFired = Signal()
        // maxDelay (0.3s) deliberately far shorter than the action's
        // own runtime below, so a stale epoch puts the cap in the past.
        let d = Debouncer(interval: 0.2, maxDelay: 0.3)

        d.schedule {
            await started.set()
            await gate.wait()
        }
        await started.wait()

        // Not event ordering — this IS the scenario: the action itself
        // runs longer than maxDelay.
        try await Task.sleep(nanoseconds: 500_000_000)

        let scheduledAt = Date()
        d.schedule { await nextFired.set() }
        await nextFired.wait()
        let delay = Date().timeIntervalSince(scheduledAt)

        await gate.set()   // let the long action finish before the test ends

        // A real debounce interval, not an immediate fire.
        #expect(delay > 0.1)
    }
}
