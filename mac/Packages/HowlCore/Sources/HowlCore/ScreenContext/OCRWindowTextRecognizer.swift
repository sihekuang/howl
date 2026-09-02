import CoreGraphics
import Foundation
import OSLog
import Vision

/// Turns a captured window image into text. Implementations return nil
/// when nothing legible came back.
public protocol WindowImageTextRecognizing: Sendable {
    func recognizeText(in capture: CapturedWindow) async -> String?
}

/// Serial queue for the blocking half of an OCR pass.
///
/// `VNImageRequestHandler.perform` is SYNCHRONOUS and, on a large
/// capture tiled into a dozen requests, routinely runs for seconds.
/// Running that on a Swift cooperative-pool thread is forbidden for the
/// same reason the AX walk is (see `AXWindowTextReader`'s `axWalkQueue`,
/// where ignoring this froze the whole app in about three minutes): the
/// pool is sized to the core count, a blocked thread is never reclaimed
/// while it waits, and once the pool drains every task in the process
/// starves, MainActor UI work included.
///
/// Serial rather than concurrent on purpose: it caps concurrent OCR
/// passes at one, so a burst of focus changes queues instead of piling
/// CPU-hungry Vision requests on top of each other. Blocking THIS
/// queue's thread is fine — it is ours, and nothing else depends on it.
private let ocrQueue = DispatchQueue(
    label: "com.howl.app.screencontext-ocr", qos: .utility
)

/// `.notice` and above persist in the unified log; `.debug`/`.info` do
/// not survive past the live stream. A silent zero here is the only
/// signal anyone would ever get that tiling has stopped working, so it
/// has to be readable after the fact:
///   /usr/bin/log show --predicate 'subsystem == "com.howl.app"' --last 10m
/// These lines carry only counts and fixed strings — never recognized
/// text, never a window title.
private let ocrLog = Logger(subsystem: "com.howl.app", category: "screencontext")

/// Overlapping tile geometry, in PIXELS.
///
/// Pixels rather than fractions is the whole point: what governs
/// whether Vision can read a glyph is the ratio of text size to the
/// working resolution it downsamples the input to, so a tile has to be
/// a fixed physical size regardless of how big the capture is. A
/// fractional split would put a 4K window's tiles right back in the
/// regime that reads nothing.
public enum OCRTiling {
    /// Measured on a real 1568x1323 capture containing six invented
    /// identifiers: 480-560px bands with 60-120px overlap recovered
    /// 6/6; 300-400px bands recovered fewer; the whole image in one
    /// request recovered ZERO — not partial, nothing at all, silently.
    public static let defaultBandHeight = 512

    /// Retry height for the silent-zero guard. Deliberately SMALLER:
    /// zero observations mean the text was too small relative to the
    /// tile, and the only lever that helps is less image per request.
    public static let retryBandHeight = 320

    /// Enough that a line of text clipped by one tile's edge is whole
    /// inside its neighbour. Dedupe then removes the copy.
    public static let defaultOverlap = 96

    /// Widest tile handed to Vision. 1568px full-width bands are the
    /// configuration measured at 6/6, so anything at or below that is
    /// known-good and needs no X split. Wider inputs do: a 5120px-wide
    /// desktop grab yields ~200 characters as full-width bands and
    /// twenty times that once it is also split across X.
    public static let defaultMaxTileWidth = 1568

    /// Coverage windows of exactly `window` px (unless `total` is
    /// smaller), advancing by `window - overlap`, with the LAST window
    /// flush against the end.
    ///
    /// Flush-to-the-end rather than a short final window on purpose: a
    /// 40px sliver of a line is unreadable, and re-covering pixels the
    /// previous window already saw costs one more request and is
    /// removed by dedupe. Every row/column of the image is inside at
    /// least one window.
    public static func spans(total: Int, window: Int, overlap: Int) -> [Range<Int>] {
        guard total > 0, window > 0 else { return [] }
        if total <= window { return [0..<total] }
        let stride = max(1, window - min(overlap, window - 1))
        var out: [Range<Int>] = []
        var start = 0
        while start + window < total {
            out.append(start..<(start + window))
            start += stride
        }
        out.append((total - window)..<total)
        return out
    }

    /// Tile rects in CGImage coordinates (origin top-left), ordered
    /// top-to-bottom then left-to-right so the recognized text comes
    /// out in roughly reading order.
    public static func tiles(
        width: Int, height: Int,
        bandHeight: Int = defaultBandHeight,
        maxTileWidth: Int = defaultMaxTileWidth,
        overlap: Int = defaultOverlap
    ) -> [CGRect] {
        let rows = spans(total: height, window: bandHeight, overlap: overlap)
        let columns = spans(total: width, window: maxTileWidth, overlap: overlap)
        var out: [CGRect] = []
        out.reserveCapacity(rows.count * columns.count)
        for row in rows {
            for column in columns {
                out.append(CGRect(
                    x: column.lowerBound, y: row.lowerBound,
                    width: column.count, height: row.count
                ))
            }
        }
        return out
    }
}

/// Reads a captured window with Apple's on-device Vision OCR.
///
/// This is the primary screen-context path: the capture is read HERE,
/// locally, and only the resulting text is sent to the LLM for keyword
/// extraction — the same text path `AXWindowTextReader` feeds.
///
/// Three things about the Vision configuration are load-bearing and
/// were each established by measurement, not preference:
///
/// 1. **Tile.** A whole-image `VNRecognizeTextRequest` over a
///    1568x1323 capture returns ZERO observations — not partial,
///    nothing, silently, on revisions 1, 2 and 3. Vision downsamples
///    large inputs to a fixed working resolution, so small text stops
///    being legible. A naive whole-image implementation compiles, looks
///    right, and produces nothing forever. See `OCRTiling`.
/// 2. **`.accurate`, never `.fast`.** `.fast` returns plenty of text
///    and garbles exactly what matters: it read a planted
///    `PLQ-88231-ZARN` as `PLQ-B8231-ZAPII`, scoring 0/6 on the
///    identifiers this feature exists to catch.
/// 3. **`usesLanguageCorrection = false`.** Identifiers must never be
///    "corrected" into dictionary words — a corrected identifier is
///    worse than a missing one, because it biases whisper towards a
///    word that is not on screen.
///
/// The capture is NOT downscaled before any of this. The old 1568px
/// long-edge cap existed to cut vision-model token cost; local OCR has
/// no token cost, and shrinking the image is what breaks recognition.
public struct OCRWindowTextRecognizer: WindowImageTextRecognizing {
    private let bandHeight: Int
    private let retryBandHeight: Int
    private let overlap: Int
    private let maxTileWidth: Int
    /// Same 8192-byte ceiling the AX path respects, because this feeds
    /// the same Go function (`screenctx.MaxWindowTextBytes`), which
    /// would truncate anything longer anyway.
    private let maxBytes: Int
    /// Wall-clock ceiling on one pass. A 5120x2160 grab is 20 tiles and
    /// ~2.3s; an 8K one would be far more. Nothing downstream wants an
    /// unbounded background CPU burn per focus change, so a pass that
    /// overruns returns what it has instead of finishing.
    private let budget: TimeInterval
    /// The per-tile recognizer. Injectable ONLY so the tiling, dedupe,
    /// byte cap and silent-zero retry can be tested without depending
    /// on what a real Vision build recognizes in a synthetic bitmap;
    /// production always uses `visionRecognizeTile`.
    private let recognizeTile: @Sendable (CGImage) -> [String]

    public init(
        bandHeight: Int = OCRTiling.defaultBandHeight,
        retryBandHeight: Int = OCRTiling.retryBandHeight,
        overlap: Int = OCRTiling.defaultOverlap,
        maxTileWidth: Int = OCRTiling.defaultMaxTileWidth,
        maxBytes: Int = ScreenContextLimits.maxWindowTextBytesForExtraction,
        budget: TimeInterval = 10,
        recognizeTile: @escaping @Sendable (CGImage) -> [String] = OCRWindowTextRecognizer.visionRecognizeTile
    ) {
        self.bandHeight = bandHeight
        self.retryBandHeight = retryBandHeight
        self.overlap = overlap
        self.maxTileWidth = maxTileWidth
        self.maxBytes = maxBytes
        self.budget = budget
        self.recognizeTile = recognizeTile
    }

    public func recognizeText(in capture: CapturedWindow) async -> String? {
        // Everything below this line blocks. Get off the cooperative
        // pool before any of it runs — see `ocrQueue`.
        let image = capture.image
        return await withCheckedContinuation { continuation in
            ocrQueue.async {
                continuation.resume(returning: self.recognizeBlocking(image))
            }
        }
    }

    /// The blocking half. Only ever called on `ocrQueue`.
    func recognizeBlocking(_ image: CGImage) -> String? {
        let first = scan(image, bandHeight: bandHeight)
        if !first.text.isEmpty { return first.text }

        // SILENT-ZERO GUARD. Zero recognized characters from a real
        // capture is a suspected tiling failure, not an empty window —
        // an empty window still has a title bar, a tab, a menu. This
        // log line is the only signal a user or we would ever get that
        // the OCR has stopped working, which is why it is `.notice`
        // (persisted) rather than `.debug` (not).
        if first.ranOutOfBudget {
            // Not a tiling failure: the pass was cut short before it
            // could cover the image. Retrying at a smaller band would
            // mean MORE tiles and the same truncation, only slower.
            ocrLog.notice("screen context OCR recognized nothing before its \(Int(self.budget), privacy: .public)s budget expired")
            return nil
        }
        ocrLog.notice("screen context OCR recognized nothing at \(self.bandHeight, privacy: .public)px bands; retrying at \(self.retryBandHeight, privacy: .public)px")

        let retry = scan(image, bandHeight: retryBandHeight)
        if retry.text.isEmpty {
            ocrLog.notice("screen context OCR recognized nothing at either band height")
            return nil
        }
        return retry.text
    }

    private struct ScanResult {
        var text: String
        var ranOutOfBudget: Bool
    }

    /// One full pass over the image at a given band height.
    ///
    /// Lines are deduped because overlapping tiles deliberately re-read
    /// the same rows, and kept in tile order so the text arrives in
    /// roughly reading order.
    private func scan(_ image: CGImage, bandHeight: Int) -> ScanResult {
        let deadline = Date().addingTimeInterval(budget)
        let rects = OCRTiling.tiles(
            width: image.width, height: image.height,
            bandHeight: bandHeight, maxTileWidth: maxTileWidth, overlap: overlap
        )

        var seen = Set<String>()
        var lines: [String] = []
        var bytes = 0

        for rect in rects {
            if Date() > deadline {
                return ScanResult(text: lines.joined(separator: "\n"), ranOutOfBudget: true)
            }
            guard let tile = image.cropping(to: rect) else { continue }
            for candidate in recognizeTile(tile) {
                let line = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty || seen.contains(line) { continue }
                // +1 for the newline this line will be joined with.
                let cost = line.utf8.count + 1
                if bytes + cost > maxBytes {
                    return ScanResult(text: lines.joined(separator: "\n"), ranOutOfBudget: false)
                }
                seen.insert(line)
                lines.append(line)
                bytes += cost
            }
        }
        return ScanResult(text: lines.joined(separator: "\n"), ranOutOfBudget: false)
    }

    /// The production per-tile recognizer. See the type header for why
    /// `.accurate` and `usesLanguageCorrection = false` are not
    /// negotiable.
    public static let visionRecognizeTile: @Sendable (CGImage) -> [String] = { tile in
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: tile, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // A failed tile is not a failed pass: the other tiles may
            // still carry the window's text. The error is deliberately
            // not logged — it can quote the input.
            return []
        }
        guard let observations = request.results else { return [] }
        // Vision does not document an ordering. Sort into reading order
        // (top row first, then left to right) so the LLM sees the
        // window's text roughly as the user does; the 0.01 band keeps
        // words on one visual line together despite baseline jitter.
        return observations
            .sorted { a, b in
                if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 {
                    return a.boundingBox.midY > b.boundingBox.midY
                }
                return a.boundingBox.minX < b.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
    }
}
