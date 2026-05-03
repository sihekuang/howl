// mac/VoiceKeyboard/UI/Settings/Pipeline/CompareCard.swift
import SwiftUI
import VoiceKeyboardCore

/// One result of a Compare run. Header has the preset name + total
/// wall time + a TSE-output ▶ button. Body shows raw / dict / cleaned
/// transcripts in labeled blocks. The "closest match" border highlights
/// whichever preset's cleaned text is the lowest Levenshtein distance
/// to the original dictation.
struct CompareCard: View {
    let result: ReplayResult
    let isClosestMatch: Bool
    let onPlayTSE: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let err = result.error {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                transcriptBlock("RAW", text: result.raw)
                transcriptBlock("DICT", text: result.dict)
                transcriptBlock("CLEANED", text: result.cleaned, emphasized: true)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isClosestMatch ? Color.accentColor : .secondary.opacity(0.3),
                              lineWidth: isClosestMatch ? 2 : 1)
        )
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text(result.preset).font(.callout).bold()
            if isClosestMatch {
                Text("closest match")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            Text(formatMs(result.totalMs))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Button {
                onPlayTSE()
            } label: { Image(systemName: "play.circle") }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(result.replayDir == nil)
            .help("Play TSE output")
        }
    }

    @ViewBuilder
    private func transcriptBlock(_ label: String, text: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(text.isEmpty ? "(empty)" : text)
                .font(emphasized ? .body : .callout)
                .foregroundStyle(emphasized ? Color.primary : Color.secondary)
                .textSelection(.enabled)
        }
    }

    private func formatMs(_ ms: Int64) -> String {
        let s = Double(ms) / 1000
        return String(format: "%.1fs", s)
    }
}
