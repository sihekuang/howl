// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/RelativeTime.swift
import Foundation

/// Pure formatter that turns "time since X" into a human label like
/// "just now" / "5 min ago" / "3 hours ago" / "May 3". Used by the
/// session list to surface staleness at a glance.
public enum RelativeTime {
    /// Build a relative label from a known `now` and a past instant.
    /// `now` is injected for testability; production callers pass `Date()`.
    public static func string(now: Date, then: Date) -> String {
        let diff = now.timeIntervalSince(then)
        if diff < 60 { return "just now" }
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
