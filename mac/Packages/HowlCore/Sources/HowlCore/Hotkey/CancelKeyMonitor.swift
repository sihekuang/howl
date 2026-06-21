import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.howl.app", category: "CancelKey")

/// Watches for any fresh keypress globally while a dictation cycle is active —
/// both recording and processing — and fires `onCancel`, which aborts the whole
/// pipeline. "Fresh" excludes OS auto-repeat: a held push-to-talk combo's base
/// key repeats while held, and those repeats must not cancel the dictation they
/// triggered (see `shouldCancel`).
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

    /// Pure cancel decision: a fresh, real keypress cancels. Two exclusions:
    /// - our own injected keystrokes (they carry `HowlSyntheticEvent.marker`
    ///   in `eventSourceUserData`; 0 for real hardware keypresses);
    /// - OS auto-repeat events. A held push-to-talk *combo* (e.g. ⌃F) makes its
    ///   base key auto-repeat, and those repeats would otherwise cancel the very
    ///   dictation they triggered. Auto-repeat is the OS continuing a held key,
    ///   not a new user action, so it never cancels — only a genuine fresh
    ///   keypress (`isAutorepeat == false`) does. This mirrors how hold-to-talk
    ///   tools treat key-repeat as part of the hold rather than a separate key.
    static func shouldCancel(userData: Int64, isAutorepeat: Bool) -> Bool {
        userData != HowlSyntheticEvent.marker && !isAutorepeat
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
        // `.listenOnly`: we observe but do NOT swallow the key, so the cancel
        // keypress also falls through to the focused app (it gets typed). That's
        // an intentional tradeoff — swallowing would need an active tap that
        // risks eating legitimate keystrokes; the cycle is being torn down
        // anyway, so a stray character is acceptable.
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: cancelKeyEventTapCallback,
            userInfo: selfPtr
        ) else {
            // Not retried (unlike CarbonHotkeyMonitor's PTT tap): `start()` runs
            // fresh on every PTT press, and the PTT tap itself already succeeded
            // to get here, so Accessibility is held — the next recording re-runs
            // this. The narrow miss window is the first dictation right after a
            // cold launch that just got granted permission.
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

    /// Simulates a real keypress — should cancel unless it's an auto-repeat.
    /// Routes through `shouldCancel` so the seam exercises the live decision.
    public func simulateKeyForTest(keyCode _: UInt16 = 0, isAutorepeat: Bool = false) {
        if Self.shouldCancel(userData: 0, isAutorepeat: isAutorepeat) { onCancel() }
    }

    /// Simulates a Howl-injected keystroke — should NOT cancel.
    public func simulateSyntheticKeyForTest() {
        if Self.shouldCancel(userData: HowlSyntheticEvent.marker, isAutorepeat: false) { onCancel() }
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
    let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let decision = CancelKeyMonitor.shouldCancel(userData: userData, isAutorepeat: isAutorepeat)
    log.info("CancelKeyMonitor: keyDown kc=\(keyCode, privacy: .public) autorepeat=\(isAutorepeat, privacy: .public) userData=\(userData, privacy: .public) shouldCancel=\(decision, privacy: .public)")
    if decision {
        // Hop to the main queue: start()/stop() and the engine teardown all
        // run on the main actor. Listen-only tap, so we never modify the event.
        DispatchQueue.main.async { monitor.fire() }
    }
    return Unmanaged.passUnretained(event)
}
