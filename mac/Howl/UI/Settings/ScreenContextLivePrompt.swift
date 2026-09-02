import HowlCore
import SwiftUI

/// What Whisper would receive if you dictated right now.
///
/// ## Why this is not in the detail pane
///
/// It used to live at the bottom of `ScreenContextActivityDetail`,
/// under the selected entry's own rows. That placement was wrong in a
/// way no wording could fix: these numbers describe the ENGINE's
/// current state, not the selected reading, but sitting inside the
/// detail column — below a row's properties, in the bottom-right of
/// the split — they read as belonging to whatever row was selected.
///
/// The previous attempt was a caption that turned orange and explained
/// the mismatch whenever an older entry was selected. It was accurate
/// and it still misled, because a reader takes position as the
/// stronger signal than a paragraph. Moving the group above the table
/// removes the association instead of arguing with it, and the warning
/// disappears along with the thing it was warning about.
///
/// It is also genuinely a header-level fact: there is exactly one
/// engine state, and it does not vary by which row you clicked.
struct ScreenContextLivePrompt: View {
    /// Live engine state, refetched by the parent whenever new
    /// activity lands. Nil when the preview could not be decoded.
    let preview: ScreenContextPreview?

    @State private var showFullPrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SettingsGroupHeader("Whisper prompt right now")
                Text("LIVE")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
            }
            Text("The current dictionary plus the last stored screen keywords. "
                 + "Rebuilt on every refresh — a denylist skip, including Howl's own "
                 + "window, applies an empty keyword set and clears it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                // Without this the enclosing column hands it an ideal
                // height of one line and SwiftUI truncates rather than
                // wraps.
                .fixedSize(horizontal: false, vertical: true)

            if let preview {
                dedupedRow(preview)
                tokenTrimRow(preview)
                whisperRow(preview)
            } else {
                Text("Whisper prompt preview unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Deduped

    @ViewBuilder
    private func dedupedRow(_ preview: ScreenContextPreview) -> some View {
        HStack(alignment: .top) {
            rowLabel("Deduped")
            Text(dedupedSummary(preview)).font(.callout)
            Spacer()
        }
    }

    private func dedupedSummary(_ preview: ScreenContextPreview) -> String {
        let dictDupes = preview.dropped.filter { $0.source == "screen" && $0.stage == "duplicate_of_dictionary" }.count
        let selfDupes = preview.dropped.filter { $0.source == "screen" && $0.stage == "duplicate" }.count
        let kept = max(preview.screenKeywords.count - dictDupes - selfDupes, 0)
        var parts: [String] = []
        if dictDupes > 0 { parts.append("\(dictDupes) already in dictionary") }
        if selfDupes > 0 { parts.append("\(selfDupes) repeated") }
        guard !parts.isEmpty else { return "\(kept) kept" }
        return "\(kept) kept · " + parts.joined(separator: " · ")
    }

    // MARK: - Token trim

    @ViewBuilder
    private func tokenTrimRow(_ preview: ScreenContextPreview) -> some View {
        HStack(alignment: .top) {
            rowLabel("Token trim")
            Text(tokenTrimSummary(preview)).font(.callout)
            Spacer()
        }
    }

    private func tokenTrimSummary(_ preview: ScreenContextPreview) -> String {
        let capStages: Set<String> = ["byte_prefilter", "screen_token_cap"]
        let droppedCount = preview.dropped.filter { $0.source == "screen" && capStages.contains($0.stage) }.count
        return "\(preview.screenApplied.count) kept · \(droppedCount) dropped · cap \(preview.maxScreenPromptTokens) tokens"
    }

    // MARK: - → Whisper

    @ViewBuilder
    private func whisperRow(_ preview: ScreenContextPreview) -> some View {
        HStack(alignment: .top) {
            rowLabel("→ Whisper")
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.prompt.isEmpty ? "(no prompt)" : preview.prompt)
                    .font(.callout.monospaced())
                    .lineLimit(showFullPrompt ? nil : 2)
                    .textSelection(.enabled)
                if preview.prompt.count > 160 {
                    Button(showFullPrompt ? "Show less" : "Show full prompt") {
                        showFullPrompt.toggle()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            Spacer()
            Text("\(preview.tokenCount)/\(preview.maxPromptTokens) tokens")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    /// Same 96pt gutter as the detail pane's rows, so the two groups
    /// read as one page rather than two designs.
    private func rowLabel(_ s: String) -> some View {
        Text(s)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 96, alignment: .leading)
    }
}
