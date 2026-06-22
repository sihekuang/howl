// mac/Howl/UI/Settings/Pipeline/TSELabView.swift
import SwiftUI
import UniformTypeIdentifiers
import HowlCore
#if canImport(AppKit)
import AppKit
#endif

/// Debug-only TSE Lab. Lets a developer either upload or record a
/// short clip, run it through Target Speaker Extraction using their
/// enrolled voice embedding, and play input + extracted side-by-side.
///
/// Surfaced under Settings → Pipeline → TSE Lab in Developer Mode.
struct TSELabView: View {
    let client: any TSELabClient
    @ObservedObject var recorder: TSELabRecorder

    @State private var labBackend: String = "ecapa"
    @State private var inputURL: URL? = nil
    @State private var outputURL: URL? = nil
    @State private var status: Status = .idle
    @State private var errorMessage: String? = nil
    @State private var player = WAVPlayer()

    // Tracks the last recorded WAV so we can clean it up if a new
    // record/upload supersedes it. Recordings live in NSTemporaryDirectory
    // and get cleaned on logout, but we still purge eagerly per session.
    @State private var previousRecordedURL: URL? = nil

    // Press-and-hold disambiguation.
    @State private var pressStartedAt: Date? = nil
    @State private var pressIntent: PressIntent = .none

    enum Status: Equatable { case idle, running, ready }
    enum PressIntent { case none, startFresh, stopToggle }

    /// Hold-vs-click threshold. Matches macOS long-press default.
    private let holdThreshold: TimeInterval = 0.25

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            inputRow
            if status == .running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Running TSE…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
        .onDisappear {
            if recorder.isRecording { recorder.cancel() }
            cleanupPreviousRecording()
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TSE Lab")
                .font(.title3).bold()
            Text("Upload a 2-speaker WAV (16 kHz mono) or record live; Target Speaker Extraction runs automatically against your enrolled voice. Listen to original vs extracted side-by-side.")
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
            .disabled(recorder.isRecording)

            recordButton

            if recorder.isRecording {
                Text(formatTime(recorder.elapsed))
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
            } else if let url = inputURL {
                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Picker("Backend", selection: $labBackend) {
                Text("ecapa").tag("ecapa")
                Text("pyannote").tag("pyannote")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        let dragGesture = DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard pressStartedAt == nil else { return } // first event of press only
                pressStartedAt = Date()
                if recorder.isRecording {
                    // Recording is running in toggle mode; this press will stop it on release.
                    pressIntent = .stopToggle
                } else {
                    // Starting a fresh recording. Whether it becomes hold or toggle is decided on release.
                    pressIntent = .startFresh
                    Task { await startRecording() }
                }
            }
            .onEnded { _ in
                let held = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                pressStartedAt = nil
                let intent = pressIntent
                pressIntent = .none
                switch intent {
                case .none:
                    break
                case .startFresh:
                    // Press-and-hold ≥ threshold → stop on release. Otherwise leave running
                    // in toggle mode; the next press will be .stopToggle.
                    if held >= holdThreshold {
                        Task { await stopRecording() }
                    }
                case .stopToggle:
                    Task { await stopRecording() }
                }
            }

        // Hand-styled to mimic .buttonStyle(.bordered) while allowing
        // a DragGesture to see pointer events that a real Button would swallow.
        HStack(spacing: 4) {
            if recorder.isRecording {
                Image(systemName: "stop.circle.fill")
                    .symbolRenderingMode(.multicolor)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Stop")
            } else {
                Image(systemName: "mic.circle")
                Text("Record")
            }
        }
        .font(.body)
        .foregroundStyle(recorder.isRecording ? Color.red : Color.accentColor)
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .gesture(dragGesture)
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
            cleanupPreviousRecording()
            invalidateForNewInput(url: url)
        }
        #endif
    }

    private func startRecording() async {
        do {
            errorMessage = nil
            try await recorder.start()
        } catch {
            errorMessage = "Recording failed to start: \(error.localizedDescription)"
        }
    }

    private func stopRecording() async {
        do {
            let url = try await recorder.stop()
            cleanupPreviousRecording()
            previousRecordedURL = url
            invalidateForNewInput(url: url)
        } catch {
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    private func invalidateForNewInput(url: URL) {
        player.stop()
        inputURL = url
        outputURL = nil
        errorMessage = nil
        status = .idle
        Task { await runTSE() }
    }

    private func cleanupPreviousRecording() {
        if let prev = previousRecordedURL {
            try? FileManager.default.removeItem(at: prev)
            previousRecordedURL = nil
        }
    }

    private func runTSE() async {
        guard let input = inputURL else { return }
        player.stop()
        outputURL = nil
        errorMessage = nil
        status = .running
        do {
            let out = try await client.extract(input: input, backend: labBackend)
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
