import SwiftUI

/// A pulsing rainbow halo that sits behind the recording-overlay pill
/// during dictation. Two stacked angular-gradient layers with different
/// blur radii give the halo depth; intensity and a small scale-pulse
/// are driven by smoothed RMS so the glow feels reactive without
/// strobing on noisy frames. The hue sweep is a slow continuous
/// rotation so the halo reads as alive even during quiet moments.
struct RainbowGlow: View {
    /// 0..1, smoothed RMS. Quiet ≈ 0, normal speech ≈ 0.05–0.2.
    /// We scale internally — caller passes the raw value.
    let level: Float

    /// Corner radius of the inner pill we're glowing around.
    var cornerRadius: CGFloat = 14

    /// How far past the pill bounds the halo extends. Drives how big
    /// the hosting panel needs to be in RecordingOverlayController.
    var halo: CGFloat = 28

    @State private var phase: Double = 0

    var body: some View {
        // Map RMS (typically 0–0.25 in normal speech) to a 0–1 intensity
        // with a floor so the glow is always faintly visible while
        // recording, not just on loud peaks.
        let intensity = max(0.20, min(1.0, Double(level) * 5.0))

        ZStack {
            haloLayer(blur: 26).opacity(0.55 * intensity)
            haloLayer(blur: 12).opacity(0.85 * intensity)
        }
        .padding(-halo)
        .scaleEffect(1.0 + CGFloat(intensity - 0.2) * 0.06)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
                phase = 360
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private func haloLayer(blur: CGFloat) -> some View {
        // Capsule (fully rounded ends) — the halo silhouette reads as
        // softer than the inner pill, which has a smaller corner radius.
        Capsule(style: .continuous)
            .fill(
                AngularGradient(
                    gradient: Gradient(colors: [
                        .red, .orange, .yellow, .green,
                        .blue, .purple, .pink, .red,
                    ]),
                    center: .center,
                    angle: .degrees(phase)
                )
            )
            .blur(radius: blur)
    }
}
