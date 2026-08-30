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
