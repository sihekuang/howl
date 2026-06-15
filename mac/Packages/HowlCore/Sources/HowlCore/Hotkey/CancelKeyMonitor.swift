import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.howl.app", category: "CancelKey")

/// Watches for ANY key globally while a dictation cycle is active — both
/// recording and processing — and fires `onCancel`, which aborts the whole
/// pipeline.
///
/// Uses a `CGEvent` tap rather than `NSEvent.addGlobalMonitorForEvents`:
/// global NSEvent monitors do NOT reliably observe key presses made while the
/// fn/Globe key is held (the common PTT trigger), so cancel never fired for
/// fn users — the monitor installed but no keyDown was ever delivered.
/// `CarbonHotkeyMonitor` uses a tap for the same reason. The tap runs under
/// Accessibility, which the app already holds for paste injection.
///
/// Howl's own injected keystrokes carry `HowlSyntheticEvent.marker` in
/// `eventSourceUserData` and are ignored. (At `.cghidEventTap` — the hardware
/// level — session-injected events aren't even seen, so this is defense in
/// depth that also keeps the test seam meaningful.)
///
/// THREAD SAFETY: `start()` and `stop()` must only be called from the main
/// actor. `@unchecked Sendable` is required because `CFMachPort` /
/// `CFRunLoopSource` aren't `Sendable`; all mutations are serialized on the
/// main thread by the caller (`EngineCoordinator`).
public final class CancelKeyMonitor: @unchecked Sendable {
    private let onCancel: @Sendable () -> Void
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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

    /// Called from the tap callback (already hopped to the main queue) for a
    /// real, non-synthetic key.
    fileprivate func fire() { onCancel() }

    public func start() {
        guard eventTap == nil else {
            log.debug("CancelKeyMonitor.start: already running")
            return
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: cancelKeyEventTapCallback,
            userInfo: selfPtr
        ) else {
            log.error("CancelKeyMonitor.start: tapCreate returned nil — Accessibility may not be ready")
            return
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = src
        log.info("CancelKeyMonitor.start: CGEvent keyDown tap installed")
    }

    public func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        eventTap = nil
        log.debug("CancelKeyMonitor.stop: tap removed")
    }

    deinit { stop() }

    // MARK: - Test surface

    /// Simulates a real (non-synthetic) keypress — should cancel.
    /// Routes through `shouldCancel` so the seam exercises the live decision.
    public func simulateKeyForTest(keyCode _: UInt16 = 0) {
        if Self.shouldCancel(userData: 0) { onCancel() }
    }

    /// Simulates a Howl-injected keystroke — should NOT cancel.
    public func simulateSyntheticKeyForTest() {
        if Self.shouldCancel(userData: HowlSyntheticEvent.marker) { onCancel() }
    }

    /// Simulates Esc — now just one of "any key".
    public func simulateEscForTest() {
        simulateKeyForTest(keyCode: 53)
    }
}

// File-scope C callback for the CGEvent tap — mirrors the pattern in
// CarbonHotkeyMonitor. `userInfo` is an unretained `CancelKeyMonitor`.
private func cancelKeyEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<CancelKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    // Re-enable the tap if the system disabled it (timeout / user input).
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }

    let userData = event.getIntegerValueField(.eventSourceUserData)
    let decision = CancelKeyMonitor.shouldCancel(userData: userData)
    log.debug("CancelKeyMonitor: keyDown observed userData=\(userData, privacy: .public) shouldCancel=\(decision, privacy: .public)")
    if decision {
        // Hop to the main queue: start()/stop() and the engine teardown all
        // run on the main actor. Listen-only tap, so we never modify the event.
        DispatchQueue.main.async { monitor.fire() }
    }
    return Unmanaged.passUnretained(event)
}
