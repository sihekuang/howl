import SwiftUI
import VoiceKeyboardCore

@main
struct VoiceKeyboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(
                appState: appDelegate.composition.appState,
                openSettings: {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                },
                quit: { NSApp.terminate(nil) }
            )
        } label: {
            MenuBarIcon(appState: appDelegate.composition.appState)
        }
        .menuBarExtraStyle(.window)

        // Settings scene wired in Task 11.
    }
}
