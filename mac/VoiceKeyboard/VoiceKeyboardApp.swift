import SwiftUI
import VoiceKeyboardCore

@main
struct VoiceKeyboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("VoiceKeyboard", systemImage: "mic") {
            // Replaced in Task 9 with the real menu bar UI.
            Text("VoiceKeyboard")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
