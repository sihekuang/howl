# About / Version Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "About" page to Settings showing the app icon, name, version + build, a Copy button, and links to the GitHub repo and release notes.

**Architecture:** A pure, unit-tested `AppVersion` value in HowlCore formats the version strings and builds the GitHub URLs. A new `AboutTab` SwiftUI view reads the live version from `Bundle.main` and renders it. A new `about` case is added to the existing `SettingsPage` enum and wired into `DetailView.pageBody`. Purely additive — no existing page or behavior changes.

**Tech Stack:** Swift, SwiftUI + AppKit (macOS app target), Swift Testing (`@Test`/`#expect`) for the HowlCore unit tests.

**Spec:** `docs/superpowers/specs/2026-06-16-about-version-page-design.md`

---

## File Structure

- **Create** `mac/Packages/HowlCore/Sources/HowlCore/AppVersion.swift` — pure value type: display string, copy string, repo URL, release-notes URL.
- **Create** `mac/Packages/HowlCore/Tests/HowlCoreTests/AppVersionTests.swift` — Swift Testing unit tests for `AppVersion`.
- **Create** `mac/Howl/UI/Settings/AboutTab.swift` — the About page view.
- **Modify** `mac/Howl/UI/Settings/SettingsView.swift` — add `about` enum case + its `title`/`icon`/`iconColor` arms + the `.about` arm in `DetailView.pageBody`.

All commands below run from the repo root unless stated otherwise. The macOS app build command is `make build` run from `mac/`. The HowlCore tests run with `swift test` from `mac/Packages/HowlCore/`.

---

## Task 1: `AppVersion` value type (HowlCore, TDD)

**Files:**
- Create: `mac/Packages/HowlCore/Tests/HowlCoreTests/AppVersionTests.swift`
- Create: `mac/Packages/HowlCore/Sources/HowlCore/AppVersion.swift`

- [ ] **Step 1: Write the failing test**

Create `mac/Packages/HowlCore/Tests/HowlCoreTests/AppVersionTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `mac/Packages/HowlCore/`): `swift test --filter AppVersion`
Expected: FAIL — compile error, `cannot find 'AppVersion' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `mac/Packages/HowlCore/Sources/HowlCore/AppVersion.swift`:

```swift
import Foundation

/// Read-only view of the running app's version for the Settings "About" page.
/// Pure value type — it does NOT read `Bundle` itself; the view passes in the
/// Info.plist strings — so the formatting and URL logic is unit-testable.
public struct AppVersion: Sendable, Equatable {
    /// Marketing version (CFBundleShortVersionString), e.g. "0.9.1".
    public let short: String
    /// Build number (CFBundleVersion), e.g. "23".
    public let build: String

    /// Empty / missing Info.plist values normalize to "unknown".
    public init(short: String?, build: String?) {
        func clean(_ s: String?) -> String {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? "unknown" : t
        }
        self.short = clean(short)
        self.build = clean(build)
    }

    /// e.g. "Version 0.9.1 (build 23)"; just "Version unknown" when unversioned.
    public var displayString: String {
        short == "unknown" ? "Version unknown" : "Version \(short) (build \(build))"
    }

    /// e.g. "Howl 0.9.1 (build 23) · macOS 15.5" — pasteable into a bug report.
    public var copyString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let patch = v.patchVersion > 0 ? ".\(v.patchVersion)" : ""
        let os = "macOS \(v.majorVersion).\(v.minorVersion)\(patch)"
        return "Howl \(short) (build \(build)) · \(os)"
    }

    /// GitHub repository.
    public var repoURL: URL {
        URL(string: "https://github.com/sihekuang/howl")!
    }

    /// Release notes for this exact version, or the releases index when the
    /// version is unknown (an un-tagged dev build).
    public var releaseNotesURL: URL {
        guard short != "unknown" else {
            return URL(string: "https://github.com/sihekuang/howl/releases")!
        }
        return URL(string: "https://github.com/sihekuang/howl/releases/tag/mac-v\(short)")!
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run (from `mac/Packages/HowlCore/`): `swift test --filter AppVersion`
Expected: PASS — both `displayCopyAndLinks` and `unknownFallback` pass.

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/AppVersion.swift \
        mac/Packages/HowlCore/Tests/HowlCoreTests/AppVersionTests.swift
git commit -m "feat(about): add testable AppVersion value to HowlCore

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `AboutTab` view

**Files:**
- Create: `mac/Howl/UI/Settings/AboutTab.swift`

- [ ] **Step 1: Create the view**

Create `mac/Howl/UI/Settings/AboutTab.swift`:

```swift
import SwiftUI
import AppKit
import HowlCore

/// Settings "About" page: app identity, version, a Copy button (handy for bug
/// reports), and links to the repo / release notes. Reads the live version from
/// the bundle so it never needs manual updates. The page header (icon + "About"
/// title) is drawn by `DetailView`; this is just the centered card below it.
struct AboutTab: View {
    private var version: AppVersion {
        AppVersion(
            short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("Howl")
                .font(.title)
                .fontWeight(.semibold)
            Text(version.displayString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(version.copyString, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .controlSize(.small)

            HStack(spacing: 16) {
                Link("GitHub", destination: version.repoURL)
                Link("Release notes", destination: version.releaseNotesURL)
            }
            .font(.callout)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run (from `mac/`): `make build`
Expected: `** BUILD SUCCEEDED **`. (`AboutTab` is unused until Task 3 — an unused view compiles fine. SourceKit may warn `No such module 'HowlCore'` in-editor; that is pre-existing index noise — trust the `make build` result.)

- [ ] **Step 3: Commit**

```bash
git add mac/Howl/UI/Settings/AboutTab.swift
git commit -m "feat(about): add AboutTab view

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Wire `about` into the Settings sidebar

**Files:**
- Modify: `mac/Howl/UI/Settings/SettingsView.swift` (enum + three `switch` arms + `pageBody`)

No other file switches exhaustively over `SettingsPage` (other references use it only as a navigation-target parameter type), so these four edits are the complete wiring.

- [ ] **Step 1: Add the enum case**

In `mac/Howl/UI/Settings/SettingsView.swift`, add `case about` as the LAST case of `SettingsPage` (so it renders at the bottom of the sidebar):

```swift
    case playground
    case pipeline   // NEW
    case about
```

- [ ] **Step 2: Add the `title` arm**

In the `var title: String` switch, after the `.pipeline` arm:

```swift
        case .pipeline:   return "Pipeline"   // NEW
        case .about:      return "About"
```

- [ ] **Step 3: Add the `icon` arm**

In the `var icon: String` switch, after the `.pipeline` arm:

```swift
        case .pipeline:   return "rectangle.connected.to.line.below"   // NEW
        case .about:      return "info.circle"
```

- [ ] **Step 4: Add the `iconColor` arm**

In the `var iconColor: Color` switch, after the `.pipeline` arm (`.cyan` is unused by other pages):

```swift
        case .pipeline:   return .indigo   // NEW
        case .about:      return .cyan
```

- [ ] **Step 5: Add the `pageBody` arm**

In `DetailView`'s `@ViewBuilder private var pageBody`, after the `.pipeline` arm's closing `)`:

```swift
        case .about:
            AboutTab()
```

- [ ] **Step 6: Build to verify it compiles**

Run (from `mac/`): `make build`
Expected: `** BUILD SUCCEEDED **` with no "switch must be exhaustive" errors.

- [ ] **Step 7: Manual verification**

Run (from `mac/`): `make run`
Then: open Settings (menu bar → Settings, or ⌘,) and confirm:
- An **About** row appears at the bottom of the sidebar with the cyan `info.circle` icon.
- Selecting it shows the app icon, "Howl", and the version line matching `mac/Howl/Info.plist` (currently `Version 0.9.1 (build 23)`).
- **Copy** places `Howl 0.9.1 (build 23) · macOS …` on the clipboard (paste somewhere to confirm).
- **GitHub** opens `https://github.com/sihekuang/howl`; **Release notes** opens `…/releases/tag/mac-v0.9.1`.

- [ ] **Step 8: Commit**

```bash
git add mac/Howl/UI/Settings/SettingsView.swift
git commit -m "feat(about): wire About page into Settings sidebar

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Final verification

- [ ] **Step 1: Run the full HowlCore test suite**

Run (from `mac/Packages/HowlCore/`): `swift test`
Expected: all tests pass (the existing suite plus the new `AppVersion` suite).

- [ ] **Step 2: Build the app once more**

Run (from `mac/`): `make build`
Expected: `** BUILD SUCCEEDED **`.

The branch is now ready for a PR (`feat/about-version-page`).

---

## Notes for the implementer

- **Swift Testing, not XCTest.** Tests use `import Testing`, `@Suite`, `@Test`, `#expect(...)` — match the existing `Tests/HowlCoreTests/*.swift` files. Do not add XCTest.
- **`copyString` is OS-dependent**, so the test asserts a `hasPrefix`, not the full string. Don't tighten it to an exact match.
- **New files are auto-discovered:** xcodegen globs the `Howl/` source tree and SwiftPM globs `Sources/`/`Tests/`, so `make build` / `swift test` pick up the new files with no `project.yml` edit. If the Xcode project looks stale, force a regen with `rm -rf Howl.xcodeproj && make project` (per `mac/CLAUDE.md`).
- **Keep edits additive.** Do not touch other `SettingsPage` arms or existing tabs.
