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
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let window = content.windows.first(where: {
                $0.owningApplication?.processID == app.processIdentifier && $0.isOnScreen
            }) else { return nil }

            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
            config.showsCursor = false

            let filter = SCContentFilter(desktopIndependentWindow: window)
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
