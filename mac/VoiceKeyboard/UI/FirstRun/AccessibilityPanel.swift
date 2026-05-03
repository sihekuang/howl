import SwiftUI
import VoiceKeyboardCore

struct AccessibilityPanel: View {
    let permissions: any AccessibilityPermissions
    let onComplete: () -> Void
    @State private var checking = false
    @State private var granted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: granted ? "checkmark.shield.fill" : "lock.shield")
                .font(.system(size: 60))
                .foregroundStyle(granted ? .green : .primary)
            Text(granted ? "Permission Granted" : "Grant Accessibility Permission")
                .font(.title)

            if granted {
                Text("VoiceKeyboard needs to restart to register the global hotkey with the new permission.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Restart VoiceKeyboard") {
                    AppRelaunch.relaunch()
                }
                .buttonStyle(.borderedProminent)
                Button("Continue Without Restart") {
                    onComplete()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                Text("VoiceKeyboard needs Accessibility permission to capture your hotkey and paste cleaned text.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Open System Settings") {
                    _ = permissions.requestTrust()
                    permissions.openSystemSettings()
                    checking = true
                }
                .buttonStyle(.borderedProminent)
                if checking {
                    Text("Waiting for permission…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(40)
        .task(id: checking) {
            guard checking else { return }
            while !permissions.isTrusted() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            granted = true
        }
    }
}
