import SwiftUI
import VoiceKeyboardCore

struct GeneralTab: View {
    @State var settings: UserSettings
    let onSave: (UserSettings) -> Void

    private let modelSizes = ["tiny", "base", "small", "medium", "large"]
    private let languages = ["auto", "en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh"]

    var body: some View {
        Form {
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
        .padding()
    }
}
