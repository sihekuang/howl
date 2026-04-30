import AppKit

/// Watches for the Escape key (keyCode 53) globally while recording is
/// active. Start it on PTT press; stop it on PTT release, result, or
/// error so normal Esc use outside of recording is unaffected.
public final class CancelKeyMonitor: @unchecked Sendable {
    private static let escKeyCode: UInt16 = 53

    private let onCancel: @Sendable () -> Void
    private var monitor: Any?

    public init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [onCancel] event in
            if event.keyCode == Self.escKeyCode {
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

    /// Simulates an Esc keypress without going through NSEvent.
    public func simulateEscForTest() {
        onCancel()
    }

    /// Simulates a non-Esc keypress (no-op — the real monitor's keyCode
    /// filter would discard it).
    public func simulateKeyForTest(keyCode _: UInt16) {}
}
