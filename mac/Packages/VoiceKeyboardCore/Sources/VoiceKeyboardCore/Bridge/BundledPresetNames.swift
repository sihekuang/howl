// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/BundledPresetNames.swift
import Foundation

extension Preset {
    /// Names of the bundled (built-in, non-deletable) presets shipped
    /// with the engine. Mirrors the names declared in
    /// `core/internal/presets/pipeline-presets.json`.
    ///
    /// The Go core enforces immutability of these names via
    /// `presets.ErrReservedName` — Save/Delete on a bundled name fails
    /// with rc != 0 from the C ABI. This Swift constant is a cosmetic
    /// mirror used by the UI to disable in-place editing and label the
    /// picker rows. If a bundled preset is added or removed in the
    /// JSON, update this set in the same commit.
    public static let bundledNames: Set<String> = [
        "default",
        "minimal",
        "aggressive",
        "paranoid",
    ]

    /// Whether this preset is one of the bundled built-ins (read-only).
    public var isBundled: Bool { Self.bundledNames.contains(name) }
}
