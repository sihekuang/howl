import SwiftUI

/// Circular buffer of recent RMS samples → bar graph rendered with Canvas.
struct WaveformView: View {
    let samples: [Float]   // newest at end
    let barCount = 32

    var body: some View {
        Canvas { context, size in
            let n = min(samples.count, barCount)
            guard n > 0 else { return }
            let barWidth = size.width / CGFloat(barCount)
            let centerY = size.height / 2
            let maxBarHeight = size.height * 0.9
            for i in 0..<n {
                let s = samples[samples.count - n + i]
                let h = max(2, CGFloat(s) * maxBarHeight)
                let x = CGFloat(i) * barWidth + barWidth * 0.2
                let rect = CGRect(
                    x: x,
                    y: centerY - h / 2,
                    width: barWidth * 0.6,
                    height: h
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth * 0.3),
                    with: .color(.white.opacity(0.85))
                )
            }
        }
    }
}
