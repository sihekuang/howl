import Foundation

/// Fixed-capacity, oldest-evicted-first buffer of `ScreenContextActivity`
/// records.
///
/// Pure value-type logic — no `@MainActor`, no `@Observable` — so the
/// eviction rule is unit-testable directly, the same way `Debouncer`'s
/// timing logic lives here even though its only consumer touches
/// AppKit (see `DebouncerTests`). The `mac/Howl` app target wraps this
/// in an `@MainActor @Observable` store (`ScreenContextActivityStore`)
/// for SwiftUI — this type is the tested mechanism underneath it, kept
/// in `HowlCore` because that is where this project's test target
/// lives, not because the state itself belongs here.
public struct ScreenContextActivityBuffer: Sendable {
    /// Oldest first, newest last.
    public private(set) var entries: [ScreenContextActivity] = []
    public let capacity: Int

    public init(capacity: Int = 50) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
    }

    /// Appends `activity`. Once `entries.count` would exceed
    /// `capacity`, evicts from the front (oldest) until back within
    /// it — so this always holds at most `capacity` entries, always
    /// the most recent ones.
    public mutating func record(_ activity: ScreenContextActivity) {
        entries.append(activity)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }
}
