import SwiftUI
import HowlCore

@main
struct HowlApp: App {
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
                openSettings: { appDelegate.showSettingsWindow() },
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
        // Standard NSMenu rendering — MenuBarMenu's Buttons + Dividers
        // become real menu items / separators with native styling. The
        // previous `.window` style produced a custom padded popup that
        // didn't match other macOS menu bar apps.
        .menuBarExtraStyle(.menu)

        // Use a regular Window (not Settings { }) so we can openWindow
        // it programmatically at launch and apply NSWindow customisations
        // (collection behaviour, focus on invoke). The window is at
        // .normal level — brought forward when invoked, not pinned
        // above other apps.
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
