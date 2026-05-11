import SwiftUI
import HowlCore

struct VoiceTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let audioCapture: any AudioCapture
    let engine: any CoreEngine

    @State private var presenceTick = 0
    @State private var sheetPresented = false

    var body: some View {
        SettingsPane {
            SettingsGroupHeader("Voice models")
            modelStatusRow(label: "Voice extraction model",
                           url: ModelPaths.tseModel)
            modelStatusRow(label: "Speaker encoder",
                           url: ModelPaths.speakerEncoder)
            if !modelsPresent {
                Text(modelInstructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            SettingsGroupHeader("Voice profile")
            profileStatusRow
            HStack {
                Button(profilePresent ? "Re-record" : "Record Voice Sample") {
                    sheetPresented = true
                }
                .disabled(!modelsPresent)
                if profilePresent {
                    Button(role: .destructive) { deleteProfile() } label: { Text("Delete") }
                }
            }

            Divider()

            Toggle("Filter out background speakers (TSE)",
                   isOn: tseToggleBinding)
                .disabled(!modelsPresent || !profilePresent)
            Text("Uses your voice profile to suppress other speakers in the same recording.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            SettingsGroupHeader("Pipeline timeout")
            HStack(spacing: 6) {
                Text("Stop after")
                TextField("", value: timeoutBinding, format: .number)
                    .frame(width: 48)
                    .multilineTextAlignment(.trailing)
                Text("seconds")
                Spacer()
            }
            .font(.callout)
            Text("Maximum time the pipeline runs after you release the hotkey. Whatever cleanup output streamed before the timeout still gets pasted. 0 disables the bound.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $sheetPresented) {
            EnrollmentSheet(
                audioCapture: audioCapture,
                engine: engine,
                inputDeviceUID: settings.inputDeviceUID,
                onComplete: {
                    sheetPresented = false
                    presenceTick += 1
                    // Auto-enable TSE when the user successfully enrolled.
                    var s = settings; s.tseEnabled = true; settings = s; onSave(s)
                },
                onCancel: { sheetPresented = false }
            )
        }
    }

    private var modelsPresent: Bool {
        let _ = presenceTick
        return FileManager.default.fileExists(atPath: ModelPaths.tseModel.path) &&
               FileManager.default.fileExists(atPath: ModelPaths.speakerEncoder.path)
    }

    private var profilePresent: Bool {
        let _ = presenceTick
        let json = ModelPaths.voiceProfileDir.appendingPathComponent("speaker.json")
        let emb  = ModelPaths.voiceProfileDir.appendingPathComponent("enrollment.emb")
        return FileManager.default.fileExists(atPath: json.path) &&
               FileManager.default.fileExists(atPath: emb.path)
    }

    @ViewBuilder
    private var profileStatusRow: some View {
        if profilePresent {
            Label("Voice enrolled", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        } else {
            Label("Not enrolled", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange).font(.callout)
        }
    }

    @ViewBuilder
    private func modelStatusRow(label: String, url: URL) -> some View {
        let _ = presenceTick
        let exists = FileManager.default.fileExists(atPath: url.path)
        HStack {
            Text(label).font(.callout)
            Spacer()
            if exists {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
            } else {
                Label("Missing", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption)
            }
        }
    }

    private var modelInstructions: String {
        """
        Voice extraction models ship inside Release builds (the .app you \
        download from GitHub Releases). This Debug build doesn't bundle them — \
        from the repo root, run ./enroll.sh once to build the models into \
        core/build/models/ (Ctrl+C the recording prompt if you only want the \
        models — voice enrollment itself happens via the Enroll button \
        below, not the script). Then copy tse_model.onnx and \
        speaker_encoder.onnx into ~/Library/Application Support/VoiceKeyboard/models/.
        """
    }

    private var tseToggleBinding: Binding<Bool> {
        Binding(
            get: { settings.tseEnabled },
            set: { newValue in
                var s = settings; s.tseEnabled = newValue; settings = s; onSave(s)
            }
        )
    }

    private var timeoutBinding: Binding<Int> {
        Binding(
            get: { settings.pipelineTimeoutSec },
            set: { newValue in
                var s = settings
                s.pipelineTimeoutSec = max(0, newValue)
                settings = s
                onSave(s)
            }
        )
    }

    private func deleteProfile() {
        let dir = ModelPaths.voiceProfileDir
        for name in ["enrollment.wav", "enrollment.emb", "speaker.json"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        var s = settings; s.tseEnabled = false; settings = s; onSave(s)
        presenceTick += 1
    }
}
