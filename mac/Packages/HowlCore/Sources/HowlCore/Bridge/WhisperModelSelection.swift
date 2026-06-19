import Foundation

/// Pure model-selection logic shared by the app's `ModelPaths` and tested in
/// HowlCore. Code-switch / non-English dictation needs whisper's multilingual
/// weights; the bundled tiny/base/small/medium are English-only `.en` builds,
/// so any multilingual need forces the large multilingual model
/// (`ggml-large-v3.bin`).
public enum WhisperModelSelection {
    /// Sentinel meaning "no secondary language".
    public static let noSecondary = "none"

    /// Collapses the degenerate `secondary == primary` case to "none" — a
    /// language can't be its own secondary.
    public static func effectiveSecondary(primary: String, secondary: String) -> String {
        secondary == primary ? noSecondary : secondary
    }

    /// True when the configuration needs multilingual weights: a non-English
    /// primary (including "auto"), or any secondary language set.
    public static func needsMultilingual(primary: String, secondary: String) -> Bool {
        if primary != "en" { return true }
        return effectiveSecondary(primary: primary, secondary: secondary) != noSecondary
    }

    /// The model size to actually load. Forces "large" (the only multilingual
    /// build Howl ships) when multilingual weights are needed; otherwise the
    /// user's requested size is honored.
    public static func effectiveSize(requested: String, primary: String, secondary: String) -> String {
        needsMultilingual(primary: primary, secondary: secondary) ? "large" : requested
    }
}
