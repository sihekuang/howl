import AppKit

@MainActor
enum AppRelaunch {
    /// Launch a fresh instance of the current bundle and terminate this one.
    /// Used after the user grants Accessibility — event taps registered before
    /// the grant are unreliable until the process restarts.
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
