import AppKit
import CoreGraphics

/// Watches for ANY key globally while a dictation cycle is active — both
/// recording and processing — and fires `onCancel`, which aborts the whole
/// pipeline. Howl's own injected keystrokes (streaming text + final ⌘V paste)
/// carry the `HowlSyntheticEvent.marker` in `eventSourceUserData` and are
/// ignored, so typing text into the document never self-cancels.
///
/// Start it on PTT press; stop it on a terminal event (result / cancelled /
/// error) or manual reset, so normal typing outside a dictation is
/// unaffected.
///
/// THREAD SAFETY: `start()` and `stop()` must only be called from the main
/// actor. `@unchecked Sendable` is required because `NSEvent` monitor tokens
/// (`Any?`) are not `Sendable`; all mutations are serialized on the main
/// thread by the caller (`EngineCoordinator`).
public final class CancelKeyMonitor: @unchecked Sendable {
    private let onCancel: @Sendable () -> Void
    private var monitor: Any?

    public init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    /// Pure cancel decision: any observed key cancels unless it carries
    /// Howl's synthetic-event marker (i.e. it's our own injection).
    /// `userData` is the event's `eventSourceUserData` field value
    /// (0 for real hardware keypresses).
    static func shouldCancel(userData: Int64) -> Bool {
        userData != HowlSyntheticEvent.marker
    }

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [onCancel] event in
            let userData = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
            if CancelKeyMonitor.shouldCancel(userData: userData) {
                onCancel()
            }
        }
    }

    public func stop() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
    }

    deinit { stop() }

    // MARK: - Test surface

    /// Simulates a real (non-synthetic) keypress — should cancel.
    /// Routes through `shouldCancel` deliberately so the seam exercises the live decision
    /// logic (field extraction / nil-coalescing in the NSEvent closure is not covered here).
    public func simulateKeyForTest(keyCode _: UInt16 = 0) {
        if Self.shouldCancel(userData: 0) { onCancel() }
    }

    /// Simulates a Howl-injected keystroke — should NOT cancel.
    /// Routes through `shouldCancel` deliberately so `ignoresHowlSyntheticKey` is a real
    /// assertion, not a tautology (field extraction in the NSEvent closure is not covered here).
    public func simulateSyntheticKeyForTest() {
        if Self.shouldCancel(userData: HowlSyntheticEvent.marker) { onCancel() }
    }

    /// Simulates Esc — now just one of "any key".
    public func simulateEscForTest() {
        simulateKeyForTest(keyCode: 53)
    }
}
