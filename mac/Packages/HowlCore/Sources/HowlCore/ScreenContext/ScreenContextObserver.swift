import AppKit
import Foundation

/// Holds the NSNotificationCenter observer token so `deinit` — which
/// is nonisolated even on a `@MainActor` class — can release it
/// without touching actor-isolated state. `NSObjectProtocol` isn't
/// Sendable, but the token is opaque and only ever passed to
/// `removeObserver`, never inspected, so `@unchecked` is safe here.
private final class ObserverToken: @unchecked Sendable {
    var value: NSObjectProtocol?
}

/// Fires `onFocusSettled` once the frontmost app has stayed frontmost
/// for `debounce` seconds, so alt-tabbing through windows costs
/// nothing. Thin AppKit shim — the timing lives in Debouncer and the
/// policy in ScreenContextCoordinator, which is where the tests are.
@MainActor
public final class ScreenContextObserver {
    private let debouncer: Debouncer
    private let onFocusSettled: @Sendable () async -> Void
    private let token = ObserverToken()

    public init(debounce: TimeInterval = 0.8,
                onFocusSettled: @escaping @Sendable () async -> Void) {
        self.debouncer = Debouncer(interval: debounce)
        self.onFocusSettled = onFocusSettled
    }

    public func start() {
        guard token.value == nil else { return }
        let action = onFocusSettled
        let debouncer = self.debouncer
        token.value = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            debouncer.schedule(action)
        }
        // Prime with whatever is already focused at startup.
        debouncer.schedule(action)
    }

    public func stop() {
        if let observer = token.value {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        token.value = nil
        debouncer.cancel()
    }

    deinit {
        if let observer = token.value {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
