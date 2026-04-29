import SwiftUI
import AppKit
import Carbon
import VoiceKeyboardCore

struct HotkeyTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let conflictChecker: any SymbolicHotkeyChecker

    @State private var isRecording = false
    @State private var conflicts: [SymbolicHotkeyConflict] = []

    var body: some View {
        Form {
            LabeledContent("Push-to-talk") {
                Button {
                    isRecording.toggle()
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
                                    settings.hotkey = shortcut
                                    onSave(settings)
                                    isRecording = false
                                    refreshConflicts()
                                },
                                onCancel: { isRecording = false }
                            )
                        }
                    }
                )
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
//
// SwiftUI doesn't give us an "intercept the next raw keystroke" hook, so we
// drop down to AppKit. The view becomes first responder while recording is
// active and overrides keyDown to capture the combo directly. This avoids
// CGEventTap entirely — no Accessibility prompt, no event-tap fragility.

private struct HotkeyListener: NSViewRepresentable {
    let onRecord: (VoiceKeyboardCore.KeyboardShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyListenerView {
        let view = KeyListenerView()
        view.onRecord = onRecord
        view.onCancel = onCancel
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: KeyListenerView, context: Context) {
        nsView.onRecord = onRecord
        nsView.onCancel = onCancel
    }
}

final class KeyListenerView: NSView {
    var onRecord: ((VoiceKeyboardCore.KeyboardShortcut) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Esc with no modifiers cancels.
        if event.keyCode == UInt16(kVK_Escape) && flags.isEmpty {
            onCancel?()
            return
        }

        // Require at least one modifier so we don't capture plain typing.
        guard !flags.isEmpty else { return }

        var modifiers: ModifierFlags = []
        if flags.contains(.shift)   { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option)  { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }

        onRecord?(VoiceKeyboardCore.KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers))
    }
}
