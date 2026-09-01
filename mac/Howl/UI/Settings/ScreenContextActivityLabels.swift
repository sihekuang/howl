import HowlCore
import SwiftUI

// Display vocabulary shared by the Screen Context list and detail
// panes. Internal rather than private-per-file on purpose: a row that
// reads "Skipped" in the list has to say the same thing when you
// select it, and two private copies is exactly how that drifts apart.

extension ScreenContextActivity.Outcome {
    /// Full sentence-ish label, for the detail pane's header where
    /// there is room to be precise about which denylist gate fired.
    var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .skippedPreReadDenylist: return "Skipped (denylist)"
        case .skippedPostReadDenylist: return "Skipped (denylist, post-read)"
        case .noReadableWindowText: return "No readable text"
        case .cacheHit: return "Cache hit"
        case .extractionSucceeded: return "Extracted"
        case .extractionFailed: return "Extraction failed"
        case .superseded: return "Superseded"
        }
    }

    /// One or two words, for the chip in a ~240pt-wide list row.
    var shortLabel: String {
        switch self {
        case .disabled: return "Off"
        case .skippedPreReadDenylist, .skippedPostReadDenylist: return "Skipped"
        case .noReadableWindowText: return "No text"
        case .cacheHit: return "Cached"
        case .extractionSucceeded: return "Extracted"
        case .extractionFailed: return "Failed"
        case .superseded: return "Superseded"
        }
    }

    /// Chip colour. Deliberately three bands rather than eight
    /// colours: green/blue means the prompt got biased, red/orange
    /// means something a user could act on, and grey means "working as
    /// designed, nothing to see".
    ///
    /// The denylist skips are grey specifically because Howl's own
    /// windows are denylisted — opening Settings puts one at the top
    /// of this list every single time, and a loud colour there would
    /// train people to ignore the colour.
    var tint: Color {
        switch self {
        case .extractionSucceeded: return .green
        case .cacheHit: return .blue
        case .extractionFailed: return .red
        case .noReadableWindowText: return .orange
        case .skippedPreReadDenylist, .skippedPostReadDenylist, .superseded, .disabled:
            return .secondary
        }
    }
}

extension ScreenContextOrigin {
    var shortLabel: String {
        switch self {
        case .screenshot: return "screenshot"
        case .accessibility: return "AX text"
        }
    }
}

extension ScreenContextFallbackReason {
    var shortLabel: String {
        switch self {
        case .noVision: return "no vision"
        case .screenshotUnavailable: return "no screenshot"
        }
    }
}

/// The coloured outcome pill used in `ScreenContextActivityList` rows
/// and the detail header. Text as well as colour — colour alone is not
/// a label.
struct ScreenContextOutcomeChip: View {
    let outcome: ScreenContextActivity.Outcome
    /// Set on a selected (accent-filled) list row, where the chip's
    /// own tint would fight the selection background.
    var onAccentBackground: Bool = false

    var body: some View {
        Text(outcome.shortLabel)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    onAccentBackground
                        ? AnyShapeStyle(Color.white.opacity(0.22))
                        : AnyShapeStyle(outcome.tint.opacity(0.16))
                )
            )
            .foregroundStyle(onAccentBackground ? AnyShapeStyle(Color.white) : AnyShapeStyle(outcome.tint))
    }
}
