import SwiftUI
import VoiceKeyboardCore

struct RecordingOverlayView: View {
    let appState: AppState
    @State private var samples: [Float] = []
    private let capacity = 32

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: appState.engineState == .processing ? "circle.dotted" : "mic.fill")
                .foregroundStyle(.white)
                .font(.system(size: 14, weight: .medium))
                .symbolEffect(
                    .pulse, options: .repeating,
                    isActive: appState.engineState == .processing
                )
            if appState.engineState == .processing {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                WaveformView(samples: samples)
                    .frame(width: 160, height: 22)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.78))
        )
        .onChange(of: appState.liveRMS) { _, new in
            samples.append(new)
            if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        }
        .onChange(of: appState.engineState) { _, new in
            if new == .idle { samples.removeAll() }
        }
    }
}
