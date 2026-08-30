import Foundation
import Testing
@testable import HowlCore

@Suite("ScreenContextDenylist")
struct ScreenContextDenylistTests {

    @Test func built_in_list_covers_password_managers() {
        let d = ScreenContextDenylist(userAdditions: [])
        #expect(d.shouldSkip(bundleID: "com.1password.1password") == true)
        #expect(d.shouldSkip(bundleID: "com.apple.keychainaccess") == true)
    }

    @Test func ordinary_apps_are_not_skipped() {
        let d = ScreenContextDenylist(userAdditions: [])
        #expect(d.shouldSkip(bundleID: "com.microsoft.VSCode") == false)
    }

    @Test func matching_is_case_insensitive() {
        let d = ScreenContextDenylist(userAdditions: [])
        #expect(d.shouldSkip(bundleID: "COM.1Password.1Password") == true)
    }

    @Test func user_additions_are_honoured() {
        let d = ScreenContextDenylist(userAdditions: ["com.example.diary"])
        #expect(d.shouldSkip(bundleID: "com.example.diary") == true)
    }

    @Test func nil_bundle_id_is_skipped() {
        // An unidentifiable window is not worth the privacy risk.
        let d = ScreenContextDenylist(userAdditions: [])
        #expect(d.shouldSkip(bundleID: nil) == true)
    }

    @Test func blank_user_additions_are_ignored() {
        let d = ScreenContextDenylist(userAdditions: ["", "   "])
        #expect(d.shouldSkip(bundleID: "com.microsoft.VSCode") == false)
    }
}
