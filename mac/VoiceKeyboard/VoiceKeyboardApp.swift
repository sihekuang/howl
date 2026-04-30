import SwiftUI
import VoiceKeyboardCore

@main
struct VoiceKeyboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Snapshot the current hotkey at scene-construction time. Real-time
        // reactivity to settings changes is deferred (would require an
        // @Observable on UserSettings).
        let shortcut: String = {
            let s = (try? appDelegate.composition.settings.get()) ?? UserSettings()
            return s.hotkey.displayString
        }()

        MenuBarExtra {
            MenuBarMenu(
                appState: appDelegate.composition.appState,
                hotkey: shortcut,
                quit: { NSApp.terminate(nil) }
            )
        } label: {
            MenuBarIcon(appState: appDelegate.composition.appState)
                .background(
                    // Register openWindow with AppDelegate so it can reliably
                    // open the settings window at launch — Window scenes are
                    // lazily realized and may not be in NSApp.windows yet.
                    Color.clear.onAppear {
                        appDelegate.openWindowBridge = { openWindow(id: $0) }
                    }
                )
        }
        .menuBarExtraStyle(.window)

        // Use a regular Window (not Settings { }) so we can openWindow
        // it programmatically at launch and apply NSWindow customisations
        // like .floating level.
        Window("Voice Keyboard", id: "settings") {
            SettingsView(composition: appDelegate.composition)
        }
        .keyboardShortcut(",", modifiers: [.command])

        Window("Welcome", id: "first-run") {
            FirstRunWindow(composition: appDelegate.composition) {
                NSApp.windows.first { $0.identifier?.rawValue == "first-run" }?.orderOut(nil)
                appDelegate.setupCompletedRetry()
            }
        }
        .windowResizability(.contentSize)
    }

}
