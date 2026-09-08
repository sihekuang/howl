import CoreGraphics
import Foundation

/// Answers "did anything on this window move since last tick?" for a
/// few milliseconds, so that Vision — ~1.4s of multi-core CPU on a
/// 2560×1080 capture, measured 2026-09-08 — is not asked to re-read a
/// window that is showing the same pixels it showed 15 seconds ago.
///
/// The signature is a 64×36 grayscale point sample of the capture.
/// Point sampling rather than box averaging on purpose: averaging a
/// cell that spans a whole line of text is nearly invariant to the
/// text scrolling by a line, which is precisely the change that must
/// be noticed. A single sampled pixel flips from glyph to gap instead.
/// A blinking caret or a changing clock digit lands on at most a
/// sample or two out of 2,304, far under the threshold; a scroll, a
/// new message or a swapped view flips hundreds.
public enum ScreenshotChangeDetector {
    public static let width = 64
    public static let height = 36

    public static func signature(of image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    /// Mean absolute difference, normalized to 0...1. Signatures of
    /// different sizes are treated as entirely different.
    public static func distance(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var total = 0
        for i in a.indices {
            total += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(total) / Double(a.count * 255)
    }
}
