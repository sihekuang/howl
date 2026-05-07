// mac/VoiceKeyboard/UI/Settings/Pipeline/ComparePane.swift
import SwiftUI

/// Generic two-row pane for the Compare view: a header strip with a
/// label badge + subtitle, then the content (a SessionDetail in
/// production, but unconstrained at the type level so the pane stays
/// reusable for empty/error/running states too).
struct ComparePane<Content: View>: View {
    let label: String
    let labelColor: Color
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(labelColor)
                    .clipShape(Capsule())
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            content()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.secondary.opacity(0.25), lineWidth: 1)
        )
    }
}
