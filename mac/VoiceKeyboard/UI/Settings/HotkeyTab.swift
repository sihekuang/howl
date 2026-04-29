import SwiftUI
import VoiceKeyboardCore

struct HotkeyTab: View {
    @State var settings: UserSettings
    let onSave: (UserSettings) -> Void

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
