import Foundation
import Testing
@testable import HowlCore

/// Records whether it was consulted and returns a canned snapshot.
private final class FakeReader: WindowTextReader, @unchecked Sendable {
    let snapshot: WindowSnapshot?
    private(set) var callCount = 0
    init(_ snapshot: WindowSnapshot?) { self.snapshot = snapshot }
    func read() async -> WindowSnapshot? {
        callCount += 1
        return snapshot
    }
}

private func snap(_ text: String) -> WindowSnapshot {
    WindowSnapshot(bundleID: "com.a", windowTitle: "Doc", text: text)
}

@Suite("FallbackWindowTextReader")
struct WindowTextReaderTests {

    @Test func uses_primary_when_it_yields_enough_text() async {
        let primary = FakeReader(snap(String(repeating: "a", count: 250)))
        let fallback = FakeReader(snap("fallback"))
        let r = FallbackWindowTextReader(primary: primary, fallback: fallback, minimumChars: 200)

        let got = await r.read()
        #expect(got?.text.count == 250)
        #expect(fallback.callCount == 0)
    }

    @Test func falls_back_when_primary_yields_too_little() async {
        let primary = FakeReader(snap("short"))
        let fallback = FakeReader(snap(String(repeating: "b", count: 300)))
        let r = FallbackWindowTextReader(primary: primary, fallback: fallback, minimumChars: 200)

        let got = await r.read()
        #expect(got?.text.count == 300)
        #expect(fallback.callCount == 1)
    }

    @Test func falls_back_when_primary_returns_nil() async {
        let primary = FakeReader(nil)
        let fallback = FakeReader(snap(String(repeating: "b", count: 300)))
        let r = FallbackWindowTextReader(primary: primary, fallback: fallback, minimumChars: 200)

        let got = await r.read()
        #expect(got?.text.count == 300)
        #expect(fallback.callCount == 1)
    }

    @Test func returns_primary_result_when_fallback_also_fails() async {
        // Better a short AX snapshot than nothing at all.
        let primary = FakeReader(snap("short"))
        let fallback = FakeReader(nil)
        let r = FallbackWindowTextReader(primary: primary, fallback: fallback, minimumChars: 200)

        let got = await r.read()
        #expect(got?.text == "short")
    }

    @Test func returns_nil_when_both_fail() async {
        let r = FallbackWindowTextReader(primary: FakeReader(nil), fallback: FakeReader(nil), minimumChars: 200)
        #expect(await r.read() == nil)
    }
}

/// Counts how often the denylist was consulted, so a test can prove a
/// reader actually routed through the check rather than happening to
/// return nil for some unrelated reason.
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

/// The guarantee that a denylisted app is never read at all.
///
/// These target `resolveReadableFrontmostApp` directly as well as the
/// readers, and deliberately so: a reader-level test alone would have no
/// teeth here, because both readers also return nil when AX or
/// ScreenCaptureKit fails against the synthetic pid these tests inject —
/// so "returns nil" cannot on its own distinguish "the denylist stopped
/// it" from "the read failed anyway". The resolver returns a value on
/// the allowed path, so its tests DO distinguish, and the reader tests
/// pin that the readers actually route through it.
@Suite("ScreenContext reader denylist")
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

    @Test func ocr_reader_declines_a_denylisted_app_before_any_capture() async {
        let spy = DenylistSpy()
        let reader = OCRWindowTextReader(
            denylist: spy.provider, frontmostApp: lookup("com.1password.1password")
        )
        #expect(await reader.read() == nil)
        #expect(spy.consultCount == 1)
    }

    @Test func composed_reader_cannot_screenshot_a_denylisted_app() async {
        // The scenario this whole guarantee exists for: the AX walk of
        // an Electron vault window yields too little, the composed
        // reader falls through to the screenshot reader, and that
        // reader must decline too. Uses the REAL readers, not fakes —
        // the fall-through is the step that would take the picture.
        let spy = DenylistSpy()
        let frontmost = lookup("com.1password.1password")
        let reader = FallbackWindowTextReader(
            primary: AXWindowTextReader(denylist: spy.provider, frontmostApp: frontmost),
            fallback: OCRWindowTextReader(denylist: spy.provider, frontmostApp: frontmost)
        )

        #expect(await reader.read() == nil)
        // Both readers consulted the denylist: the fall-through DID
        // happen (that is by design — the primary returning nil is
        // indistinguishable from "no usable text"), and the screenshot
        // reader independently declined before reaching ScreenCaptureKit.
        #expect(spy.consultCount == 2)
    }
}
