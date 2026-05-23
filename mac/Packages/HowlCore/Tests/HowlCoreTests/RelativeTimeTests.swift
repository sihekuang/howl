import Foundation
import Testing
@testable import HowlCore

@Suite("RelativeTime")
struct RelativeTimeTests {
    private let now = Date(timeIntervalSince1970: 1_777_900_000) // arbitrary fixed reference

    @Test func underAMinuteIsJustNow() {
        let then = now.addingTimeInterval(-30)
        #expect(RelativeTime.string(now: now, then: then) == "just now")
    }

    @Test func minutesAgo() {
        let then = now.addingTimeInterval(-5 * 60)
        #expect(RelativeTime.string(now: now, then: then) == "5 min ago")
    }

    @Test func oneMinute_singular() {
        let then = now.addingTimeInterval(-60)
        #expect(RelativeTime.string(now: now, then: then) == "1 min ago")
    }

    @Test func oneHour_singular() {
        let then = now.addingTimeInterval(-3600)
        #expect(RelativeTime.string(now: now, then: then) == "1 hour ago")
    }

    @Test func multipleHours() {
        let then = now.addingTimeInterval(-3 * 3600)
        #expect(RelativeTime.string(now: now, then: then) == "3 hours ago")
    }

    @Test func oneDay_singular() {
        let then = now.addingTimeInterval(-24 * 3600)
        #expect(RelativeTime.string(now: now, then: then) == "1 day ago")
    }

    @Test func multipleDays() {
        let then = now.addingTimeInterval(-3 * 24 * 3600)
        #expect(RelativeTime.string(now: now, then: then) == "3 days ago")
    }

    @Test func farPastFallsBackToDateStamp() {
        // 30 days ago → date stamp like "Apr 3"
        let then = now.addingTimeInterval(-30 * 24 * 3600)
        let got = RelativeTime.string(now: now, then: then)
        #expect(!got.contains("ago"))
        #expect(!got.contains("just now"))
    }

    @Test func parseISO8601_validRoundTrip() {
        let id = "2026-05-03T01:08:42.123Z"
        let got = RelativeTime.parse(id)
        #expect(got != nil)
    }

    @Test func parseISO8601_invalidReturnsNil() {
        #expect(RelativeTime.parse("not a date") == nil)
    }
}
