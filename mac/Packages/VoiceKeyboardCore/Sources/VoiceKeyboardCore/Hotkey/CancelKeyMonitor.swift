import AppKit

/// Watches for the Escape key (keyCode 53) globally while recording is
/// active. Start it on PTT press; stop it on PTT release, result, or
/// error so normal Esc use outside of recording is unaffected.
public final class CancelKeyMonitor: @unchecked Sendable {
    private var monitor: Any?

    public init() {}

    public func start(onCancel: @escaping @Sendable () -> Void) {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                onCancel()
            }
        }
    }

    public func stop() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
    }
}
