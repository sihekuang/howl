// mac/Packages/HowlCore/Sources/HowlCore/Storage/DictStats.swift
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

    /// Byte budget for whisper's initial prompt. Mirrors
    /// `transcribe.MaxInitialPromptLen` in
    /// core/internal/transcribe/prompt.go (896 bytes ≈ ~224 tokens;
    /// whisper.cpp keeps only the last ~n_text_ctx/2 prompt tokens). The
    /// Go side joins the dictionary ", " and bounds it to this, so terms
    /// past the cap never reach whisper's recognition. Keep in sync with Go.
    public static let whisperPromptBudgetBytes = 896

    /// How the dictionary fits whisper's initial-prompt budget. Byte-based
    /// (UTF-8) because the Go bound truncates by bytes, not characters.
    public struct WhisperPromptFit: Equatable, Sendable {
        public let usedBytes: Int
        public let budgetBytes: Int
        public let usedTokens: Int
        public let budgetTokens: Int
        public let termsThatFit: Int
        public let totalTerms: Int
        public let overBudget: Bool
    }

    /// Mirror of the Go `DictionaryPrompt` bound: join terms with ", ",
    /// measure UTF-8 bytes, and count how many leading terms fit within
    /// `whisperPromptBudgetBytes`. Go truncates the joined string from the
    /// back, so the leading terms are the ones that reach whisper.
    public static func whisperPromptFit(from terms: [String]) -> WhisperPromptFit {
        let budget = whisperPromptBudgetBytes
        let used = terms.joined(separator: ", ").utf8.count
        let over = used > budget
        var fit = terms.count
        if over {
            var running = 0
            fit = 0
            for (i, term) in terms.enumerated() {
                let add = (i == 0 ? 0 : 2) + term.utf8.count  // ", " before all but first
                if running + add > budget { break }
                running += add
                fit += 1
            }
        }
        return WhisperPromptFit(
            usedBytes: used,
            budgetBytes: budget,
            usedTokens: Int((Double(used) / 4.0).rounded(.up)),
            budgetTokens: budget / 4,
            termsThatFit: fit,
            totalTerms: terms.count,
            overBudget: over
        )
    }
}
