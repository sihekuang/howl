// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Editor/Levenshtein.swift
import Foundation

/// Pure helper for the Compare view's "closest match" badge. Computes
/// the Levenshtein distance between two strings (Unicode-aware via
/// Character iteration). Standard two-row dynamic-programming table.
public enum Levenshtein {
    public static func distance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var prev = Array(0...bChars.count)
        var curr = Array(repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,           // deletion
                    curr[j - 1] + 1,       // insertion
                    prev[j - 1] + cost     // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }
}
