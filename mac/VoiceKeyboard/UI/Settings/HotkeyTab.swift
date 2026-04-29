import SwiftUI
import AppKit
import Carbon
import os
import VoiceKeyboardCore

private let log = Logger(subsystem: "com.voicekeyboard.app", category: "Hotkey")

struct HotkeyTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let conflictChecker: any SymbolicHotkeyChecker

    @State private var isRecording = false
    @State private var conflicts: [SymbolicHotkeyConflict] = []
    @State private var lastSeen: String? = nil

    var body: some View {
        Form {
            LabeledContent("Push-to-talk") {
                Button {
                    isRecording.toggle()
                    lastSeen = nil
                    log.info("HotkeyTab: record toggled isRecording=\(isRecording, privacy: .public)")
                } label: {
                    Text(isRecording ? "Press a shortcut… (Esc to cancel)" : settings.hotkey.displayString)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 180)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isRecording ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
                .background(
                    Group {
                        if isRecording {
                            HotkeyListener(
                                onRecord: { shortcut in
                                    log.info("HotkeyTab: recorded kc=\(shortcut.keyCode, privacy: .public) mods=\(String(format: "0x%X", shortcut.modifiers.rawValue), privacy: .public)")
                                    settings.hotkey = shortcut
                                    onSave(settings)
                                    isRecording = false
                                    refreshConflicts()
                                },
                                onCancel: {
                                    log.info("HotkeyTab: record cancelled")
                                    isRecording = false
                                },
                                onKeySeen: { description in
                                    lastSeen = description
                                }
                            )
                        }
                    }
                )
            }

            if isRecording, let lastSeen {
                Text("Last key seen: \(lastSeen)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if !conflicts.isEmpty {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("This shortcut conflicts with macOS").bold()
                            ForEach(conflicts, id: \.id) { c in
                                Text("• \(c.name)").font(.caption)
                            }
                            Text("macOS will intercept the keypress before VoiceKeyboard sees it. Disable the conflicting shortcut in System Settings → Keyboard → Keyboard Shortcuts, or pick a different binding above.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            refreshConflicts()
        }
    }

    private func refreshConflicts() {
        conflicts = conflictChecker.conflicts(for: settings.hotkey)
    }
}

// MARK: - NSView-based key listener

private struct HotkeyListener: NSViewRepresentable {
    let onRecord: (VoiceKeyboardCore.KeyboardShortcut) -> Void
    let onCancel: () -> Void
    let onKeySeen: (String) -> Void

    func makeNSView(context: Context) -> KeyListenerView {
        let view = KeyListenerView()
        view.onRecord = onRecord
        view.onCancel = onCancel
        view.onKeySeen = onKeySeen
        log.info("HotkeyListener: makeNSView")
        return view
    }

    func updateNSView(_ nsView: KeyListenerView, context: Context) {
        nsView.onRecord = onRecord
        nsView.onCancel = onCancel
        nsView.onKeySeen = onKeySeen
    }
}

final class KeyListenerView: NSView {
    var onRecord: ((VoiceKeyboardCore.KeyboardShortcut) -> Void)?
    var onCancel: (() -> Void)?
    var onKeySeen: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            log.error("KeyListenerView: viewDidMoveToWindow but no window")
            return
        }
        // Defer until the run loop ticks once — the SwiftUI hosting view
        // sometimes installs its own first responder right after we mount.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ok = window.makeFirstResponder(self)
            log.info("KeyListenerView: makeFirstResponder -> \(ok, privacy: .public). currentFirstResponder=\(String(describing: window.firstResponder), privacy: .public)")
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let desc = "kc=\(event.keyCode) flags=0x\(String(flags.rawValue, radix: 16))"
        log.info("KeyListenerView.keyDown \(desc, privacy: .public)")
        onKeySeen?(desc)

        if event.keyCode == UInt16(kVK_Escape) && flags.isEmpty {
            onCancel?()
            return
        }

        guard !flags.isEmpty else {
            log.debug("KeyListenerView: ignoring — no modifiers")
            return
        }

        var modifiers: ModifierFlags = []
        if flags.contains(.shift)   { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option)  { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }

        onRecord?(VoiceKeyboardCore.KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers))
    }

    // Some hosts route key events through performKeyEquivalent first
    // (e.g. when Cmd is held). Capture them here too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        log.info("KeyListenerView.performKeyEquivalent kc=\(event.keyCode, privacy: .public)")
        keyDown(with: event)
        return true
    }
}
