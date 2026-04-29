import Foundation
import CoreGraphics

public protocol HotkeyRecorder: Sendable {
    /// Capture the next keyDown event whose modifiers are non-empty.
    /// Returns nil if cancelled or if the user pressed Esc.
    func recordNext() async -> KeyboardShortcut?

    /// Cancel a recording in progress.
    func cancel()
}

/// CGEventTap-based recorder. Installs a temporary tap, captures one
/// keyDown with at least one modifier (so plain typing isn't recorded),
/// returns the shortcut. Pressing Esc with no modifiers cancels.
public final class CGEventHotkeyRecorder: HotkeyRecorder, @unchecked Sendable {
    private var continuation: CheckedContinuation<KeyboardShortcut?, Never>?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()

    public init() {}

    public func recordNext() async -> KeyboardShortcut? {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
            self.installTap()
        }
    }

    public func cancel() {
        finish(with: nil)
    }

    private func installTap() {
        let mask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<CGEventHotkeyRecorder>.fromOpaque(refcon).takeUnretainedValue()
                recorder.handle(type: type, event: event)
                // Swallow the event — it would be confusing to also fire whatever shortcut they hit.
                return nil
            },
            userInfo: userInfo
        ) else {
            finish(with: nil)
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        lock.lock()
        eventTap = tap
        runLoopSource = source
        lock.unlock()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        guard type == .keyDown else { return }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Esc with no modifiers cancels recording.
        if keyCode == KeyboardShortcut.kVK_Escape && !flags.contains(.maskCommand)
           && !flags.contains(.maskShift) && !flags.contains(.maskControl) && !flags.contains(.maskAlternate) {
            finish(with: nil)
            return
        }

        var modifiers: ModifierFlags = []
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }

        // Require at least one modifier. Plain key-only shortcuts would
        // collide with normal typing.
        guard !modifiers.isEmpty else { return }

        finish(with: KeyboardShortcut(keyCode: keyCode, modifiers: modifiers))
    }

    private func finish(with shortcut: KeyboardShortcut?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        lock.unlock()
        cont?.resume(returning: shortcut)
    }
}
