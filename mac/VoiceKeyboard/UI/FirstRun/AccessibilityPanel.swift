import SwiftUI
import VoiceKeyboardCore

struct AccessibilityPanel: View {
    let permissions: any AccessibilityPermissions
    let onComplete: () -> Void
    @State private var checking = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 60))
            Text("Grant Accessibility Permission").font(.title)
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
        .padding(40)
        .task(id: checking) {
            guard checking else { return }
            while !permissions.isTrusted() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            onComplete()
        }
    }
}
