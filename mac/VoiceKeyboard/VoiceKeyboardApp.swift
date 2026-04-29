import SwiftUI

@main
struct VoiceKeyboardApp: App {
    var body: some Scene {
        MenuBarExtra("VoiceKeyboard", systemImage: "mic") {
            Text("Setup pending")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
