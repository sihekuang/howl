// mac/VoiceKeyboard/UI/Settings/Pipeline/TSELabView.swift
import SwiftUI
import UniformTypeIdentifiers
import VoiceKeyboardCore
#if canImport(AppKit)
import AppKit
#endif

/// Debug-only TSE Lab. Lets a developer upload a 2-speaker WAV, run
/// it through Target Speaker Extraction using their enrolled
/// embedding, and play the input + extracted output side-by-side.
/// Used to verify TSE works end-to-end without going through the
/// live capture pipeline.
///
/// Surfaced under Settings → Pipeline → TSE Lab in Developer Mode.
struct TSELabView: View {
    let client: any TSELabClient

    @State private var inputURL: URL? = nil
    @State private var outputURL: URL? = nil
    @State private var status: Status = .idle
    @State private var errorMessage: String? = nil
    @State private var player = WAVPlayer()

    enum Status: Equatable {
        case idle
        case running
        case ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            inputRow
            runButton
            if let err = errorMessage {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if status == .ready, let inURL = inputURL, let outURL = outputURL {
                Divider()
                comparisonRow(input: inURL, output: outURL)
            }
            transportBar
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TSE Lab")
                .font(.title3).bold()
            Text("Upload a 2-speaker WAV (16 kHz mono) and run Target Speaker Extraction against your enrolled voice. Listen to original vs extracted side-by-side.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var inputRow: some View {
        HStack(spacing: 8) {
            Button {
                pickInput()
            } label: {
                Label("Choose WAV…", systemImage: "doc.badge.plus")
            }
            if let url = inputURL {
                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var runButton: some View {
        HStack {
            Button {
                Task { await runTSE() }
            } label: {
                if status == .running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Running…")
                    }
                } else {
                    Label("Run TSE", systemImage: "play.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(inputURL == nil || status == .running)
            Spacer()
        }
    }

    @ViewBuilder
    private func comparisonRow(input: URL, output: URL) -> some View {
        HStack(alignment: .top, spacing: 12) {
            clipPanel(title: "Original", url: input)
            clipPanel(title: "Extracted", url: output)
        }
    }

    @ViewBuilder
    private func clipPanel(title: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).bold()
            HStack(spacing: 6) {
                Button {
                    player.toggle(url: url)
                } label: {
                    let isCurrent = player.currentURL == url
                    Label(
                        isCurrent && player.isPlaying ? "Pause" : "Play",
                        systemImage: isCurrent && player.isPlaying ? "pause" : "play"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var transportBar: some View {
        if let url = player.currentURL {
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
                        .truncationMode(.middle)

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
        }
    }

    // MARK: - Actions

    private func pickInput() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, UTType(filenameExtension: "wav") ?? .audio].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            // New input invalidates any prior result + playback.
            player.stop()
            inputURL = url
            outputURL = nil
            errorMessage = nil
            status = .idle
        }
        #endif
    }

    private func runTSE() async {
        guard let input = inputURL else { return }
        // Clear prior state.
        player.stop()
        outputURL = nil
        errorMessage = nil
        status = .running
        do {
            let out = try await client.extract(input: input)
            outputURL = out
            status = .ready
        } catch {
            errorMessage = "TSE failed: \(error.localizedDescription)"
            status = .idle
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
