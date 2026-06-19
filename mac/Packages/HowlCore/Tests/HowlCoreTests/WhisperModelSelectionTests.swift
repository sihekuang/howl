import Testing
@testable import HowlCore

@Suite struct WhisperModelSelectionTests {
    @Test func englishOnlyNeedsNoMultilingual() {
        #expect(!WhisperModelSelection.needsMultilingual(primary: "en", secondary: "none"))
        #expect(WhisperModelSelection.effectiveSize(requested: "small", primary: "en", secondary: "none") == "small")
    }

    @Test func secondaryForcesLarge() {
        #expect(WhisperModelSelection.needsMultilingual(primary: "en", secondary: "zh"))
        #expect(WhisperModelSelection.effectiveSize(requested: "small", primary: "en", secondary: "zh") == "large")
    }

    // The latent bug: non-English primary on a small (.en-only) size.
    @Test func nonEnglishPrimaryForcesLarge() {
        #expect(WhisperModelSelection.needsMultilingual(primary: "zh", secondary: "none"))
        #expect(WhisperModelSelection.effectiveSize(requested: "small", primary: "zh", secondary: "none") == "large")
    }

    @Test func autoPrimaryForcesLarge() {
        #expect(WhisperModelSelection.effectiveSize(requested: "small", primary: "auto", secondary: "none") == "large")
    }

    @Test func secondaryEqualToPrimaryCollapsesToNone() {
        #expect(WhisperModelSelection.effectiveSecondary(primary: "en", secondary: "en") == "none")
        #expect(!WhisperModelSelection.needsMultilingual(primary: "en", secondary: "en"))
        #expect(WhisperModelSelection.effectiveSize(requested: "small", primary: "en", secondary: "en") == "small")
    }

    @Test func largeStaysLarge() {
        #expect(WhisperModelSelection.effectiveSize(requested: "large", primary: "en", secondary: "none") == "large")
    }
}
