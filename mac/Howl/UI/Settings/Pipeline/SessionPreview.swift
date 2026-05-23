// mac/Howl/UI/Settings/Pipeline/SessionPreview.swift
import Foundation

/// Loads the cleaned transcript for a captured session and returns the
/// first N characters so the SessionList row can show a content preview.
/// Returns nil when the file is missing/unreadable — the row should
/// render "(no transcript)" in that case.
enum SessionPreview {
    static func load(in id: String, maxChars: Int = 80) -> String? {
        let url = SessionPaths.file(in: id, rel: "cleaned.txt")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text.count <= maxChars { return text }
        // Unicode-aware truncation: take the first maxChars Characters,
        // append a single-char ellipsis.
        let prefix = String(text.prefix(maxChars))
        return prefix + "…"
    }
}
