import Foundation
import AppKit
import CoreGraphics

/// Save → set → ⌘V → wait → restore.
public actor ClipboardPasteInjector: TextInjector {
    private let pasteboard: PasteboardProtocol
    private let keystroke: KeystrokeSenderProtocol
    private let restoreDelay: TimeInterval

    public init(
        pasteboard: PasteboardProtocol,
        keystroke: KeystrokeSenderProtocol,
        restoreDelay: TimeInterval = 0.05
    ) {
        self.pasteboard = pasteboard
        self.keystroke = keystroke
        self.restoreDelay = restoreDelay
    }

    public func inject(_ text: String) async throws {
        guard !text.isEmpty else { return }
        let saved = await pasteboard.string()
        await pasteboard.clear()
        await pasteboard.setString(text)
        await keystroke.sendCmdV()
        try await Task.sleep(nanoseconds: UInt64(restoreDelay * 1_000_000_000))
        await pasteboard.clear()
        if let saved = saved {
            await pasteboard.setString(saved)
        }
    }
}

public final class SystemPasteboard: PasteboardProtocol, @unchecked Sendable {
    public init() {}
    public func string() async -> String? {
        NSPasteboard.general.string(forType: .string)
    }
    public func setString(_ s: String) async {
        NSPasteboard.general.setString(s, forType: .string)
    }
    public func clear() async {
        NSPasteboard.general.clearContents()
    }
}

public final class CGEventKeystrokeSender: KeystrokeSenderProtocol, @unchecked Sendable {
    public init() {}
    public func sendCmdV() async {
        let kVK_ANSI_V: CGKeyCode = 9
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: kVK_ANSI_V, keyDown: true),
           let up = CGEvent(keyboardEventSource: nil, virtualKey: kVK_ANSI_V, keyDown: false) {
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
