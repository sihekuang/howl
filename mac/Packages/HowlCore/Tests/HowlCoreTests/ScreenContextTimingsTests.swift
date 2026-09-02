import Foundation
import Testing
@testable import HowlCore

/// The arithmetic behind the timing panel.
///
/// The distinction these pin down is nil-versus-zero: the three
/// strategies run different stages, so a stage that never ran must not
/// render as one that ran instantly.
@Suite("Screen context timings")
struct ScreenContextTimingsTests {
    @Test("a stage that did not run stays nil rather than becoming zero")
    func absentStagesAreNil() {
        let ax = ScreenContextTimings(read: 0.4, extract: 1.2)
        #expect(ax.capture == nil)
        #expect(ax.read == 0.4)
    }

    @Test("merging lays new stages over old without erasing them")
    func mergingKeepsWhatTheOtherDoesNotMeasure() {
        let fromSource = ScreenContextTimings(capture: 0.2, read: 0.5)
        let fromCoordinator = ScreenContextTimings(extract: 2.0, total: 3.0)
        let merged = fromSource.merging(fromCoordinator)
        #expect(merged.capture == 0.2)
        #expect(merged.read == 0.5)
        #expect(merged.extract == 2.0)
        #expect(merged.total == 3.0)
    }

    @Test("a nil in the overlay never erases a measured stage")
    func mergingDoesNotErase() {
        let measured = ScreenContextTimings(capture: 0.2, read: 0.5)
        let merged = measured.merging(ScreenContextTimings(total: 1.0))
        #expect(merged.capture == 0.2)
        #expect(merged.read == 0.5)
    }

    @Test("two model round trips in one refresh add up instead of overwriting")
    func extractAccumulates() {
        // The vision path: a no-vision probe costs real time, then the
        // retry through the text extractor costs more. Overwriting
        // would discard the probe, and the discarded time would
        // resurface as `unaccounted`, blaming the debounce for it.
        let afterProbe = ScreenContextTimings(capture: 0.3).addingExtract(1.5)
        let afterRetry = afterProbe.addingExtract(2.0)
        #expect(afterRetry.extract == 3.5)
        #expect(afterRetry.capture == 0.3)
    }

    @Test("the first extract on an unmeasured refresh is just itself")
    func firstExtractIsNotOffset() {
        #expect(ScreenContextTimings().addingExtract(1.5).extract == 1.5)
    }

    @Test("unaccounted time is the total the stages do not explain")
    func unaccountedIsTheRemainder() {
        let t = ScreenContextTimings(capture: 0.2, read: 0.5, extract: 2.0, total: 3.0)
        // Tolerance, not equality: 3.0 - (0.2 + 0.5 + 2.0) lands on
        // 0.2999999999999998 in binary floating point.
        #expect(abs((t.unaccounted ?? -1) - 0.3) < 0.0001)
    }

    @Test("unaccounted never renders as negative time")
    func unaccountedClampsAtZero() {
        // Stages and the total come off different clock reads, so a
        // rounding artefact can put the sum a hair over the total.
        let t = ScreenContextTimings(capture: 1.0, read: 1.0, extract: 1.0, total: 2.999)
        #expect(t.unaccounted == 0)
    }

    @Test("unaccounted is unknown, not zero, when nothing was measured")
    func unaccountedNeedsBothSides() {
        #expect(ScreenContextTimings(total: 3.0).unaccounted == nil)
        #expect(ScreenContextTimings(capture: 0.2).unaccounted == nil)
    }

    @Test("an unmeasured refresh reports empty")
    func emptyIsEmpty() {
        #expect(ScreenContextTimings().isEmpty)
        #expect(!ScreenContextTimings(total: 0.1).isEmpty)
    }
}
