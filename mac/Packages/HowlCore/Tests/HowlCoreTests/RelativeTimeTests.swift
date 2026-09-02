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

    // MARK: - Sub-minute granularity
    //
    // These exist because a list of screen-context activities is a
    // list of things that happen seconds apart, and both halves of
    // "just now forever" are bugs: a label that never ages as the
    // clock advances, and a label too coarse to tell two entries in
    // the same minute apart. A test that formats one instant once
    // would pass while both are present, so every test here either
    // advances `now` against a fixed `then` or holds `now` fixed and
    // varies `then`.

    @Test func secondsGranularity_labelAgesAsNowAdvances() {
        let then = now
        let labelsOverTime = [0, 4, 5, 12, 30, 59, 60, 65, 3600].map { elapsed in
            RelativeTime.string(
                now: then.addingTimeInterval(TimeInterval(elapsed)),
                then: then,
                granularity: .seconds
            )
        }
        #expect(labelsOverTime == [
            "just now",     // 0s
            "just now",     // 4s  — still inside the first bucket
            "5 sec ago",    // 5s  — first tick that must visibly change
            "10 sec ago",   // 12s — floored to the bucket
            "30 sec ago",   // 30s
            "55 sec ago",   // 59s — the last sub-minute label
            "1 min ago",    // 60s — hands over to the minutes path
            "1 min ago",    // 65s
            "1 hour ago",   // 3600s
        ])
    }

    @Test func secondsGranularity_distinguishesEntriesInTheSameMinute() {
        // The user-visible complaint: several entries a few seconds
        // apart all reading the same thing.
        let recent = now.addingTimeInterval(-5)
        let older = now.addingTimeInterval(-40)
        let recentLabel = RelativeTime.string(now: now, then: recent, granularity: .seconds)
        let olderLabel = RelativeTime.string(now: now, then: older, granularity: .seconds)
        #expect(recentLabel == "5 sec ago")
        #expect(olderLabel == "40 sec ago")
        #expect(recentLabel != olderLabel)
    }

    @Test func secondsGranularity_bucketMatchesTheExportedTickInterval() {
        // The view ticks at `subMinuteBucket`; if the label stepped at
        // some other size, ticks would either be wasted or arrive too
        // late to keep the label true.
        let step = RelativeTime.subMinuteBucket
        let atStep = RelativeTime.string(
            now: now, then: now.addingTimeInterval(-step), granularity: .seconds)
        let justUnder = RelativeTime.string(
            now: now, then: now.addingTimeInterval(-step + 0.5), granularity: .seconds)
        #expect(atStep == "\(Int(step)) sec ago")
        #expect(justUnder == "just now")
    }

    @Test func secondsGranularity_nonPositiveAgeStaysJustNow() {
        // Clock skew, or a timestamp from the future: never "-5 sec ago".
        let future = now.addingTimeInterval(30)
        #expect(RelativeTime.string(now: now, then: future, granularity: .seconds) == "just now")
        #expect(RelativeTime.string(now: now, then: now, granularity: .seconds) == "just now")
    }

    @Test func minutesGranularityIsUnaffected() {
        // Guards every pre-existing caller (SessionList, CompareView),
        // which must keep collapsing the first minute.
        for elapsed in [0, 5, 12, 30, 59] {
            let then = now.addingTimeInterval(-TimeInterval(elapsed))
            #expect(RelativeTime.string(now: now, then: then) == "just now")
            #expect(RelativeTime.string(now: now, then: then, granularity: .minutes) == "just now")
        }
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
