import Foundation

/// How long each stage of one screen-context refresh took.
///
/// Every field is optional, and nil means "this stage did not run" —
/// never "it took no time". The distinction is the point: the three
/// strategies run different stages, so a zero would claim a stage
/// happened instantly when it never happened at all.
///
///     OCR     capture + read + extract
///     vision  capture +        extract   (the model reads the pixels)
///     AX                read + extract   (no pixels are ever taken)
///
/// Wall-clock, not CPU time. A stage that is slow because the machine
/// is busy looks identical to one that is slow on its own — which is
/// the right trade for "why did this refresh take nine seconds", and
/// is what the unified log's timestamps already gave us.
public struct ScreenContextTimings: Equatable, Sendable {
    /// Acquiring the pixels — the ScreenCaptureKit screenshot.
    public var capture: TimeInterval?
    /// Turning the window into text: the OCR band passes, or the
    /// Accessibility walk. Not "OCR", because two strategies produce
    /// text and only one of them uses Vision.
    public var read: TimeInterval?
    /// The keyword-extraction round trip to the model.
    public var extract: TimeInterval?
    /// The whole refresh, measured by the coordinator. Deliberately
    /// NOT the sum of the stages above — see `unaccounted`.
    public var total: TimeInterval?

    public init(
        capture: TimeInterval? = nil,
        read: TimeInterval? = nil,
        extract: TimeInterval? = nil,
        total: TimeInterval? = nil
    ) {
        self.capture = capture
        self.read = read
        self.extract = extract
        self.total = total
    }

    /// Nothing was measured at all.
    public var isEmpty: Bool {
        capture == nil && read == nil && extract == nil && total == nil
    }

    /// Time inside the refresh that no stage claims: the debounce, the
    /// hop onto the OCR queue, the cooperative pool being busy, the
    /// cache lookup.
    ///
    /// Worth surfacing rather than hiding, because a refresh that
    /// spends most of its wall-clock here has a very different problem
    /// from one bottlenecked on the model — and the two are
    /// indistinguishable from the total alone. Nil unless the total
    /// and at least one stage are known; clamped at zero, since the
    /// stages and the total are taken from different clocks and a
    /// rounding artefact should not render as negative time.
    public var unaccounted: TimeInterval? {
        guard let total else { return nil }
        let measured = [capture, read, extract].compactMap { $0 }
        guard !measured.isEmpty else { return nil }
        return max(0, total - measured.reduce(0, +))
    }

    /// The receiver with `seconds` ADDED to any extract already
    /// recorded, rather than replacing it.
    ///
    /// One refresh can make two model round trips: a vision model that
    /// answers "I cannot see images" has already cost real time, and
    /// the retry through the text extractor costs more. Overwriting
    /// would silently discard the first, and the discarded time would
    /// resurface as `unaccounted`, blaming the debounce for the
    /// model's latency.
    public func addingExtract(_ seconds: TimeInterval) -> ScreenContextTimings {
        var copy = self
        copy.extract = (copy.extract ?? 0) + seconds
        return copy
    }

    /// The receiver with `other`'s measured stages laid over it.
    ///
    /// A nil in `other` never erases a value already present: stages
    /// are measured in different places — capture and read inside the
    /// source, extract and total in the coordinator — and each knows
    /// only its own.
    public func merging(_ other: ScreenContextTimings) -> ScreenContextTimings {
        ScreenContextTimings(
            capture: other.capture ?? capture,
            read: other.read ?? read,
            extract: other.extract ?? extract,
            total: other.total ?? total
        )
    }
}

/// Measures an async stage on a monotonic clock.
///
/// `ContinuousClock` rather than `Date()`: it does not jump when the
/// system clock is adjusted, and a negative duration rendered in a
/// diagnostic panel is worse than no duration at all.
func measuringDuration<T>(_ body: () async -> T) async -> (value: T, seconds: TimeInterval) {
    let clock = ContinuousClock()
    let start = clock.now
    let value = await body()
    return (value, (clock.now - start).timeInterval)
}

extension Duration {
    /// Seconds as a `TimeInterval`, attoseconds included.
    var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
