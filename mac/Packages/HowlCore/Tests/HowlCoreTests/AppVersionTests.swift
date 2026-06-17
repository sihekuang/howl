import Foundation
import Testing
@testable import HowlCore

@Suite("AppVersion")
struct AppVersionTests {
    @Test func displayCopyAndLinks() {
        let v = AppVersion(short: "0.9.1", build: "23")
        #expect(v.displayString == "Version 0.9.1 (build 23)")
        #expect(v.copyString.hasPrefix("Howl 0.9.1 (build 23) · macOS"))
        #expect(v.repoURL.absoluteString == "https://github.com/sihekuang/howl")
        #expect(v.releaseNotesURL.absoluteString
            == "https://github.com/sihekuang/howl/releases/tag/mac-v0.9.1")
    }

    @Test func unknownFallback() {
        let v = AppVersion(short: nil, build: "")
        #expect(v.displayString == "Version unknown")
        #expect(v.releaseNotesURL.absoluteString
            == "https://github.com/sihekuang/howl/releases")
    }
}
