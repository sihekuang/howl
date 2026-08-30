import Foundation

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
