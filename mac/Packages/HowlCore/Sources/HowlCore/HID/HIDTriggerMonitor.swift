import Foundation

/// A trigger source that listens to a HID device element and reports press /
/// release edges. Peer to `HotkeyMonitor`: same closure-based seam, so the
/// arbiter can fan both into the engine identically.
///
/// Permission checking is deliberately *not* part of this protocol — that is
/// `HIDInputMonitoringPermission`'s job (interface segregation).
public protocol HIDTriggerMonitor: Sendable {
    /// Begin listening. `binding == nil` means discovery/log mode: no trigger
    /// fires; every device element edge is logged so the user can read off the
    /// vendor/product/usage of the element they want to bind.
    ///
    /// Async so implementations can retry transient `IOHIDManager` open
    /// failures (mirrors `HotkeyMonitor.start`). Throws only after retries are
    /// exhausted.
    func start(
        _ binding: HIDBinding?,
        onPress: @escaping @Sendable () -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) async throws

    /// Phase-2 learn mode: listen until the next learnable element edge (a
    /// non-keyboard, non-axis button down — see `HIDLearnFilter`) and report it
    /// via `onLearned`. Further edges are ignored after the first; the caller
    /// persists the binding and calls `stop()` / `start` (bound) to release and
    /// rebind the device.
    func learnNextBinding(_ onLearned: @escaping @Sendable (HIDBinding) -> Void) async throws

    /// Stop listening and release the device (idempotent).
    func stop()
}
