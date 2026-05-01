import SwiftUI
import VoiceKeyboardCore

struct ProviderTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let secrets: any SecretStore

    var body: some View {
        Form {
            // Provider picker comes in Task 7. For now just show the
            // Anthropic block to keep parity with the pre-refactor UI.
            LabeledContent("Provider") { Text("Anthropic") }
            AnthropicSection(settings: $settings, secrets: secrets)
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: settings) { _, new in onSave(new) }
    }
}
