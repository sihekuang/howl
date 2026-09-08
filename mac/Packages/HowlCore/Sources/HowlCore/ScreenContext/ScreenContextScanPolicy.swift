import Foundation

/// Whether a periodic scan tick is worth spending.
///
/// Extracted from `ScreenContextObserver` for the same reason
/// `Debouncer` was: the decision is pure, the thing that feeds it
/// (`CGEventSource`) is not, and the decision is the part worth
/// testing.
///
/// The periodic scan exists because the three event triggers —
/// app activation, focused-window-changed, title-changed — all miss
/// the case that matters most for dictation: the user stays in one
/// window, scrolls or types, and the content moves underneath
/// keywords that were captured on entry. Whisper's `initial_prompt`
/// is frozen inside `howl_start_capture`, so refreshing when the
/// hotkey is pressed would already be too late; the keywords have to
/// be warm before that.
public enum ScreenContextScanPolicy {
    /// How long the machine may sit without human input before
    /// periodic scanning pauses.
    ///
    /// This is the whole battery story. A laptop left open on a
    /// desk would otherwise screenshot and OCR its front window
    /// every 15 seconds forever, and there is no possible benefit:
    /// with no keyboard, mouse or trackpad input, nothing the user
    /// did can have changed the window, and nobody is about to
    /// dictate into it either.
    ///
    /// It also covers screen lock and display sleep without needing
    /// to observe them separately — a locked Mac is by definition
    /// receiving no HID input, so the same test pauses scanning
    /// there too.
    ///
    /// One minute, not ten seconds: the gap between "reading a long
    /// page before dictating a reply" and "walked away" is the thing
    /// being separated, and a reader who has not touched the
    /// trackpad in 40 seconds is still reading.
    public static let maxIdleSeconds: TimeInterval = 60

    /// - Parameter idleSeconds: seconds since the last human input
    ///   event, or nil when that cannot be determined — in which
    ///   case scanning proceeds. Failing OPEN is deliberate here and
    ///   is the opposite of the denylist's fail-closed rule: the cost
    ///   of a wrong "yes" is one wasted screenshot, while a wrong
    ///   "no" silently disables the feature this whole change exists
    ///   to add.
    public static func shouldScan(idleSeconds: TimeInterval?, maxIdle: TimeInterval = maxIdleSeconds) -> Bool {
        guard let idleSeconds else { return true }
        return idleSeconds <= maxIdle
    }
}
