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
