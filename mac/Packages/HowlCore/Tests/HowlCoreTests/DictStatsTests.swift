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
}
