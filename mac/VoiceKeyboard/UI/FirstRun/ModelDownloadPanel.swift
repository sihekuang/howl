import SwiftUI
import VoiceKeyboardCore

struct ModelDownloadPanel: View {
    let onComplete: () -> Void
    @State private var size: String = "small"
    @State private var downloader = ModelDownloader()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle").font(.system(size: 60))
            Text("Choose Transcription Model").font(.title)
            Picker("Model", selection: $size) {
                Text("Tiny (75MB)").tag("tiny")
                Text("Base (142MB)").tag("base")
                Text("Small (466MB) — recommended").tag("small")
                Text("Medium (1.5GB)").tag("medium")
                Text("Large (2.9GB)").tag("large")
            }
            .pickerStyle(.menu)
            switch downloader.state {
            case .idle:
                Button("Download") {
                    Task {
                        await downloader.download(size: size, to: ModelPaths.whisperModel(size: size))
                        if case .completed = downloader.state { onComplete() }
                    }
                }
                .buttonStyle(.borderedProminent)
            case .downloading(let p):
                ProgressView(value: p) { Text("Downloading… \(Int(p*100))%") }
            case .completed:
                Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let msg):
                Text("Failed: \(msg)").foregroundStyle(.red)
                Button("Retry") {
                    Task {
                        await downloader.download(size: size, to: ModelPaths.whisperModel(size: size))
                        if case .completed = downloader.state { onComplete() }
                    }
                }
            }
        }
        .padding(40)
    }
}
