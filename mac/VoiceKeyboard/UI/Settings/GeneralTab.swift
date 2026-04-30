import SwiftUI
import VoiceKeyboardCore

struct GeneralTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let audioCapture: any AudioCapture

    @State private var devices: [AudioInputDevice] = []

    private let modelSizes = ["tiny", "base", "small", "medium", "large"]
    private let languages = ["auto", "en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh"]

    var body: some View {
        Form {
            // Bind through Optional<String> via a custom Picker tag.
            // "" tag represents "System Default".
            Picker("Microphone", selection: micBinding) {
                Text("System Default").tag("")
                ForEach(devices) { dev in
                    Text(dev.name).tag(dev.id)
                }
            }
            Picker("Whisper model", selection: $settings.whisperModelSize) {
                ForEach(modelSizes, id: \.self) { Text($0.capitalized).tag($0) }
            }
            Picker("Language", selection: $settings.language) {
                ForEach(languages, id: \.self) { Text($0).tag($0) }
            }
            Toggle("Disable noise suppression", isOn: $settings.disableNoiseSuppression)
        }
        .formStyle(.grouped)
        .onChange(of: settings) { _, new in onSave(new) }
        .task { devices = audioCapture.availableInputDevices() }
        .padding()
    }

    private var micBinding: Binding<String> {
        Binding(
            get: { settings.inputDeviceUID ?? "" },
            set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 }
        )
    }
}
