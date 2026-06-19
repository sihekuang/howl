import Foundation
import Testing
@testable import HowlCore

@Suite("OccupationPacks")
struct OccupationPacksTests {

    // Each pack must stay within half the whisper prompt budget, so a
    // single pack fits comfortably AND any two packs still fit 896 bytes.
    @Test func every_pack_fits_half_the_whisper_budget() {
        let cap = DictStats.whisperPromptBudgetBytes / 2   // 448
        for pack in OccupationPacks.all {
            let bytes = pack.terms.joined(separator: ", ").utf8.count
            #expect(bytes <= cap, "pack '\(pack.id)' is \(bytes) bytes, over the \(cap)-byte cap")
        }
    }

    @Test func pack_ids_are_unique() {
        let ids = OccupationPacks.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func no_pack_is_empty() {
        for pack in OccupationPacks.all {
            #expect(!pack.terms.isEmpty, "pack '\(pack.id)' has no terms")
        }
    }
}
