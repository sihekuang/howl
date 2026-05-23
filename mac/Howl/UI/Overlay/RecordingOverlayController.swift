import AppKit
import SwiftUI
import HowlCore

@MainActor
public final class RecordingOverlayController {
    private var panel: NSPanel?
    private let appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public func show() {
        if panel == nil {
            panel = makePanel()
        }
        if let panel = panel {
            position(panel: panel)
            panel.orderFront(nil)
        }
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: RecordingOverlayView(appState: appState))
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 44)
        let panel = NSPanel(
            contentRect: host.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = host
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return panel
    }

    private func position(panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let s = screen.visibleFrame
        let pw = panel.frame.width
        let ph = panel.frame.height
        let x = s.midX - pw / 2
        let y = s.minY + 80
        _ = ph // silence unused warning
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
