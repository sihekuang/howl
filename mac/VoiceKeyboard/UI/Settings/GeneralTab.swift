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
    /// Live read of SMAppService.mainApp.status. macOS can change this
    /// externally (e.g. user untoggles in System Settings), so re-read
    /// on `.task` rather than caching forever.
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled

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
                // Saved selection points to a device that isn't in the
                // discovery list (disconnected, or `.task` hasn't loaded
                // yet on first render). Without this stub the picker
                // binding has no matching tag and SwiftUI logs
                // "selection is invalid and does not have an associated
                // tag, this will give undefined results." Same pattern
                // OllamaSection uses for uninstalled models.
                if let savedUID = settings.inputDeviceUID,
                   !savedUID.isEmpty,
                   !devices.contains(where: { $0.id == savedUID }) {
                    Text("\(displayName(for: savedUID)) — not connected").tag(savedUID)
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

            Toggle("Open at login", isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { newValue in
                    LaunchAtLogin.setEnabled(newValue)
                    // Re-read so the toggle reflects whether macOS
                    // actually accepted the change (it can decline).
                    launchAtLoginEnabled = LaunchAtLogin.isEnabled
                }
            ))
        }
        .formStyle(.grouped)
        .onChange(of: settings) { _, new in onSave(new) }
        .task {
            devices = audioCapture.availableInputDevices()
            // Auto-select a real device when the user hasn't picked one
            // and any are available. Without this the picker sticks on
            // "System Default" indefinitely, which is opaque about which
            // mic the engine actually grabs. nil means "never picked";
            // an explicit "" (System Default) is preserved.
            if settings.inputDeviceUID == nil, let first = devices.first {
                settings.inputDeviceUID = first.id
            }
            modelStatusTick += 1
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
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
            // Picking "System Default" (tag "") writes "" — distinct
            // from nil ("never picked"). Auto-default in .task only
            // fires when nil, so an explicit System Default sticks.
            // The engine treats non-nil-empty the same as nil
            // (AudioCapture: `if let uid, !uid.isEmpty`), so this is
            // purely about preserving user intent in the picker.
            set: { settings.inputDeviceUID = $0 }
        )
    }

    /// Best-effort friendly name from a Core Audio UID. macOS UIDs for
    /// USB devices come through as colon-delimited strings whose third
    /// segment is the model name, e.g.
    ///   AppleUSBAudioEngine:Creative Technology Ltd:SB Katana SE:6E0…:5
    /// becomes "SB Katana SE". Falls back to the whole UID for unknown
    /// formats (Bluetooth, AirPods, virtual devices) — better than
    /// showing nothing.
    private func displayName(for uid: String) -> String {
        let parts = uid.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 3 {
            let model = parts[2].trimmingCharacters(in: .whitespaces)
            if !model.isEmpty { return model }
        }
        return uid
    }
}
