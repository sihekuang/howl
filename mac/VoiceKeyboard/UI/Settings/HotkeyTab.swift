import SwiftUI
import VoiceKeyboardCore

struct HotkeyTab: View {
    @Binding var settings: UserSettings

    var body: some View {
        Form {
            LabeledContent("Push-to-talk") {
                Text(settings.hotkey.displayString).font(.system(.body, design: .monospaced))
            }
            Text("To change: edit `defaults` for `com.voicekeyboard.app` (settings UI in v2).")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .formStyle(.grouped)
        .padding()
    }
}
