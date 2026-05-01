import SwiftUI
import AppKit

// Reusable building blocks for Settings, ported from the OLED-saver
// project so the two apps' settings UIs feel like one design family.
// SettingsSection groups related controls into a labelled card;
// VisualEffectBackground is the translucent sidebar/window backing
// macOS uses on its own preference panes.

/// A labelled card grouping a set of settings controls. Used inside
/// each settings page's detail panel.
struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
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
