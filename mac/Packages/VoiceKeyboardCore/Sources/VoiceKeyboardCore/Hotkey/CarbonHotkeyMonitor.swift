import AppKit
import Carbon
import CoreGraphics
import os

private let log = Logger(subsystem: "com.voicekeyboard.app", category: "Hotkey")

/// Carbon Event-Manager-based global hotkey monitor.
///
/// Normal key+modifier shortcuts use Carbon's `RegisterEventHotKey`, which
/// requires no TCC permissions. fn/Globe key can't be registered with Carbon,
/// so we fall back to `CGEvent.tapCreate` (session-level passive tap) — the
/// same approach OpenWhisper uses. The tap requires Accessibility, which the
/// app already holds for paste injection.
public final class CarbonHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    // fn/Globe key path — CGEventTap instead of NSEvent global monitor.
    fileprivate var fnEventTap: CFMachPort?
    fileprivate var fnRunLoopSource: CFRunLoopSource?
    fileprivate var fnRequired: ModifierFlags = []
    /// For fn+letter combos: the target key code to match on keyDown/keyUp.
    /// -1 means fn-alone or fn+modifier mode (flagsChanged detection instead).
    fileprivate var fnLetterKeyCode: Int64 = -1
    private var bound: Bound?
    fileprivate var isHeld: Bool { bound?.isHeld == true }

    private struct Bound {
        let onPress: @Sendable () -> Void
        let onRelease: @Sendable () -> Void
        var isHeld: Bool
    }

    public init() {}

    public func start(
        _ shortcut: KeyboardShortcut,
        onPress: @escaping @Sendable () -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) throws {
        stop()
        bound = Bound(onPress: onPress, onRelease: onRelease, isHeld: false)

        // fn/Globe key: use CGEvent.tapCreate with .maskSecondaryFn — the
        // same technique OpenWhisper uses. NSEvent.addGlobalMonitorForEvents
        // isn't reliable for Globe key on macOS 15+.
        if shortcut.isFnBased {
            fnRequired = shortcut.modifiers
            fnLetterKeyCode = shortcut.isFnLetterCombo ? Int64(shortcut.keyCode) : -1
            let reqRaw = fnRequired.rawValue
            log.info("PTT (CGEventTap/fn) start: mods=0x\(String(format: "%X", reqRaw), privacy: .public) letterKC=\(self.fnLetterKeyCode, privacy: .public)")

            let mask = CGEventMask(
                (1 << CGEventType.flagsChanged.rawValue) |
                (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.keyUp.rawValue)
            )
            // fn+letter needs an active tap so we can swallow the keyDown
            // (otherwise the letter gets typed in the focused app).
            // fn-alone / fn+modifier can stay listenOnly — flagsChanged can't be swallowed.
            let tapOptions: CGEventTapOptions = shortcut.isFnLetterCombo ? CGEventTapOptions(rawValue: 0)! : .listenOnly
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: tapOptions,
                eventsOfInterest: mask,
                callback: fnGlobeEventTapCallback,
                userInfo: selfPtr
            ) else {
                log.error("PTT (CGEventTap/fn): tapCreate failed — Accessibility permission required")
                throw HotkeyError.tapInstallFailed
            }
            fnEventTap = tap
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            fnRunLoopSource = src
            log.info("PTT (CGEventTap/fn): tap registered")
            return
        }

        log.info("PTT (Carbon) start: key=\(shortcut.keyCode, privacy: .public) mods=\(String(format: "0x%X", shortcut.modifiers.rawValue), privacy: .public)")

        // Install one handler that watches BOTH press and release events.
        var specs: [EventTypeSpec] = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let monitor = Unmanaged<CarbonHotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            let kind = GetEventKind(event)
            DispatchQueue.main.async {
                if kind == UInt32(kEventHotKeyPressed) {
                    monitor.firePress()
                } else if kind == UInt32(kEventHotKeyReleased) {
                    monitor.fireRelease()
                }
            }
            return noErr
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var installedHandler: EventHandlerRef?
        let installRC = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            specs.count,
            &specs,
            selfPtr,
            &installedHandler
        )
        if installRC != noErr {
            log.error("PTT (Carbon) start: InstallEventHandler FAILED rc=\(installRC, privacy: .public)")
            throw HotkeyError.tapInstallFailed
        }
        eventHandler = installedHandler

        // Register the actual hotkey. RegisterEventHotKey returns
        // -9878 (eventHotKeyExistsErr) if the binding is already in use
        // by another app.
        let hotKeyID = EventHotKeyID(signature: OSType(0x564B4248) /* "VKBH" */, id: 1)
        let modifiers = carbonModifiers(from: shortcut.modifiers)
        var ref: EventHotKeyRef?
        let registerRC = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if registerRC != noErr {
            log.error("PTT (Carbon) start: RegisterEventHotKey FAILED rc=\(registerRC, privacy: .public) (likely conflict with another app or a system shortcut)")
            if let h = eventHandler {
                RemoveEventHandler(h)
                eventHandler = nil
            }
            throw HotkeyError.tapInstallFailed
        }
        hotKeyRef = ref
        log.info("PTT (Carbon) start: hotkey registered")
    }

    public func stop() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        if let tap = fnEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = fnRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
                fnRunLoopSource = nil
            }
            fnEventTap = nil
        }
        bound = nil
    }

    fileprivate func firePress() {
        guard var b = bound, !b.isHeld else { return }
        b.isHeld = true
        bound = b
        log.info("PTT press fired")
        b.onPress()
    }

    fileprivate func fireRelease() {
        guard var b = bound, b.isHeld else { return }
        b.isHeld = false
        bound = b
        log.info("PTT release fired")
        b.onRelease()
    }

    private func carbonModifiers(from m: ModifierFlags) -> UInt32 {
        var out: UInt32 = 0
        if m.contains(.command) { out |= UInt32(cmdKey) }
        if m.contains(.option)  { out |= UInt32(optionKey) }
        if m.contains(.shift)   { out |= UInt32(shiftKey) }
        if m.contains(.control) { out |= UInt32(controlKey) }
        return out
    }
}

// File-scope C callback for the CGEventTap — mirrors OpenWhisper's
// macos-globe-listener.swift. userInfo is an unretained CarbonHotkeyMonitor.
private func fnGlobeEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<CarbonHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    // Re-enable the tap if the system disabled it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = monitor.fnEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    let letterKC = monitor.fnLetterKeyCode

    // fn+letter mode: detect via keyDown/keyUp on the target key code.
    if letterKC >= 0 {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown && event.flags.contains(.maskSecondaryFn) && keyCode == letterKC {
            log.info("CGEventTap keyDown fn+letter kc=\(keyCode, privacy: .public): press")
            DispatchQueue.main.async { monitor.firePress() }
            return nil  // swallow — prevent the letter from being typed
        }
        // Only swallow keyUp if PTT is currently held — otherwise regular
        // typing of the same key (no fn) would lose its keyUp and appear stuck.
        if type == .keyUp && keyCode == letterKC && monitor.isHeld {
            log.info("CGEventTap keyUp fn+letter kc=\(keyCode, privacy: .public): release")
            DispatchQueue.main.async { monitor.fireRelease() }
            return nil  // swallow
        }
        return Unmanaged.passUnretained(event)
    }

    // fn-alone / fn+modifier mode: detect via flagsChanged.
    guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
    let flags = event.flags
    let rawFlags = flags.rawValue
    var allHeld = flags.contains(.maskSecondaryFn)
    log.info("CGEventTap flagsChanged: raw=0x\(String(format: "%X", rawFlags), privacy: .public) maskSecondaryFn=\(allHeld, privacy: .public)")
    let req = monitor.fnRequired
    if req.contains(.shift)   { allHeld = allHeld && flags.contains(.maskShift) }
    if req.contains(.control) { allHeld = allHeld && flags.contains(.maskControl) }
    if req.contains(.option)  { allHeld = allHeld && flags.contains(.maskAlternate) }
    if req.contains(.command) { allHeld = allHeld && flags.contains(.maskCommand) }

    DispatchQueue.main.async {
        if allHeld { monitor.firePress() } else { monitor.fireRelease() }
    }
    return Unmanaged.passUnretained(event)
}
