import Foundation
import Testing
@testable import HowlCore

private func activity(_ bundleID: String, at t: Date) -> ScreenContextActivity {
    ScreenContextActivity(timestamp: t, bundleID: bundleID, outcome: .cacheHit)
}

@Suite("ScreenContextActivityBuffer")
struct ScreenContextActivityBufferTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func starts_empty() {
        let buffer = ScreenContextActivityBuffer(capacity: 5)
        #expect(buffer.entries.isEmpty)
    }

    @Test func records_in_order_below_capacity() {
        var buffer = ScreenContextActivityBuffer(capacity: 5)
        buffer.record(activity("com.a", at: t0))
        buffer.record(activity("com.b", at: t0))
        buffer.record(activity("com.c", at: t0))
        #expect(buffer.entries.map(\.bundleID) == ["com.a", "com.b", "com.c"])
    }

    @Test func evicts_oldest_first_once_over_capacity() {
        var buffer = ScreenContextActivityBuffer(capacity: 3)
        for i in 1...5 {
            buffer.record(activity("com.\(i)", at: t0))
        }
        // Only the 3 most recent survive, oldest-first within that window.
        #expect(buffer.entries.map(\.bundleID) == ["com.3", "com.4", "com.5"])
    }

    @Test func never_exceeds_capacity_across_many_inserts() {
        var buffer = ScreenContextActivityBuffer(capacity: 50)
        for i in 1...200 {
            buffer.record(activity("com.\(i)", at: t0))
        }
        #expect(buffer.entries.count == 50)
        // The last recorded entry is always the most recent.
        #expect(buffer.entries.last?.bundleID == "com.200")
        // The oldest surviving entry is exactly `capacity` back from the end.
        #expect(buffer.entries.first?.bundleID == "com.151")
    }

    @Test func single_capacity_buffer_keeps_only_the_newest() {
        var buffer = ScreenContextActivityBuffer(capacity: 1)
        buffer.record(activity("com.a", at: t0))
        buffer.record(activity("com.b", at: t0))
        #expect(buffer.entries.map(\.bundleID) == ["com.b"])
    }
}
