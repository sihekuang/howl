import Foundation
import ServiceManagement
import os

/// Thin wrapper around macOS 13+'s SMAppService for the "open at login"
/// preference. Reading status is cheap; flipping it asks macOS to
/// register/unregister the app as a login item, which the user can
/// audit in System Settings → General → Login Items.
///
/// Falls back to a logged warning if SMAppService throws — the toggle
/// state in Settings reflects what macOS actually has registered, not
/// just what the user clicked.
@MainActor
enum LaunchAtLogin {
    private static let log = Logger(subsystem: "com.howl.app", category: "LaunchAtLogin")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            log.error("toggle failed: \(String(describing: error), privacy: .public)")
        }
    }
}
