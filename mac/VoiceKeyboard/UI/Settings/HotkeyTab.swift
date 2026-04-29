import SwiftUI
import VoiceKeyboardCore

struct HotkeyTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let recorder: any HotkeyRecorder
    let conflictChecker: any SymbolicHotkeyChecker

    @State private var isRecording = false
    @State private var conflicts: [SymbolicHotkeyConflict] = []

    var body: some View {
        Form {
            LabeledContent("Push-to-talk") {
                Text(settings.hotkey.displayString).font(.system(.body, design: .monospaced))
            }

            HStack {
                Button(isRecording ? "Press a shortcut… (Esc to cancel)" : "Record New Shortcut") {
                    Task {
                        isRecording = true
                        defer { isRecording = false }
                        if let shortcut = await recorder.recordNext() {
                            settings.hotkey = shortcut
                            onSave(settings)
                            refreshConflicts()
                        }
                    }
                }
                .disabled(isRecording)
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
