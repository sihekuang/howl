import Foundation
import CoreGraphics
import os

private let log = Logger(subsystem: "com.voicekeyboard.app", category: "Injector")

/// Types text at the focused field via synthetic Unicode keyboard
/// events. Used for streaming LLM output: each delta gets posted as a
/// keyDown/keyUp pair carrying the chunk's UTF-16 codepoints, so the
/// user sees text appear at the cursor character-by-character.
///
/// Like all CGEvent-based input synthesis on macOS, this requires
/// Accessibility permission. Without it, the events post but never
/// reach the focused app and nothing visible happens.
public final class CGEventTextTyper: StreamingTextInjector, @unchecked Sendable {
    public init() {}

    public func injectChunk(_ text: String) async throws {
        guard !text.isEmpty else { return }
        // Convert to UTF-16 code units; CGEvent's keyboard Unicode API
        // expects UniChar (16-bit) sequences. Surrogate pairs are
        // delivered together as part of the same keystroke.
        let utf16 = Array(text.utf16)
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
            let up   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            log.error("CGEventTextTyper: could not allocate CGEvent for \(text.count, privacy: .public) chars")
            return
        }
        utf16.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
        }
        // cgAnnotatedSessionEventTap routes the event through the
        // current login session; the focused app sees it like any
        // other key press.
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
