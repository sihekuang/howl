import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import HowlCore

/// Counts how often the denylist was consulted, so a test can prove a
/// capturer or reader actually routed through the check rather than
/// happening to return nil for some unrelated reason.
private final class DenylistSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var consulted = 0
    private let userAdditions: [String]

    init(userAdditions: [String] = []) { self.userAdditions = userAdditions }

    var provider: @Sendable () -> ScreenContextDenylist {
        { [self] in
            lock.lock(); defer { lock.unlock() }
            consulted += 1
            return ScreenContextDenylist(userAdditions: userAdditions)
        }
    }

    var consultCount: Int {
        lock.lock(); defer { lock.unlock() }; return consulted
    }
}

private func lookup(_ bundleID: String, _ pid: pid_t = 4242) -> FrontmostAppLookup {
    { (bundleID: bundleID, pid: pid) }
}

private let noDenylist: @Sendable () -> ScreenContextDenylist = {
    ScreenContextDenylist(userAdditions: [])
}

/// The guarantee that a denylisted app is never captured or read at all.
///
/// These target `resolveReadableFrontmostApp` directly as well as the
/// capturer and the reader, and deliberately so: a capturer-level test
/// alone would have no teeth here, because both also return nil when
/// ScreenCaptureKit or AX fails against the synthetic pid these tests
/// inject — so "returns nil" cannot on its own distinguish "the
/// denylist stopped it" from "the capture failed anyway". The resolver
/// returns a value on the allowed path, so its tests DO distinguish,
/// and the consult count pins that both types actually route through it.
@Suite("ScreenContext capture denylist")
struct WindowTextReaderDenylistTests {

    @Test func resolver_allows_a_benign_app() async {
        let got = await resolveReadableFrontmostApp(
            denylist: noDenylist, lookup: lookup("com.apple.TextEdit", 99)
        )
        #expect(got?.bundleID == "com.apple.TextEdit")
        #expect(got?.pid == 99)
    }

    @Test func resolver_declines_a_built_in_denylisted_app() async {
        let got = await resolveReadableFrontmostApp(
            denylist: noDenylist, lookup: lookup("com.1password.1password")
        )
        #expect(got == nil)
    }

    @Test func resolver_declines_a_user_added_app() async {
        // Proves the injected denylist's CONTENT is consulted, not just
        // a hardcoded built-in list.
        let spy = DenylistSpy(userAdditions: ["com.example.Vault"])
        let got = await resolveReadableFrontmostApp(
            denylist: spy.provider, lookup: lookup("com.example.Vault")
        )
        #expect(got == nil)
        // ...and that the same app is allowed once it is not listed.
        let allowed = await resolveReadableFrontmostApp(
            denylist: noDenylist, lookup: lookup("com.example.Vault")
        )
        #expect(allowed?.bundleID == "com.example.Vault")
    }

    @Test func resolver_fails_closed_on_an_unidentifiable_app() async {
        // No frontmost app at all.
        #expect(await resolveReadableFrontmostApp(denylist: noDenylist, lookup: { nil }) == nil)
        // Present, but with an empty bundle ID — `shouldSkip` is
        // fail-closed on that, and must stay so.
        #expect(await resolveReadableFrontmostApp(denylist: noDenylist, lookup: lookup("")) == nil)
    }

    @Test func ax_reader_declines_a_denylisted_app() async {
        let spy = DenylistSpy()
        let reader = AXWindowTextReader(
            denylist: spy.provider, frontmostApp: lookup("com.1password.1password")
        )
        #expect(await reader.read() == nil)
        // Teeth: proves the read routed through the denylist rather
        // than returning nil because AX failed on the synthetic pid.
        #expect(spy.consultCount == 1)
    }

    @Test func screenshot_capturer_declines_a_denylisted_app_before_any_capture() async {
        // The scenario the whole guarantee exists for, now that the
        // screenshot is the PRIMARY path rather than a fallback: the
        // capturer must decline before it reaches ScreenCaptureKit, so
        // a password manager is never photographed — and so a
        // denylisted app never even triggers the Screen Recording
        // prompt.
        let spy = DenylistSpy()
        let capturer = ScreenCaptureKitWindowCapturer(
            denylist: spy.provider, frontmostApp: lookup("com.1password.1password")
        )
        #expect(await capturer.capture() == nil)
        #expect(spy.consultCount == 1)
    }

    @Test func screenshot_capturer_declines_a_user_added_app() async {
        let spy = DenylistSpy(userAdditions: ["com.example.Vault"])
        let capturer = ScreenCaptureKitWindowCapturer(
            denylist: spy.provider, frontmostApp: lookup("com.example.Vault")
        )
        #expect(await capturer.capture() == nil)
        #expect(spy.consultCount == 1)
    }

    @Test func every_content_source_declines_a_denylisted_app() async {
        // The guarantee is per-STRATEGY, not per-coordinator: whichever
        // source `CompositionRoot` installs, a denylisted app must be
        // refused inside the source itself, before any capture or AX
        // walk. A new strategy that forgot this would still pass every
        // coordinator test, because the coordinator's own pre-read gate
        // would mask it whenever the two observations happened to
        // agree.
        //
        // Each gets its own spy, so `consultCount` gives the assertion
        // teeth: "returned nil" alone cannot tell "the denylist stopped
        // it" from "ScreenCaptureKit/AX failed against the synthetic
        // pid these tests inject".
        let axSpy = DenylistSpy()
        let ocrSpy = DenylistSpy()
        let visionSpy = DenylistSpy()
        let sources: [(String, DenylistSpy, any ScreenContentSource)] = [
            ("AX", axSpy, AXScreenContentSource(
                reader: AXWindowTextReader(
                    denylist: axSpy.provider, frontmostApp: lookup("com.1password.1password")))),
            ("OCR", ocrSpy, OCRScreenContentSource(
                capturer: ScreenCaptureKitWindowCapturer(
                    denylist: ocrSpy.provider, frontmostApp: lookup("com.1password.1password")),
                recognizer: OCRWindowTextRecognizer())),
            ("vision model", visionSpy, VisionModelScreenContentSource(
                capturer: ScreenCaptureKitWindowCapturer(
                    denylist: visionSpy.provider, frontmostApp: lookup("com.1password.1password")))),
        ]
        for (name, spy, source) in sources {
            let content = await source.read()
            #expect(content == nil, "\(name) source read a denylisted app")
            #expect(spy.consultCount == 1, "\(name) source never consulted the denylist")
        }
    }

    @Test func the_composed_fallback_declines_a_denylisted_app_on_both_legs() async {
        // Composition must not open a hole: if the primary refuses, the
        // secondary is asked next, and it has to refuse for the same
        // reason rather than treating "the primary declined" as
        // permission to read.
        let spy = DenylistSpy()
        let composed = FallbackScreenContentSource(
            primary: OCRScreenContentSource(
                capturer: ScreenCaptureKitWindowCapturer(
                    denylist: spy.provider, frontmostApp: lookup("com.1password.1password")),
                recognizer: OCRWindowTextRecognizer()),
            secondary: AXScreenContentSource(
                reader: AXWindowTextReader(
                    denylist: spy.provider, frontmostApp: lookup("com.1password.1password"))),
            reasonWhenSecondaryUsed: .screenshotUnavailable
        )
        #expect(await composed.read() == nil)
        // Teeth: both legs really consulted the denylist, rather than
        // one of them returning nil for an unrelated reason.
        #expect(spy.consultCount == 2)
    }
}

/// The 1568px long-edge policy. Pure arithmetic, so it is pinned here
/// rather than left to a display-dependent integration test.
@Suite("Screenshot scaling")
struct ScreenshotScalingTests {

    @Test func leaves_an_image_already_within_the_cap_untouched() {
        // nil means "no resample" — a small window is encoded exactly
        // as captured rather than being needlessly softened.
        #expect(ScreenshotScaling.downscaledSize(width: 1200, height: 800) == nil)
        #expect(ScreenshotScaling.downscaledSize(width: 1568, height: 1568) == nil)
    }

    @Test func caps_the_long_edge_and_preserves_aspect_ratio() {
        let got = ScreenshotScaling.downscaledSize(width: 3136, height: 1960)
        #expect(got?.width == 1568)
        #expect(got?.height == 980)
    }

    @Test func caps_a_portrait_window_on_its_height() {
        let got = ScreenshotScaling.downscaledSize(width: 1000, height: 4000)
        #expect(got?.height == 1568)
        #expect(got?.width == 392)
    }

    @Test func never_rounds_a_sliver_down_to_zero_pixels() {
        // A 20000x3 strip scales to 1568 wide and 0.235 tall; a zero
        // dimension would fail CGContext creation and lose the capture
        // entirely.
        let got = ScreenshotScaling.downscaledSize(width: 20_000, height: 3)
        #expect(got?.width == 1568)
        #expect(got?.height == 1)
    }

    @Test func default_cap_is_the_documented_1568() {
        #expect(ScreenshotScaling.maxLongEdge == 1568)
    }
}

/// The image-production half of the VISION-MODEL strategy: the two
/// pure steps between ScreenCaptureKit and the ABI. They can be
/// exercised for real against a synthetic `CGImage`, unlike the
/// capture itself.
///
/// They belong to `VisionModelScreenContentSource` alone. The OCR
/// strategy reads the same capture in-process and must never pay for
/// either step — encoding is waste there, and the downscale would
/// destroy exactly the small glyphs it needs.
@Suite("Screenshot encoding")
struct ScreenshotEncodingTests {

    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func downscale_resamples_an_oversize_image_to_the_cap() {
        let scaled = VisionModelScreenContentSource.downscale(
            makeImage(width: 3200, height: 2000), maxLongEdge: 1568
        )
        #expect(scaled?.width == 1568)
        #expect(scaled?.height == 980)
    }

    @Test func downscale_returns_nil_for_an_image_already_within_the_cap() {
        // nil is the "encode the original" signal — no needless
        // resample of glyphs that are already small.
        #expect(VisionModelScreenContentSource.downscale(
            makeImage(width: 800, height: 600), maxLongEdge: 1568
        ) == nil)
    }

    @Test func encodePNG_produces_bytes_go_can_sniff_as_png() throws {
        // Go decides the media type from the magic bytes alone
        // (`llm.DetectImageMediaType`) — there is no format parameter on
        // the ABI to correct a wrong guess, so the signature is the
        // whole contract.
        let data = try #require(VisionModelScreenContentSource.encodePNG(makeImage(width: 64, height: 48)))
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        // ...and that they really decode back to the same pixel size.
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 64)
        #expect(decoded.height == 48)
    }
}

/// Which of an app's windows gets photographed.
///
/// The bug these pin down was found from the app's own logs: three
/// captures came back with no recognized text, and the retry pass took
/// ~18ms. Measured against the shipped recognizer, ~18ms per pass
/// corresponds to an image about 159x22 — a 800x600 capture already
/// costs 3.5x that. The capture had succeeded; it had simply
/// photographed the wrong window.
@Suite("Window choice among an app's on-screen windows")
struct WindowChoiceTests {
    private func candidate(
        _ pid: pid_t, _ width: CGFloat, _ height: CGFloat, onScreen: Bool = true
    ) -> WindowCandidate {
        WindowCandidate(pid: pid, isOnScreen: onScreen, width: width, height: height)
    }

    @Test("the real window wins over a transient that sorts ahead of it")
    func prefersTheLargestWindow() {
        // Exactly the shape observed live: Chrome's link-preview bubble
        // ahead of the browser window it belongs to.
        let windows = [
            candidate(3246, 159, 22),
            candidate(3246, 2560, 2160),
            candidate(3246, 1538, 1080),
        ]
        #expect(chooseWindow(from: windows, pid: 3246) == 1)
    }

    @Test("another app's larger window is never chosen")
    func ignoresOtherApps() {
        let windows = [
            candidate(3246, 159, 22),
            candidate(9999, 5120, 4320),
        ]
        #expect(chooseWindow(from: windows, pid: 3246) == 0)
    }

    @Test("an off-screen window is never chosen, however large")
    func ignoresOffScreenWindows() {
        let windows = [
            candidate(3246, 400, 300),
            candidate(3246, 5120, 4320, onScreen: false),
        ]
        #expect(chooseWindow(from: windows, pid: 3246) == 0)
    }

    @Test("equal areas keep the front-most window")
    func tiesKeepTheEarlierWindow() {
        let windows = [
            candidate(3246, 800, 600),
            candidate(3246, 800, 600),
        ]
        #expect(chooseWindow(from: windows, pid: 3246) == 0)
    }

    @Test("no on-screen window for this app means nothing to photograph")
    func noMatchIsNil() {
        let windows = [candidate(9999, 800, 600)]
        #expect(chooseWindow(from: windows, pid: 3246) == nil)
    }
}
