// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Storage/DictStats.swift
import Foundation

/// Token/word counts for the custom-dictionary cleanup-prompt
/// substitution. Mirrors the Go side's `strings.Join(terms, ", ")` so
/// the chars and rough-token count match what the LLM actually sees.
///
/// Token estimate is char-count / 4 rounded up — biased a touch
/// conservative (overcount > undercount). The cleanup prompt template
/// itself adds another ~60 tokens regardless of the dictionary.
public enum DictStats {
    public struct Snapshot: Equatable, Sendable {
        public let words: Int
        public let chars: Int
        public let tokens: Int
    }

    public static func compute(from terms: [String]) -> Snapshot {
        guard !terms.isEmpty else { return .init(words: 0, chars: 0, tokens: 0) }
        let payload = terms.joined(separator: ", ")
        let chars = payload.count
        let tokens = Int((Double(chars) / 4.0).rounded(.up))
        return .init(words: terms.count, chars: chars, tokens: tokens)
    }
}
