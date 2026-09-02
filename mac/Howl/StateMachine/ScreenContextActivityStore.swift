import Foundation
import Observation
import HowlCore

/// In-memory ring buffer of recent `ScreenContextActivity`, backing
/// the Screen Context tab's master/detail panes
/// (`ScreenContextActivityList` / `ScreenContextActivityDetail`).
///
/// Lives in the app target rather than `HowlCore` — this project keeps
/// UI-facing state in `mac/Howl` (see `AppState`, the pattern this
/// follows) even though only `HowlCore` has a test target. The actual
/// fixed-capacity eviction logic is `ScreenContextActivityBuffer` in
/// `HowlCore`, unit-tested there; this class is a thin `@MainActor`
/// `@Observable` wrapper around it so SwiftUI observes changes.
///
/// Dies with the app: nothing here is persisted, by design.
@MainActor
@Observable
public final class ScreenContextActivityStore: @unchecked Sendable {
    // `@unchecked Sendable`: every stored property is touched only
    // through a `@MainActor`-isolated method — the whole class is
    // `@MainActor`, so actor isolation (not this annotation) is what
    // actually makes access to `buffer` data-race-free. The annotation
    // exists solely so a reference to this store can be captured by
    // the `@Sendable` `onActivity` closure `CompositionRoot` hands to
    // `ScreenContextCoordinator` (which runs on its own actor); that
    // closure only ever calls back in with `await`, hopping onto the
    // main actor before `record(_:)` runs. Mirrors `ScreenContextCache`'s
    // own `@unchecked Sendable` for the same reason, one layer over.
    private var buffer: ScreenContextActivityBuffer

    public init(capacity: Int = 50) {
        self.buffer = ScreenContextActivityBuffer(capacity: capacity)
    }

    /// Oldest first, newest last — mirrors `ScreenContextActivityBuffer.entries`.
    public var entries: [ScreenContextActivity] { buffer.entries }

    /// Newest first, for display ("most recent activity" at the top of
    /// the inspector).
    public var recentFirst: [ScreenContextActivity] { entries.reversed() }

    public func record(_ activity: ScreenContextActivity) {
        buffer.record(activity)
    }
}
