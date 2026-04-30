import SwiftUI
import VoiceKeyboardCore

@main
struct VoiceKeyboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(composition: appDelegate.composition)
        }

        Window("Welcome", id: "first-run") {
            FirstRunWindow(composition: appDelegate.composition) {
                NSApp.windows.first { $0.identifier?.rawValue == "first-run" }?.orderOut(nil)
                appDelegate.setupCompletedRetry()
            }
        }
        .windowResizability(.contentSize)

        Window("Playground", id: "playground") {
            PlaygroundTab(
                appState: appDelegate.composition.appState,
                hotkey: shortcutForLaunch(appDelegate),
                coordinator: appDelegate.composition.coordinator
            )
            .frame(minWidth: 520, minHeight: 360)
        }
        .windowResizability(.contentSize)
    }

    private func shortcutForLaunch(_ delegate: AppDelegate) -> VoiceKeyboardCore.KeyboardShortcut {
        let s = (try? delegate.composition.settings.get()) ?? UserSettings()
        return s.hotkey
    }
}
