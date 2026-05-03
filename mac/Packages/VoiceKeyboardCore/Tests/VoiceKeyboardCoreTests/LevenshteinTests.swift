import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("Levenshtein")
struct LevenshteinTests {
    @Test func identicalStrings_zero() {
        #expect(Levenshtein.distance("hello", "hello") == 0)
    }
    @Test func emptyVsNonEmpty_lengthOfOther() {
        #expect(Levenshtein.distance("", "abc") == 3)
        #expect(Levenshtein.distance("abc", "") == 3)
    }
    @Test func singleSubstitution_one() {
        #expect(Levenshtein.distance("cat", "bat") == 1)
    }
    @Test func insertion_one() {
        #expect(Levenshtein.distance("car", "cars") == 1)
    }
    @Test func unrelatedStrings_kittenSitting() {
        #expect(Levenshtein.distance("kitten", "sitting") == 3)
    }
    @Test func unicode_handled() {
        #expect(Levenshtein.distance("café", "cafe") == 1)
    }
}
