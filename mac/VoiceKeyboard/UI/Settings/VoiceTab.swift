import SwiftUI
import VoiceKeyboardCore

struct VoiceTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let audioCapture: any AudioCapture
    let engine: any CoreEngine

    @State private var presenceTick = 0
    @State private var sheetPresented = false

    var body: some View {
        Form {
            Section("Voice models") {
                modelStatusRow(label: "Voice extraction model",
                               url: ModelPaths.tseModel)
                modelStatusRow(label: "Speaker encoder",
                               url: ModelPaths.speakerEncoder)
                if !modelsPresent {
                    Text(modelInstructions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Voice profile") {
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
            }

            Section {
                Toggle("Filter out background speakers (TSE)",
                       isOn: tseToggleBinding)
                    .disabled(!modelsPresent || !profilePresent)
            } footer: {
                Text("Uses your voice profile to suppress other speakers in the same recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
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
        Voice extraction models are not yet bundled with the app. To install \
        them, run ./enroll.sh once in Terminal (it will build the models and \
        place them under core/build/models/), then copy tse_model.onnx and \
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

    private func deleteProfile() {
        let dir = ModelPaths.voiceProfileDir
        for name in ["enrollment.wav", "enrollment.emb", "speaker.json"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        var s = settings; s.tseEnabled = false; settings = s; onSave(s)
        presenceTick += 1
    }
}
