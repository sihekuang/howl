import SwiftUI
import AppKit

// Reusable building blocks for Settings. Each page wraps its body in
// `SettingsPane { … }` so spacing/padding stays consistent across the
// six tabs; `SettingsGroupHeader` labels a logical cluster of controls
// without the chrome of a Form Section. `VisualEffectBackground` is
// the translucent sidebar/window backing macOS uses on its own
// preference panes.

/// Standard layout container for a Settings page. All six pages wrap
/// their body in this so spacing, alignment, and outer padding stay
/// consistent. Use `Divider()` between logical groups inside the
/// container, and `SettingsGroupHeader` to label them.
struct SettingsPane<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding()
    }
}

/// Subtle group label — `.callout` weight on `.secondary` foreground.
/// Sits above a related cluster of controls. Use it inside
/// `SettingsPane` to give the cluster a name without the chrome of a
/// `Form` `Section` header.
struct SettingsGroupHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.callout).foregroundStyle(.secondary)
    }
}

/// Translucent backing matching macOS-native preference panes.
/// Wraps NSVisualEffectView; the sidebar material on the detail panel
/// gives the window the right level of depth without going opaque.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
