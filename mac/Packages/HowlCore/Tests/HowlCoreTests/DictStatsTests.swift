import Foundation
import Testing
@testable import HowlCore

@Suite("DictStats")
struct DictStatsTests {

    @Test func empty_dict_is_zero() {
        let s = DictStats.compute(from: [])
        #expect(s.words == 0)
        #expect(s.chars == 0)
        #expect(s.tokens == 0)
    }

    @Test func single_term_counts_as_one_word() {
        let s = DictStats.compute(from: ["MCP"])
        #expect(s.words == 1)
        #expect(s.chars == 3)             // "MCP"
        #expect(s.tokens == 1)            // ceil(3/4)
    }

    @Test func multiple_terms_joined_with_comma_space() {
        // payload = "MCP, WebRTC" -> 11 chars -> ceil(11/4) = 3 tokens
        let s = DictStats.compute(from: ["MCP", "WebRTC"])
        #expect(s.words == 2)
        #expect(s.chars == 11)
        #expect(s.tokens == 3)
    }

    @Test func whisperFit_empty_is_not_over_budget() {
        let f = DictStats.whisperPromptFit(from: [])
        #expect(f.usedBytes == 0)
        #expect(f.budgetBytes == 896)
        #expect(f.budgetTokens == 224)
        #expect(f.totalTerms == 0)
        #expect(f.termsThatFit == 0)
        #expect(f.overBudget == false)
    }

    @Test func whisperFit_small_dict_all_fit() {
        // "MCP, WebRTC" = 11 bytes
        let f = DictStats.whisperPromptFit(from: ["MCP", "WebRTC"])
        #expect(f.usedBytes == 11)
        #expect(f.usedTokens == 3)        // ceil(11/4)
        #expect(f.termsThatFit == 2)
        #expect(f.totalTerms == 2)
        #expect(f.overBudget == false)
    }

    @Test func whisperFit_large_dict_truncates_leading_terms() {
        // 50 × 20-byte term. Joined length of first k terms = 22k - 2.
        // 22*50 - 2 = 1098 > 896 -> over. Largest k with 22k-2 <= 896 is 40 (878).
        let terms = Array(repeating: "supercalifragilistic", count: 50)
        let f = DictStats.whisperPromptFit(from: terms)
        #expect(f.overBudget == true)
        #expect(f.totalTerms == 50)
        #expect(f.termsThatFit == 40)
    }

    @Test func whisperFit_boundary_exactly_at_budget_fits() {
        let f = DictStats.whisperPromptFit(from: [String(repeating: "a", count: 896)])
        #expect(f.usedBytes == 896)
        #expect(f.overBudget == false)
        #expect(f.termsThatFit == 1)
    }

    @Test func whisperFit_boundary_one_over_does_not_fit() {
        let f = DictStats.whisperPromptFit(from: [String(repeating: "a", count: 897)])
        #expect(f.usedBytes == 897)
        #expect(f.overBudget == true)
        #expect(f.termsThatFit == 0)
    }

    @Test func whisperFit_uses_utf8_byte_length() {
        // "世界" = 2 characters but 6 UTF-8 bytes.
        let f = DictStats.whisperPromptFit(from: ["世界"])
        #expect(f.usedBytes == 6)
        #expect(f.overBudget == false)
    }
}
