import AppKit
import Foundation

/// Resolves the frontmost app's identity. Injectable so the
/// denylist guarantee below is testable without a live AppKit
/// frontmost app; production uses `defaultFrontmostApp`.
public typealias FrontmostAppLookup = @Sendable @MainActor () -> (bundleID: String, pid: pid_t)?

/// Production frontmost-app lookup.
///
/// `NSWorkspace.frontmostApplication`'s thread affinity is not
/// documented by Apple. AppKit is documented as requiring a run loop
/// and not being daemon-safe; `NSRunningApplication`'s properties are
/// documented as atomic, but that guarantees the returned object's
/// consistency, not which thread may call the accessor. Nothing
/// certifies this is safe off the main thread — and nothing in the
/// Swift 6 checker enforces it either, since NSWorkspace carries no
/// actor-isolation annotation for the compiler to catch a mistake
/// against. A clean `swift build` is not a safety certificate. Hence
/// `@MainActor` here and the hop in `resolveReadableFrontmostApp`; do
/// not remove either as "redundant" without documented evidence.
@MainActor
public func defaultFrontmostApp() -> (bundleID: String, pid: pid_t)? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          let bundleID = app.bundleIdentifier else { return nil }
    return (bundleID, app.processIdentifier)
}

/// Resolves the frontmost app and applies the denylist to it **inside a
/// single main-actor hop**, returning nil if it must not be read.
///
/// The adjacency is the entire point, and it is why this lives here
/// rather than in the coordinator. A caller-side gate cannot make this
/// guarantee: the coordinator checks the denylist, then `await`s the
/// read, and each reader independently resolves frontmost again — so
/// the app that was checked and the app that gets read can differ. That
/// window is not theoretical. It opens on the single most ordinary
/// sequence there is: finish typing in an editor, the 800ms debounce
/// fires precisely because you stopped, and you alt-tab to your
/// password manager while the read is in flight. The AX walk of an
/// Electron vault window then yields under `minimumUsefulChars`, and
/// the composed reader falls through to screenshotting it.
///
/// Resolving the identity and judging it with no suspension point in
/// between closes that: the pid handed back is the pid that was
/// checked, so the app that is read is by construction the app that was
/// cleared. `shouldSkip` is fail-closed on nil and empty bundle IDs, so
/// "we cannot tell what this is" also declines.
///
/// The denylist is snapshotted BEFORE the hop on purpose: building it
/// reads and JSON-decodes user settings, which has no business running
/// on the main thread. Only the `Set` membership test happens inside.
/// A snapshot microseconds old is irrelevant — it changes only when the
/// user edits settings, whereas the frontmost app changes constantly,
/// and it is that pairing which has to be atomic.
func resolveReadableFrontmostApp(
    denylist: @Sendable () -> ScreenContextDenylist,
    lookup: @escaping FrontmostAppLookup
) async -> (bundleID: String, pid: pid_t)? {
    let list = denylist()
    return await MainActor.run {
        guard let app = lookup() else { return nil }
        if list.shouldSkip(bundleID: app.bundleID) { return nil }
        return app
    }
}

/// Text read from the user's focused window, with the identity needed
/// to cache and denylist it.
public struct WindowSnapshot: Equatable, Sendable {
    public let bundleID: String
    public let windowTitle: String
    public let text: String

    public init(bundleID: String, windowTitle: String, text: String) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.text = text
    }
}

/// Reads the text of the frontmost window. Implementations return nil
/// when they cannot read it at all (no permission, no focused window,
/// unsupported app).
public protocol WindowTextReader: Sendable {
    func read() async -> WindowSnapshot?
}

public enum WindowTextReading {
    /// Below this many characters an AX read is treated as unusable and
    /// the OCR fallback runs. Electron, Canvas, and terminal apps
    /// typically expose only a title or nothing at all.
    public static let minimumUsefulChars = 200
}

/// Tries `primary` first and falls back to `fallback` when the primary
/// yields nothing or too little to be useful.
///
/// This ordering is why most users never see a Screen Recording
/// permission prompt: native apps satisfy the AX path, and the
/// screenshot reader is only constructed lazily when AX comes up short.
public struct FallbackWindowTextReader: WindowTextReader {
    private let primary: any WindowTextReader
    private let fallback: any WindowTextReader
    private let minimumChars: Int

    public init(primary: any WindowTextReader,
                fallback: any WindowTextReader,
                minimumChars: Int = WindowTextReading.minimumUsefulChars) {
        self.primary = primary
        self.fallback = fallback
        self.minimumChars = minimumChars
    }

    public func read() async -> WindowSnapshot? {
        let first = await primary.read()
        if let first, first.text.count >= minimumChars {
            return first
        }
        if let second = await fallback.read(), second.text.count >= minimumChars {
            return second
        }
        // Fallback unavailable or no better — a short primary read still
        // beats nothing.
        return first
    }
}
