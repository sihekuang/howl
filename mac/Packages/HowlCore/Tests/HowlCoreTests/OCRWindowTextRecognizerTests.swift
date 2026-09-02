import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import HowlCore

/// A blank bitmap of a given size. The injected-recognizer tests never
/// look at the pixels — only at how the image is carved up.
private func blankImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func captured(_ image: CGImage) -> CapturedWindow {
    CapturedWindow(bundleID: "com.a", windowTitle: "Doc", image: image)
}

/// Records every tile it is handed and answers with whatever the test
/// programmed for that tile's height, so the tiling, dedupe, byte cap
/// and silent-zero retry can be tested without depending on what a
/// particular Vision build makes of a synthetic bitmap.
private final class TileSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _heights: [Int] = []
    private var _calls = 0
    /// Height -> lines. A height with no entry answers nothing.
    private let answers: [Int: [String]]
    /// Overrides `answers` when set: called with the invocation index.
    private let byIndex: (@Sendable (Int) -> [String])?

    init(answers: [Int: [String]] = [:], byIndex: (@Sendable (Int) -> [String])? = nil) {
        self.answers = answers
        self.byIndex = byIndex
    }

    var tileHeights: [Int] { withLock { _heights } }
    var callCount: Int { withLock { _calls } }

    var recognize: @Sendable (CGImage) -> [String] {
        { [self] tile in
            let index: Int = withLock {
                _heights.append(tile.height)
                _calls += 1
                return _calls - 1
            }
            if let byIndex { return byIndex(index) }
            return answers[tile.height] ?? []
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The tile geometry the measurements established. Pure arithmetic, so
/// it is pinned here rather than left to whatever a live capture
/// happens to be.
@Suite("OCR tiling")
struct OCRTilingTests {

    @Test func defaults_are_the_measured_values() {
        // These four numbers ARE the finding. A whole-image request
        // over a real 1568x1323 capture returned zero observations;
        // 480-560px bands with 60-120px overlap recovered all six
        // planted identifiers. Changing them without re-measuring is
        // how this feature silently stops working.
        #expect(OCRTiling.defaultBandHeight == 512)
        #expect(OCRTiling.defaultOverlap == 96)
        #expect(OCRTiling.defaultMaxTileWidth == 1568)
        #expect(OCRTiling.retryBandHeight == 320)
        // The retry must be SMALLER: zero observations mean the text
        // was too small relative to the tile, and only less image per
        // request helps.
        #expect(OCRTiling.retryBandHeight < OCRTiling.defaultBandHeight)
    }

    @Test func an_image_within_one_window_is_not_split() {
        #expect(OCRTiling.spans(total: 400, window: 512, overlap: 96) == [0..<400])
        #expect(OCRTiling.spans(total: 512, window: 512, overlap: 96) == [0..<512])
    }

    @Test func spans_are_full_size_overlapping_and_flush_to_the_end() {
        // A 1323px-tall capture — the real one the measurements used.
        let rows = OCRTiling.spans(total: 1323, window: 512, overlap: 96)
        #expect(rows == [0..<512, 416..<928, 811..<1323])
        // Every window is the full band height, including the last:
        // a 40px sliver of a line is unreadable, so the final window
        // is pulled back to sit flush against the end instead.
        #expect(rows.allSatisfy { $0.count == 512 })
    }

    @Test func spans_leave_no_uncovered_row() {
        // The property that matters: text cannot fall between tiles.
        for total in [300, 513, 900, 1323, 2160, 5000] {
            let rows = OCRTiling.spans(total: total, window: 512, overlap: 96)
            let covered = Set(rows.flatMap { $0 })
            #expect(covered.count == total, "uncovered rows at total=\(total)")
        }
    }

    @Test func consecutive_spans_really_do_overlap() {
        // The overlap is what makes a line clipped by one tile's edge
        // whole inside its neighbour. Without it, dedupe would have
        // nothing to remove and the clipped line would be lost.
        let rows = OCRTiling.spans(total: 2000, window: 512, overlap: 96)
        let overlaps = zip(rows, rows.dropFirst()).map { $0.upperBound - $1.lowerBound }
        #expect(overlaps.count == rows.count - 1)
        // Exactly the requested overlap everywhere except the last
        // pair, where pulling the final window flush against the end
        // can only ever overlap MORE.
        #expect(overlaps.dropLast().allSatisfy { $0 == 96 })
        #expect(overlaps.allSatisfy { $0 >= 96 })
    }

    @Test func a_wide_capture_is_split_across_x_as_well_as_y() {
        // A 5120px-wide desktop grab yields ~200 characters as
        // full-width bands and twenty times that once it is also split
        // across X. Height alone is not enough.
        let tiles = OCRTiling.tiles(width: 5120, height: 2160)
        #expect(tiles.count == 20)                      // 4 columns x 5 rows
        #expect(Set(tiles.map(\.width)) == [1568])
        #expect(Set(tiles.map(\.height)) == [512])
        // ...while a capture already inside the known-good width is
        // banded on Y only.
        let narrow = OCRTiling.tiles(width: 1568, height: 1323)
        #expect(narrow.count == 3)
        #expect(Set(narrow.map(\.width)) == [1568])
    }

    @Test func tiles_are_ordered_top_to_bottom_then_left_to_right() {
        // So the recognized text arrives in roughly reading order.
        let tiles = OCRTiling.tiles(width: 3000, height: 1200)
        let sorted = tiles.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        #expect(tiles.map(\.origin) == sorted.map(\.origin))
        // ...and it really is more than one row and one column, or the
        // ordering above would be vacuous.
        #expect(Set(tiles.map(\.minY)).count > 1)
        #expect(Set(tiles.map(\.minX)).count > 1)
    }
}

/// Everything the reader does around the Vision call, driven through an
/// injected per-tile recognizer so the assertions are about this code
/// and not about a particular Vision build.
@Suite("OCR reader")
struct OCRWindowTextRecognizerTests {

    @Test func dedupes_lines_that_overlapping_tiles_read_twice() async {
        // 1200px tall at a 512px band is three tiles, and the overlap
        // means the same line really is read more than once.
        let spy = TileSpy(answers: [512: ["shared line"]])
        let reader = OCRWindowTextRecognizer(recognizeTile: spy.recognize)
        let text = await reader.recognizeText(in: captured(blankImage(width: 200, height: 1200)))
        #expect(spy.callCount == 3)
        #expect(text == "shared line")
    }

    @Test func keeps_the_lines_in_tile_order() async {
        let spy = TileSpy(byIndex: { ["line \($0)"] })
        let reader = OCRWindowTextRecognizer(recognizeTile: spy.recognize)
        let text = await reader.recognizeText(in: captured(blankImage(width: 200, height: 1200)))
        #expect(text == "line 0\nline 1\nline 2")
    }

    @Test func caps_output_at_the_byte_limit_the_go_extractor_uses() async {
        // The same 8192-byte ceiling the AX path respects, because both
        // feed `screenctx.MaxWindowTextBytes`, which would truncate
        // anything longer anyway.
        let line = String(repeating: "x", count: 100)
        let spy = TileSpy(byIndex: { index in (0..<500).map { "\(index)-\($0)-\(line)" } })
        let reader = OCRWindowTextRecognizer(recognizeTile: spy.recognize)
        let text = await reader.recognizeText(in: captured(blankImage(width: 200, height: 1200)))
        let bytes = try! #require(text).utf8.count
        #expect(bytes <= ScreenContextLimits.maxWindowTextBytesForExtraction)
        // ...and it really did fill up rather than stopping early for
        // some unrelated reason.
        #expect(bytes > ScreenContextLimits.maxWindowTextBytesForExtraction - 200)
    }

    @Test func a_capture_that_recognizes_nothing_is_retried_at_the_other_band_height() async {
        // THE SILENT-ZERO GUARD. Zero recognized characters from a real
        // capture is a suspected tiling failure, not an empty window —
        // and a naive whole-image implementation fails exactly this
        // way: silently, forever, looking perfectly healthy.
        //
        // The fake answers nothing at the 512px band and answers at the
        // 320px one, so the retry is the ONLY way this can produce
        // text.
        let spy = TileSpy(answers: [320: ["recovered by the retry"]])
        let reader = OCRWindowTextRecognizer(recognizeTile: spy.recognize)
        let text = await reader.recognizeText(in: captured(blankImage(width: 200, height: 1200)))
        #expect(text == "recovered by the retry")
        // The first pass really was the default band, and the second
        // really was the smaller one.
        #expect(spy.tileHeights.prefix(3) == [512, 512, 512])
        #expect(spy.tileHeights.dropFirst(3).allSatisfy { $0 == 320 })
        #expect(spy.tileHeights.count > 3)
    }

    @Test func gives_up_after_the_retry_rather_than_looping() async {
        let spy = TileSpy()   // answers nothing, ever
        let reader = OCRWindowTextRecognizer(recognizeTile: spy.recognize)
        let text = await reader.recognizeText(in: captured(blankImage(width: 200, height: 1200)))
        #expect(text == nil)
        // Exactly two passes: three tiles at 512, five at 320.
        #expect(spy.tileHeights == [512, 512, 512, 320, 320, 320, 320, 320])
    }

    @Test func a_pass_that_runs_out_of_budget_is_not_retried() async {
        // Budget exhaustion is not a tiling failure — the pass was cut
        // short before it could cover the image, and retrying at a
        // smaller band would mean MORE tiles and the same truncation,
        // only slower.
        let spy = TileSpy()
        let reader = OCRWindowTextRecognizer(budget: 0, recognizeTile: spy.recognize)
        let text = await reader.recognizeText(in: captured(blankImage(width: 200, height: 1200)))
        #expect(text == nil)
        #expect(spy.callCount == 0)
    }

    @Test func an_empty_recognition_is_nil_rather_than_an_empty_string() async {
        // The caller distinguishes "read the window, found nothing"
        // from "read the window, here is the text" by exactly this.
        let spy = TileSpy(answers: [512: ["   ", "\n"]])   // whitespace only
        let reader = OCRWindowTextRecognizer(recognizeTile: spy.recognize)
        #expect(await reader.recognizeText(in: captured(blankImage(width: 200, height: 1200))) == nil)
    }
}

/// The real Vision configuration, against real rendered pixels.
///
/// Rendered rather than committed as a binary, following the Go
/// fixture's precedent: the generator IS the fixture, it diffs, and it
/// can be regenerated at any size without a checked-in PNG going stale
/// against the identifiers the test asserts on.
@Suite("OCR reader against real Vision")
struct OCRWindowTextRecognizerVisionTests {

    /// Nonsense compounds shaped like the code identifiers this feature
    /// exists to catch, and absent from any language model's training
    /// data — so recognizing them can only mean the pixels were read.
    static let identifiers = [
        "thornwick_calibration_delta",
        "PLQ-88231-ZARN",
        "mistvale.parquet",
        "HoneggerBufferPool",
        "kx_flutterbye_threshold",
        "Ozymandias_Retry_7",
    ]

    /// A synthetic screenshot of a code editor: dense monospaced lines
    /// at a realistic on-screen size, filling the whole frame.
    private func renderedCode(width: Int, height: Int, fontSize: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        var y = CGFloat(height) - fontSize * 2
        var row = 0
        while y > fontSize {
            let identifier = Self.identifiers[row % Self.identifiers.count]
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "\(row)  let \(identifier) = compute(\(row), scale: 0.\(row))",
                attributes: attributes
            ))
            context.textPosition = CGPoint(x: 24, y: y)
            CTLineDraw(line, context)
            y -= fontSize * 1.6
            row += 1
        }
        return context.makeImage()!
    }

    private func recovered(from text: String?) -> Int {
        guard let text else { return 0 }
        return Self.identifiers.filter { text.localizedCaseInsensitiveContains($0) }.count
    }

    @Test func reads_identifiers_out_of_a_rendered_capture() async {
        let image = renderedCode(width: 1400, height: 900, fontSize: 12)
        let text = await OCRWindowTextRecognizer().recognizeText(in: captured(image))
        #expect(recovered(from: text) == Self.identifiers.count)
    }

    @Test func tiling_is_what_makes_a_large_capture_readable() async {
        // The measured fact this whole design exists for: handed a
        // large capture in ONE request, Vision downsamples it to a
        // fixed working resolution and small text stops being legible —
        // on a real 1568x1323 Chrome capture it returned zero
        // observations, silently. Tiling into fixed-PIXEL bands keeps
        // the text-to-tile ratio in the regime that works.
        //
        // The comparison is `>=` rather than "the whole-image request
        // returns nothing", so a future Vision that gets better at
        // large inputs cannot fail this test — but a regression that
        // removed tiling still does.
        let image = renderedCode(width: 2400, height: 1800, fontSize: 12)
        let tiled = await OCRWindowTextRecognizer().recognizeText(in: captured(image))
        // One tile covering everything: what a naive implementation
        // does. Retry disabled too, so the guard cannot rescue it.
        let untiled = await OCRWindowTextRecognizer(
            bandHeight: 4000, retryBandHeight: 4000, maxTileWidth: 4000
        ).recognizeText(in: captured(image))

        #expect(recovered(from: tiled) == Self.identifiers.count)
        #expect(recovered(from: tiled) >= recovered(from: untiled))
        #expect((tiled?.count ?? 0) >= (untiled?.count ?? 0))
    }
}
