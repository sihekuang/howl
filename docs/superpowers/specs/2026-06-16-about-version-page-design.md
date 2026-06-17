# About / Version page — design

**Date:** 2026-06-16
**Status:** Approved, pending implementation plan

## Problem

There is no in-app way to see which version of Howl you're running. The
version exists only in `mac/Howl/Info.plist` (`CFBundleShortVersionString`,
`CFBundleVersion`) and on the GitHub release. Users (and bug reports) need a
visible, copyable version somewhere in the app.

## Goal

Add an **About** page to Settings that shows the app icon, name, current
version + build, a Copy button, and links to the repo and release notes.

Non-goals (explicitly out of scope):
- "Check for updates" / auto-update (needs update infrastructure — separate feature).
- Open-source acknowledgements / licenses section.
- Any change to existing Settings pages or behavior.

## Design

Purely additive. Three pieces.

### 1. New `SettingsPage` case — `about`

In `mac/Howl/UI/Settings/SettingsView.swift`, add `case about` to the
`SettingsPage` enum. It is added **last** so it renders at the bottom of the
sidebar (the sidebar order follows `CaseIterable`). Wire up the existing
per-page metadata to match the other cases:

- `title` → `"About"`
- `systemImage` → `"info.circle"`
- accent color → `.cyan` (currently unused by other pages)

Add `.about → AboutTab()` to the detail-view switch that maps the selected
page to its view.

### 2. `AboutTab` view — `mac/Howl/UI/Settings/AboutTab.swift`

A centered vertical stack:

```
        [App Icon]
           Howl
   Version 0.9.1 (build 23)
          [ Copy ]

   GitHub ↗     Release notes ↗
```

- **Icon:** `NSApplication.shared.applicationIconImage`.
- **Name:** static `"Howl"`.
- **Version line:** `AppVersion.displayString` (see §3).
- **Copy button:** writes `AppVersion.copyString` to `NSPasteboard.general`.
- **Links:** SwiftUI `Link`s — GitHub → `AppVersion.repoURL`, Release notes →
  `AppVersion.releaseNotesURL`.

The view reads `CFBundleShortVersionString` and `CFBundleVersion` from
`Bundle.main.infoDictionary` and constructs an `AppVersion`. It holds no other
state and follows the look of the existing `*Tab.swift` views.

### 3. `AppVersion` value — `mac/Packages/HowlCore/Sources/HowlCore/…`

A pure, `Sendable` value type so the formatting/URL logic is unit-tested by
`swift test` (which CI runs). It does **not** read `Bundle` itself — the view
passes the raw strings in, keeping it pure.

```swift
public struct AppVersion: Sendable, Equatable {
    public let short: String   // CFBundleShortVersionString, e.g. "0.9.1"
    public let build: String   // CFBundleVersion, e.g. "23"

    public init(short: String?, build: String?) // nil/empty → "unknown"

    public var displayString: String      // "Version 0.9.1 (build 23)"
    public var copyString: String         // "Howl 0.9.1 (build 23) · macOS <ver>"
    public var repoURL: URL               // https://github.com/sihekuang/howl
    public var releaseNotesURL: URL       // …/releases/tag/mac-v0.9.1
}
```

- `copyString` includes the macOS version
  (`ProcessInfo.processInfo.operatingSystemVersionString`) so it is useful
  pasted directly into a bug report.
- `releaseNotesURL` is built from `short` as `…/releases/tag/mac-v{short}`.
  For a dev build whose tag doesn't exist yet the link 404s; acceptable.
- Missing/empty `short` or `build` render as `"unknown"`; with both unknown,
  `releaseNotesURL` falls back to the repo's `/releases` index.

## Data flow

`Bundle.main.infoDictionary` → `AboutTab` reads the two keys → builds
`AppVersion` → renders `displayString` and wires the buttons/links to
`copyString` / `repoURL` / `releaseNotesURL`. No persistence, no engine
involvement, no settings writes.

## Error handling

The only failure mode is missing Info.plist keys, handled by the `"unknown"`
fallback in `AppVersion`. Copy and links are always safe (static/derived URLs).

## Testing

**Unit (HowlCore, runs in CI):**
- `AppVersion(short: "0.9.1", build: "23")` →
  - `displayString == "Version 0.9.1 (build 23)"`
  - `copyString` begins with `"Howl 0.9.1 (build 23)"`
  - `releaseNotesURL.absoluteString == "https://github.com/sihekuang/howl/releases/tag/mac-v0.9.1"`
- `AppVersion(short: nil, build: nil)` → `displayString == "Version unknown"`,
  `releaseNotesURL` ends in `/releases`.

**Manual:**
- Settings → About shows the icon, "Howl", and the version matching
  `Info.plist`.
- Copy puts the expected string on the clipboard.
- GitHub and Release notes links open the correct pages.

## Files touched

- `mac/Howl/UI/Settings/SettingsView.swift` — add `about` case + wiring.
- `mac/Howl/UI/Settings/AboutTab.swift` — new view.
- `mac/Packages/HowlCore/Sources/HowlCore/AppVersion.swift` — new value type.
- `mac/Packages/HowlCore/Tests/HowlCoreTests/AppVersionTests.swift` — new tests.
