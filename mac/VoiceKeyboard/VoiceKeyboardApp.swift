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

        Settings {
            SettingsView(composition: appDelegate.composition)
        }

        Window("Welcome", id: "first-run") {
            FirstRunWindow(composition: appDelegate.composition) {
                NSApp.windows.first { $0.identifier?.rawValue == "first-run" }?.orderOut(nil)
            }
        }
        .windowResizability(.contentSize)
    }
}
