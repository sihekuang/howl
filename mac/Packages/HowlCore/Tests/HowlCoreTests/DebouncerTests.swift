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
}
