import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import HowlCore

private func blankImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private struct StubCapturer: WindowImageCapturing {
    let captured: CapturedWindow?
    func capture() async -> CapturedWindow? { captured }
}

private struct StubRecognizer: WindowImageTextRecognizing {
    let text: String?
    func recognizeText(in capture: CapturedWindow) async -> String? { text }
}

private struct StubTextReader: WindowTextReader {
    let snapshot: WindowSnapshot?
    func read() async -> WindowSnapshot? { snapshot }
}

/// A leaf source with no alternate, to pin the protocol default.
private struct FixedSource: ScreenContentSource {
    let content: ScreenContent?
    func read() async -> ScreenContent? { content }
}

private func window(_ width: Int = 800, _ height: Int = 600) -> CapturedWindow {
    CapturedWindow(bundleID: "com.a", windowTitle: "Doc", image: blankImage(width: width, height: height))
}

private func text(_ content: ScreenContent?) -> WindowSnapshot? {
    guard case .text(let snapshot) = content else { return nil }
    return snapshot
}

private func image(_ content: ScreenContent?) -> WindowImageCapture? {
    guard case .image(let capture) = content else { return nil }
    return capture
}

@Suite("OCRScreenContentSource")
struct OCRScreenContentSourceTests {

    @Test func yields_the_recognized_text_marked_as_a_screenshot_read() async {
        let source = OCRScreenContentSource(
            capturer: StubCapturer(captured: window()),
            recognizer: StubRecognizer(text: "thornwick_calibration_delta")
        )
        let snapshot = text(await source.read())
        #expect(snapshot?.text == "thornwick_calibration_delta")
        #expect(snapshot?.bundleID == "com.a")
        #expect(snapshot?.windowTitle == "Doc")
        // `.screenshot`, not `.accessibility`: the pixels were read.
        // Downstream this is the only thing that distinguishes OCR
        // text from AX text.
        #expect(snapshot?.source == .screenshot)
        #expect(snapshot?.fallbackReason == nil)
    }

    @Test func the_reading_is_text_and_carries_no_encoded_image() async {
        // PNG encoding belongs to the vision-model strategy alone. Here
        // the type system carries the guarantee: a `.text` reading has
        // no byte payload to encode INTO, so the OCR path cannot be
        // paying for an encode it does not use.
        let content = await OCRScreenContentSource(
            capturer: StubCapturer(captured: window()),
            recognizer: StubRecognizer(text: "some text")
        ).read()
        #expect(image(content) == nil)
        #expect(text(content) != nil)
    }

    @Test func a_screenshot_that_reads_as_blank_is_an_empty_reading_not_a_missing_one() async {
        // The distinction the fallback chain depends on. The window WAS
        // photographed and read; it simply had nothing legible in it.
        // Returning nil here would make a composed fallback fire and
        // quietly hand the user accessibility text for every blank
        // window — the brief's rule is that the fallback is for missing
        // pixels only.
        let source = OCRScreenContentSource(
            capturer: StubCapturer(captured: window()),
            recognizer: StubRecognizer(text: nil)
        )
        let content = await source.read()
        #expect(content != nil)
        #expect(text(content)?.text == "")
        #expect(text(content)?.source == .screenshot)
    }

    @Test func no_screenshot_at_all_is_a_missing_reading() async {
        // Screen Recording denied, no on-screen window, or the window
        // vanished mid-capture — the one outcome that means "ask
        // somebody else".
        let source = OCRScreenContentSource(
            capturer: StubCapturer(captured: nil),
            recognizer: StubRecognizer(text: "never reached")
        )
        #expect(await source.read() == nil)
    }
}

@Suite("VisionModelScreenContentSource")
struct VisionModelScreenContentSourceTests {

    @Test func yields_png_bytes_go_can_sniff_as_png() async {
        // Go decides the media type from the magic bytes alone
        // (`llm.DetectImageMediaType`) — there is no format parameter
        // on the ABI to correct a wrong guess, so the signature is the
        // whole contract.
        let content = await VisionModelScreenContentSource(
            capturer: StubCapturer(captured: window(640, 480))
        ).read()
        let capture = image(content)
        #expect(capture?.pngData.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(capture?.pixelSize == ScreenContextPixelSize(width: 640, height: 480))
        #expect(capture?.fallbackReason == nil)
    }

    @Test func downscales_an_oversize_capture_to_the_long_edge_cap() async {
        // The cap exists to cut what a remote model is billed for, and
        // applies to THIS strategy only — the OCR one reads the same
        // capture at native resolution because shrinking it is what
        // stops Vision recognizing small text.
        let content = await VisionModelScreenContentSource(
            capturer: StubCapturer(captured: window(3200, 2000))
        ).read()
        #expect(image(content)?.pixelSize == ScreenContextPixelSize(width: 1568, height: 980))
    }

    @Test func no_screenshot_at_all_is_a_missing_reading() async {
        let source = VisionModelScreenContentSource(capturer: StubCapturer(captured: nil))
        #expect(await source.read() == nil)
    }
}

@Suite("AXScreenContentSource")
struct AXScreenContentSourceTests {

    @Test func yields_the_readers_snapshot_unchanged() async {
        let snapshot = WindowSnapshot(bundleID: "com.a", windowTitle: "Doc",
                                      text: "AX text", source: .accessibility)
        let content = await AXScreenContentSource(reader: StubTextReader(snapshot: snapshot)).read()
        #expect(text(content) == snapshot)
    }

    @Test func no_readable_text_is_a_missing_reading() async {
        #expect(await AXScreenContentSource(reader: StubTextReader(snapshot: nil)).read() == nil)
    }
}

@Suite("FallbackScreenContentSource")
struct FallbackScreenContentSourceTests {

    private let primaryReading = ScreenContent.text(
        WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "OCR text", source: .screenshot))
    private let secondaryReading = ScreenContent.text(
        WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: "AX text", source: .accessibility))

    private func composed(primary: ScreenContent?, secondary: ScreenContent?) -> FallbackScreenContentSource {
        FallbackScreenContentSource(
            primary: FixedSource(content: primary),
            secondary: FixedSource(content: secondary),
            reasonWhenSecondaryUsed: .screenshotUnavailable
        )
    }

    @Test func uses_the_primary_when_it_reads_the_window() async {
        let content = await composed(primary: primaryReading, secondary: secondaryReading).read()
        #expect(text(content)?.text == "OCR text")
        // Nothing fell back, so nothing may claim it did.
        #expect(content?.fallbackReason == nil)
    }

    @Test func uses_the_secondary_only_when_the_primary_reads_nothing() async {
        let content = await composed(primary: nil, secondary: secondaryReading).read()
        #expect(text(content)?.text == "AX text")
        #expect(text(content)?.source == .accessibility)
    }

    @Test func stamps_its_reason_on_the_secondarys_reading() async {
        // Without this the record cannot say why the user is looking at
        // accessibility text, and "grant Screen Recording" becomes
        // unguessable from the inspector.
        let content = await composed(primary: nil, secondary: secondaryReading).read()
        #expect(content?.fallbackReason == .screenshotUnavailable)
    }

    @Test func stamps_the_reason_on_a_pixels_reading_too() async {
        // The stamp is written once, against `ScreenContent`, so it
        // cannot go missing when the strategies are composed the other
        // way round.
        let pixels = ScreenContent.image(WindowImageCapture(
            bundleID: "com.a", windowTitle: "Doc", pngData: Data([1, 2, 3]),
            pixelSize: ScreenContextPixelSize(width: 10, height: 10)))
        let content = await composed(primary: nil, secondary: pixels).read()
        #expect(image(content)?.fallbackReason == .screenshotUnavailable)
        #expect(image(content)?.pngData == Data([1, 2, 3]))
    }

    @Test func reads_nothing_when_neither_leg_can_read_the_window() async {
        #expect(await composed(primary: nil, secondary: nil).read() == nil)
    }

    @Test func the_alternate_is_the_secondary_without_the_primarys_reason() async {
        // `readAlternate` answers a caller that could not CONSUME the
        // primary's reading — the primary read the window perfectly
        // well. Stamping `screenshotUnavailable` here would report a
        // failure that did not happen; the caller stamps what actually
        // did.
        let source = composed(primary: primaryReading, secondary: secondaryReading)
        let alternate = await source.readAlternate()
        #expect(text(alternate)?.text == "AX text")
        #expect(alternate?.fallbackReason == nil)
    }

    @Test func a_leaf_source_has_no_alternate() async {
        // The protocol default. A leaf can only read the window one
        // way, and saying so is what lets the caller clear rather than
        // hang on to stale keywords.
        #expect(await FixedSource(content: primaryReading).readAlternate() == nil)
    }
}

/// The dimensions of what was photographed survive into the reading.
///
/// This is a diagnostic guarantee, not a cosmetic one. A capture that
/// recognises no text and a capture of a 159x22 scrap of window chrome
/// are the same record without it — which is precisely why the
/// wrong-window bug stayed invisible while it was happening.
@Suite("OCR readings carry what was photographed")
struct OCRReadingPixelSizeTests {
    @Test("a reading that recognised nothing still reports the size")
    func emptyReadingKeepsPixelSize() async {
        let source = OCRScreenContentSource(
            capturer: StubCapturer(captured: CapturedWindow(
                bundleID: "com.example.app",
                windowTitle: "",
                image: blankImage(width: 159, height: 22)
            )),
            recognizer: StubRecognizer(text: nil)
        )

        guard case .text(let snapshot)? = await source.read() else {
            Issue.record("expected a text reading"); return
        }
        #expect(snapshot.text.isEmpty)
        #expect(snapshot.pixelSize == ScreenContextPixelSize(width: 159, height: 22))
    }

    @Test("a successful reading reports it too")
    func successfulReadingKeepsPixelSize() async {
        let source = OCRScreenContentSource(
            capturer: StubCapturer(captured: CapturedWindow(
                bundleID: "com.example.app",
                windowTitle: "",
                image: blankImage(width: 2560, height: 2160)
            )),
            recognizer: StubRecognizer(text: "some recognised text")
        )

        guard case .text(let snapshot)? = await source.read() else {
            Issue.record("expected a text reading"); return
        }
        #expect(snapshot.pixelSize == ScreenContextPixelSize(width: 2560, height: 2160))
    }

    @Test("a reading with no pixels behind it reports no size")
    func axReadingHasNoPixelSize() async {
        let source = AXScreenContentSource(reader: StubTextReader(snapshot: WindowSnapshot(
            bundleID: "com.example.app", windowTitle: "", text: "text", source: .accessibility
        )))

        guard case .text(let snapshot)? = await source.read() else {
            Issue.record("expected a text reading"); return
        }
        #expect(snapshot.pixelSize == nil)
    }
}
