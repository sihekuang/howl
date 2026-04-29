import Foundation
import CoreGraphics
import AppKit

/// Global CGEventTap-based monitor for a single shortcut. Captures both
/// keyDown and keyUp so push-to-talk semantics work cleanly.
public final class CGEventHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var bound: Bound?

    private struct Bound {
        let shortcut: KeyboardShortcut
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
        bound = Bound(
            shortcut: shortcut, onPress: onPress, onRelease: onRelease, isHeld: false
        )

        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let mon = Unmanaged<CGEventHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                mon.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            throw HotkeyError.tapInstallFailed
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        bound = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        guard var b = bound else { return }
        if type == .keyDown {
            if matches(event: event, shortcut: b.shortcut), !b.isHeld {
                b.isHeld = true
                bound = b
                b.onPress()
            }
        } else if type == .keyUp || type == .flagsChanged {
            if b.isHeld, !matches(event: event, shortcut: b.shortcut) {
                // Either the keyCode key went up or modifiers were dropped
                // → treat as release.
                b.isHeld = false
                bound = b
                b.onRelease()
            }
        }
    }

    private func matches(event: CGEvent, shortcut: KeyboardShortcut) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let want = shortcut.modifiers
        let allModsHeld =
            (!want.contains(.option)  || flags.contains(.maskAlternate)) &&
            (!want.contains(.command) || flags.contains(.maskCommand)) &&
            (!want.contains(.shift)   || flags.contains(.maskShift)) &&
            (!want.contains(.control) || flags.contains(.maskControl))
        return keyCode == shortcut.keyCode && allModsHeld
    }
}

public enum HotkeyError: Error {
    case tapInstallFailed
}
