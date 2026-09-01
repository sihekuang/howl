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

    @Test func built_in_list_covers_both_dashlane_bundle_ids() {
        // Current macOS bundle ID and the legacy (iOS-extension-derived)
        // one, kept side by side so older installs stay covered.
        let d = ScreenContextDenylist(userAdditions: [])
        #expect(d.shouldSkip(bundleID: "com.dashlane.Dashlane") == true)
        #expect(d.shouldSkip(bundleID: "com.dashlane.dashlanephonefinal") == true)
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

    @Test func skipEverything_skips_ordinary_apps_too() {
        // The fail-closed fallback for "settings unreadable": unlike
        // ScreenContextDenylist(userAdditions: []), which only covers
        // the built-in password-manager list, this must refuse every
        // window, including ones that would otherwise be fine to read.
        let d = ScreenContextDenylist.skipEverything
        #expect(d.shouldSkip(bundleID: "com.microsoft.VSCode") == true)
        #expect(d.shouldSkip(bundleID: "com.1password.1password") == true)
        #expect(d.shouldSkip(bundleID: nil) == true)
    }
}

@Suite("ScreenContextDenylist self-exclusion")
struct ScreenContextDenylistSelfExclusionTests {
    /// Reading our own AX tree makes SwiftUI run a view-graph update
    /// inside the synchronous AX call, which deadlocked the app. The
    /// host bundle ID must be denied even though it appears in neither
    /// `builtIn` nor the user's additions.
    ///
    /// The ID is injected rather than read from `Bundle.main`: under
    /// the SwiftPM test runner that is nil, so asserting against it
    /// would pass without exercising the guard at all.
    @Test func skips_the_host_applications_own_bundle_id() {
        let list = ScreenContextDenylist(userAdditions: [], hostBundleID: "com.howl.app")
        #expect(list.shouldSkip(bundleID: "com.howl.app"))
        // Case-insensitively too: the lookup lowercases both sides.
        #expect(list.shouldSkip(bundleID: "COM.HOWL.APP"))
    }

    /// A host with no bundle ID must not poison the list — in
    /// particular it must not insert an empty string that then matches
    /// something it shouldn't.
    @Test func a_nil_host_bundle_id_leaves_the_rest_of_the_list_intact() {
        let list = ScreenContextDenylist(userAdditions: [], hostBundleID: nil)
        #expect(list.shouldSkip(bundleID: "com.1password.1password"))
        #expect(!list.shouldSkip(bundleID: "com.google.Chrome"))
    }

    /// The self-entry must not swallow the rest of the list.
    @Test func still_skips_password_managers_and_still_allows_others() {
        let list = ScreenContextDenylist(userAdditions: [], hostBundleID: "com.howl.app")
        #expect(list.shouldSkip(bundleID: "com.1password.1password"))
        #expect(!list.shouldSkip(bundleID: "com.google.Chrome"))
    }
}
