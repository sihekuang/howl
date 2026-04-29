import SwiftUI
import VoiceKeyboardCore

/// A scratch text field where the user can try the full dictation flow
/// without leaving the app: focus the editor, hold the PTT hotkey, speak,
/// release. The cleaned text is pasted into the currently focused field —
/// which is this one when the playground tab is open.
struct PlaygroundTab: View {
    let appState: AppState
    let hotkey: VoiceKeyboardCore.KeyboardShortcut

    @State private var scratch: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusBanner

            Text("Click into the box below, then hold \(Text(hotkey.displayString).font(.system(.body, design: .monospaced).bold())) and speak. Release to transcribe — the cleaned text appears here.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $scratch)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.secondary.opacity(0.3))
                )
                .frame(minHeight: 140)

            HStack {
                if appState.engineState == .recording {
                    rmsMeter
                }
                Spacer()
                Button("Clear") { scratch = "" }
                    .disabled(scratch.isEmpty)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch appState.engineState {
        case .idle:
            Label("Ready — hold \(hotkey.displayString) to dictate", systemImage: "mic")
                .foregroundStyle(.secondary)
        case .recording:
            Label("Listening…", systemImage: "waveform.circle.fill")
                .foregroundStyle(.red)
        case .processing:
            Label("Processing…", systemImage: "ellipsis.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var rmsMeter: some View {
        let level = CGFloat(min(max(appState.liveRMS * 6, 0), 1))
        return HStack(spacing: 4) {
            ForEach(0..<10) { i in
                let threshold = CGFloat(i) / 10.0
                RoundedRectangle(cornerRadius: 2)
                    .fill(level > threshold ? Color.red : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 14)
            }
        }
    }
}
