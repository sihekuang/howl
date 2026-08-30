import AppKit
import Foundation
import ScreenCaptureKit
import Vision

/// Screenshots the focused window and runs Apple's Vision OCR over it.
///
/// This is the fallback path for apps the Accessibility API cannot read
/// (Electron, Canvas, terminals). Constructing it does nothing; the
/// Screen Recording TCC prompt appears on the first actual `read()`.
/// Pixel buffers are never written to disk.
public struct OCRWindowTextReader: WindowTextReader {
    public init() {}

    public func read() async -> WindowSnapshot? {
        // See AXWindowTextReader.read(): `NSWorkspace.frontmostApplication`'s
        // thread affinity is undocumented by Apple (AppKit is documented
        // as run-loop-dependent and not daemon-safe, but nothing states
        // this specific accessor is safe off the main thread — and
        // nothing in the Swift 6 checker would catch a mistake here
        // either, since NSWorkspace carries no actor-isolation
        // annotation). Hop explicitly rather than lean on the
        // compiler's silence; do not remove this as "redundant".
        guard let (bundleID, pid) = await MainActor.run(body: { () -> (String, pid_t)? in
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let bundleID = app.bundleIdentifier else { return nil }
            return (bundleID, app.processIdentifier)
        }) else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let window = content.windows.first(where: {
                $0.owningApplication?.processID == pid && $0.isOnScreen
            }) else { return nil }

            // `SCStreamConfiguration.width/height` are measured in
            // pixels, but `window.frame` is in points — on a 2x Retina
            // display, sizing the config directly from the frame would
            // capture at half resolution per axis (a quarter of the
            // pixels) and degrade Vision's accuracy on the small glyphs
            // this feature most needs (dense code identifiers in
            // Electron editors and terminals). Scale by the content
            // filter's pointPixelScale, and ask for the best available
            // resolution explicitly rather than relying on defaults.
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)

            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )

            let text = try recognizeText(in: image)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return WindowSnapshot(
                bundleID: bundleID,
                windowTitle: window.title ?? "",
                text: trimmed
            )
        } catch {
            // Permission denied, window vanished mid-capture, or OCR
            // failure. All degrade to "no screen context" by design.
            return nil
        }
    }

    private func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // identifiers must not be "corrected"

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return "" }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
