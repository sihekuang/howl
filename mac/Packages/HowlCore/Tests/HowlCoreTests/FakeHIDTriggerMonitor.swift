import Foundation
@testable import HowlCore

/// Thread-safe call counter for arbiter start/stop closures in tests.
/// `@unchecked` is safe: tests invoke these synchronously on one thread.
final class CallCounter: @unchecked Sendable {
    private(set) var value = 0
    func inc() { value += 1 }
}

/// Test double for `HIDTriggerMonitor`. Captures the press/release closures
/// the arbiter vends, and lets a test fire synthetic device edges — the seam
/// that lets us test all routing logic with no IOKit / hardware.
final class FakeHIDTriggerMonitor: HIDTriggerMonitor, @unchecked Sendable {
    private(set) var startedBinding: HIDBinding?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var learnCount = 0
    private var onPress: (@Sendable () -> Void)?
    private var onRelease: (@Sendable () -> Void)?
    private var onLearned: (@Sendable (HIDBinding) -> Void)?

    func start(
        _ binding: HIDBinding?,
        onPress: @escaping @Sendable () -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) async throws {
        startedBinding = binding
        self.onPress = onPress
        self.onRelease = onRelease
        startCount += 1
    }

    func learnNextBinding(_ onLearned: @escaping @Sendable (HIDBinding) -> Void) async throws {
        self.onLearned = onLearned
        learnCount += 1
    }

    func stop() {
        stopCount += 1
        onPress = nil
        onRelease = nil
        onLearned = nil
    }

    /// Simulate the bound element going down.
    func fireDown() { onPress?() }

    /// Simulate the bound element coming back up (or a synthetic
    /// release on device removal).
    func fireUp() { onRelease?() }

    /// Simulate learn mode capturing an element edge.
    func fireLearned(_ binding: HIDBinding) { onLearned?(binding) }
}
