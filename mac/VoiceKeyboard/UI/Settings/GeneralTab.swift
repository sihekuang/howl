import SwiftUI
import VoiceKeyboardCore

struct GeneralTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let audioCapture: any AudioCapture

    @State private var devices: [AudioInputDevice] = []
    @State private var downloader = ModelDownloader()
    /// Bumps every time we want SwiftUI to re-evaluate isDownloaded
    /// (after a download completes / after launch / after switching).
    @State private var modelStatusTick = 0

    private let modelSizes: [(size: String, label: String, mb: String)] = [
        ("tiny", "Tiny", "75 MB"),
        ("base", "Base", "142 MB"),
        ("small", "Small", "466 MB"),
        ("medium", "Medium", "1.5 GB"),
        ("large", "Large", "2.9 GB"),
    ]
    private let languages = ["auto", "en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh"]

    var body: some View {
        Form {
            Picker("Microphone", selection: micBinding) {
                Text("System Default").tag("")
                ForEach(devices) { dev in
                    Text(dev.name).tag(dev.id)
                }
            }
            Picker("Whisper model", selection: $settings.whisperModelSize) {
                ForEach(modelSizes, id: \.size) { m in
                    Text(modelLabel(for: m)).tag(m.size)
                }
            }
            modelStatusRow
            Picker("Language", selection: $settings.language) {
                ForEach(languages, id: \.self) { Text($0).tag($0) }
            }
            Toggle("Disable noise suppression", isOn: $settings.disableNoiseSuppression)
        }
        .formStyle(.grouped)
        .onChange(of: settings) { _, new in onSave(new) }
        .task {
            devices = audioCapture.availableInputDevices()
            modelStatusTick += 1
        }
        .padding()
    }

    @ViewBuilder
    private var modelStatusRow: some View {
        let size = settings.whisperModelSize
        let path = ModelPaths.whisperModel(size: size).path
        // modelStatusTick is referenced so SwiftUI re-evaluates after
        // a download completes.
        let _ = modelStatusTick
        let downloaded = FileManager.default.fileExists(atPath: path)

        switch downloader.state {
        case .downloading(let p):
            HStack {
                ProgressView(value: p)
                Text("\(Int(p * 100))%").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            HStack {
                Label("Download failed: \(msg)", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption)
                Spacer()
                Button("Retry") { Task { await runDownload(size: size) } }
            }
        default:
            HStack {
                if downloaded {
                    Label("Model downloaded", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                } else {
                    Label("Not downloaded", systemImage: "arrow.down.circle")
                        .foregroundStyle(.orange).font(.caption)
                }
                Spacer()
                if !downloaded {
                    Button("Download \(size.capitalized)") {
                        Task { await runDownload(size: size) }
                    }
                }
            }
        }
    }

    private func runDownload(size: String) async {
        await downloader.download(size: size, to: ModelPaths.whisperModel(size: size))
        modelStatusTick += 1
    }

    private func modelLabel(for m: (size: String, label: String, mb: String)) -> String {
        let path = ModelPaths.whisperModel(size: m.size).path
        let mark = FileManager.default.fileExists(atPath: path) ? "✓" : " "
        return "\(mark) \(m.label) (\(m.mb))"
    }

    private var micBinding: Binding<String> {
        Binding(
            get: { settings.inputDeviceUID ?? "" },
            set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 }
        )
    }
}
