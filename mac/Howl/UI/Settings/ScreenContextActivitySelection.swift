import Foundation
import HowlCore

/// Which activity the Screen Context detail pane shows, as the list
/// underneath it changes.
///
/// Pure decision logic, kept out of the view so the two rules that
/// actually matter are readable in one place:
///
/// 1. A user who has explicitly selected an older entry keeps it. New
///    activity arriving must not yank the detail pane out from under
///    them mid-read. This is not hypothetical: opening Settings makes
///    Howl frontmost, Howl's own bundle ID is denylisted, so a
///    "Skipped" entry lands at the top of the list at the exact moment
///    the user is trying to inspect the reading that came before it.
/// 2. A user who has not (or who is sitting on the newest entry)
///    follows the newest arrival, so the pane behaves like a live view
///    when nobody has pinned anything.
///
/// Lives in the app target rather than HowlCore because it is
/// presentation state and this project keeps UI-only logic in
/// `mac/Howl` — see `ScreenContextActivityStore`'s own note on the
/// same split.
enum ScreenContextActivitySelection {

    /// The selection to show after `recentFirst` changed.
    ///
    /// - Parameters:
    ///   - recentFirst: activities newest-first, i.e. `store.recentFirst`.
    ///   - current: the currently-selected id, if any.
    ///   - followsNewest: whether the current selection was tracking
    ///     new arrivals (see `followsNewest(_:in:)`).
    /// - Returns: the id to select. Nil only when there is nothing to
    ///   select at all.
    static func reconciled(
        recentFirst: [ScreenContextActivity],
        current: UUID?,
        followsNewest: Bool
    ) -> UUID? {
        let newest = recentFirst.first?.id
        guard let current, !followsNewest else { return newest }
        // A pinned entry that has fallen out of the ring buffer can't
        // be shown any more; snap forward rather than blanking the
        // pane.
        guard recentFirst.contains(where: { $0.id == current }) else { return newest }
        return current
    }

    /// Whether a selection should track new arrivals.
    ///
    /// Derived rather than stored as intent: sitting on the newest
    /// entry *is* following it, and re-selecting the top row is the
    /// obvious way to resume following after pinning something older.
    static func followsNewest(_ id: UUID?, in recentFirst: [ScreenContextActivity]) -> Bool {
        recentFirst.first?.id == id
    }
}
