// mac/VoiceKeyboard/UI/Settings/Pipeline/SessionDetail.swift
import SwiftUI
import VoiceKeyboardCore
#if canImport(AppKit)
import AppKit
#endif

/// Right pane for the selected captured session. Shows the inline
/// transport bar (from the shared WAVPlayer), per-stage rows with
/// Play/Pause buttons, and transcript rows that open externally.
///
/// The WAVPlayer is owned by the parent (PlaygroundTab) so that a
/// session selection change can stop playback before the new session
/// renders.
struct SessionDetail: View {
    let manifest: SessionManifest
    @Bindable var player: WAVPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            transportBar
            ForEach(Array(manifest.stages.enumerated()), id: \.offset) { _, stage in
                stageRow(stage)
            }
            Divider().padding(.vertical, 4)
            transcriptRow(label: "raw.txt",     rel: manifest.transcripts.raw)
            transcriptRow(label: "dict.txt",    rel: manifest.transcripts.dict)
            transcriptRow(label: "cleaned.txt", rel: manifest.transcripts.cleaned)
        }
    }

    // MARK: - Transport bar

    /// True when the player's current URL belongs to one of THIS
    /// manifest's stages. Used to gate transport-bar visibility so a
    /// shared player (e.g. across Compare's two panes) doesn't render
    /// the same controls in both — only the pane that "owns" the
    /// playing source shows the bar.
    private var isPlayingOurSource: Bool {
        guard let url = player.currentURL else { return false }
        for stage in manifest.stages where SessionPaths.file(in: manifest.id, rel: stage.wav) == url {
            return true
        }
        return false
    }

    @ViewBuilder
    private var transportBar: some View {
        if isPlayingOurSource, let url = player.currentURL {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button {
                        if player.isPlaying { player.pause() } else { player.play(url: url) }
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                    Text(url.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 0.001)
                    )
                    .controlSize(.mini)

                    Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
                if let err = player.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let err = player.lastError {
            Text(err).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func stageRow(_ stage: SessionManifest.Stage) -> some View {
        let url = SessionPaths.file(in: manifest.id, rel: stage.wav)
        let isCurrent = player.currentURL == url
        HStack {
            Text(stage.name).font(.callout).bold()
            Text("(\(stage.kind))").foregroundStyle(.secondary).font(.caption)
            if isCurrent {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
            }
            Spacer()
            Text("\(stage.rateHz) Hz").foregroundStyle(.secondary).font(.caption.monospaced())
            if let sim = stage.tseSimilarity {
                Text("sim \(String(format: "%.2f", sim))")
                    .foregroundStyle(.secondary).font(.caption.monospaced())
            }
            Button {
                player.toggle(url: url)
            } label: {
                Label(
                    isCurrent && player.isPlaying ? "Pause" : "Play",
                    systemImage: isCurrent && player.isPlaying ? "pause" : "play"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func transcriptRow(label: String, rel: String) -> some View {
        HStack {
            Text(label).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
            Button {
                openExternal(rel: rel)
            } label: { Label("Open", systemImage: "doc.text") }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func openExternal(rel: String) {
        let url = SessionPaths.file(in: manifest.id, rel: rel)
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
