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
}
