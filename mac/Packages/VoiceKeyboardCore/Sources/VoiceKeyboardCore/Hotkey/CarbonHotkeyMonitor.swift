import AppKit
import Carbon
import os

private let log = Logger(subsystem: "com.voicekeyboard.app", category: "Hotkey")

/// Carbon Event-Manager-based global hotkey monitor.
///
/// We previously used `CGEvent.tapCreate` (a session-level event tap) for
/// PTT — that approach requires Input Monitoring (and Accessibility on
/// some macOS versions) and silently fails with `tapInstallFailed` when
/// the user hasn't granted both. Carbon's `RegisterEventHotKey` works
/// through the Window Server's hotkey machinery and needs none of those
/// TCC permissions, which is the right tradeoff for a PTT shortcut.
///
/// We subscribe to both `kEventHotKeyPressed` and `kEventHotKeyReleased`
/// so PTT semantics still work cleanly. The class is named for the
/// implementation strategy, not the protocol — older callsites referred
/// to `CGEventHotkeyMonitor`; that name is no longer accurate.
public final class CarbonHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var bound: Bound?

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
            // Tear down the handler we just installed so we don't leak.
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
        bound = nil
    }

    private func firePress() {
        guard var b = bound, !b.isHeld else { return }
        b.isHeld = true
        bound = b
        log.info("PTT press fired")
        b.onPress()
    }

    private func fireRelease() {
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
