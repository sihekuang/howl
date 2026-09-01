// mac/Packages/HowlCore/Sources/HowlCore/Editor/RelativeTime.swift
import Foundation

/// Pure formatter that turns "time since X" into a human label like
/// "just now" / "5 min ago" / "3 hours ago" / "May 3". Used by the
/// session list to surface staleness at a glance.
public enum RelativeTime {
    /// How finely to describe an age of less than one minute.
    public enum Granularity: Sendable {
        /// Everything under a minute is "just now". The original
        /// behaviour, and the default, because the session list this
        /// helper was written for stamps sessions minutes apart.
        case minutes
        /// Under a minute, count in `subMinuteBucket`-second steps.
        /// For lists whose entries arrive seconds apart — screen
        /// context refreshes fire on every focus change — where
        /// collapsing a whole minute into one label makes distinct
        /// entries look like duplicates.
        case seconds
    }

    /// Step size for `.seconds` labels, and the interval a caller
    /// should re-render at to keep them honest. Exported so the two
    /// cannot drift: a view ticking slower than this shows stale
    /// labels, and one ticking faster just recomputes the same string.
    public static let subMinuteBucket: TimeInterval = 5

    /// Build a relative label from a known `now` and a past instant.
    /// `now` is injected for testability; production callers pass
    /// `Date()` — or, in a list whose labels must age while it sits on
    /// screen, a `TimelineView` context date.
    ///
    /// `granularity` defaults to `.minutes`, so every pre-existing
    /// caller's output is unchanged.
    public static func string(now: Date, then: Date, granularity: Granularity = .minutes) -> String {
        let diff = now.timeIntervalSince(then)
        if diff < 60 {
            guard granularity == .seconds else { return "just now" }
            // Floored to the bucket, and non-positive ages (a clock
            // that moved backwards, a timestamp from the future) read
            // "just now" rather than "-5 sec ago".
            let bucket = Int(diff / subMinuteBucket) * Int(subMinuteBucket)
            return bucket <= 0 ? "just now" : "\(bucket) sec ago"
        }
        if diff < 3600 {
            let m = Int(diff / 60)
            return "\(m) min ago"
        }
        if diff < 24 * 3600 {
            let h = Int(diff / 3600)
            return "\(h) \(h == 1 ? "hour" : "hours") ago"
        }
        if diff < 7 * 24 * 3600 {
            let d = Int(diff / (24 * 3600))
            return "\(d) \(d == 1 ? "day" : "days") ago"
        }
        // Far past — fall back to a fixed date stamp.
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: then)
    }

    /// Parse a session manifest's RFC3339 id (`2026-05-03T01:08:42.123Z`)
    /// to a Date. Returns nil for unparseable input.
    public static func parse(_ id: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: id) { return d }
        // Manifests without sub-second precision fall through to the
        // version without fractional seconds.
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: id)
    }
}
