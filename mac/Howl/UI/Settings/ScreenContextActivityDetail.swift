import HowlCore
import SwiftUI

/// Right column of the Screen Context tab: the full diagnostic chain
/// for ONE selected `ScreenContextActivity`.
///
/// Mirrors `Pipeline/SessionDetail.swift` — a plain
/// `VStack(alignment: .leading)` of labelled rows for whatever the
/// list has selected, owning no selection state of its own.
///
/// Rendered inside `SettingsPane`, and follows that container's idiom:
/// plain `HStack`/`Text` rows and `SettingsGroupHeader`, never
/// `Section` or `LabeledContent` — `SettingsPane` is a `VStack`, not a
/// `Form`/`List`, so those don't render here.
///
/// ## The two halves are not the same kind of fact
///
/// Rows 1-3 (Captured, LLM returned, Sanitized) are properties of the
/// selected record: they describe what happened when that window was
/// read, and they are as true a week later as they were at the time.
///
/// Rows 4-6 (Deduped, Token trim, → Whisper) come from
/// `engine.screenContextPreview()`, which is **live engine state** —
/// the prompt whisper would receive if you dictated right now, rebuilt
/// by every refresh from the current dictionary and whatever keywords
/// the LAST refresh stored. They were never a property of any single
/// activity; the old single-entry layout just never had to admit it,
/// because the only entry it could show was the newest one.
///
/// So they are presented as their own group, under their own heading,
/// explicitly labelled as the engine's current state rather than part
/// of the record above — and when the selection is not the newest
/// entry, the heading says so outright. Showing them silently under a
/// historical selection would be a straightforward lie, and a
/// consequential one: a denylist skip applies an EMPTY keyword set, so
/// the moment Settings comes to the front, the live prompt loses every
/// screen keyword the entry you are reading actually produced.
///
/// ## Privacy
///
/// Raw window text and the LLM's raw response are shown verbatim
/// behind disclosures, by design — this is a diagnostic surface the
/// user explicitly asked to see the truth on, and everything it shows
/// is already in-memory-only (`ScreenContextActivityStore`), never
/// written to disk.
///
/// The captured SCREENSHOT is the deliberate exception: only its byte
/// count and pixel dimensions are ever recorded, so this panel can
/// report that a capture happened, how big it was and what resolution
/// the model saw, but can never show the picture back. See
/// `ScreenContextActivity.capturedImageBytes`.
///
/// Every read path is reachable in normal operation — a screenshot
/// read locally by OCR (the default), a screenshot sent to a vision
/// model, or accessibility text when there are no pixels at all — so
/// every row that describes a capture names which one it was, and the
/// Captured row spells out why a fallback happened. "This model can't
/// read images" and "the screenshot failed" are the two reasons, and
/// they call for opposite fixes.
///
/// A `.screenshot` row with a character count was read by OCR; one
/// with a byte count was sent to a vision model. Which strategy is
/// installed is `CompositionRoot`'s business, not this view's.
struct ScreenContextActivityDetail: View {
    let activity: ScreenContextActivity
    /// Live engine state, refetched by the parent whenever new
    /// activity lands. Nil when the preview could not be decoded.
    let preview: ScreenContextPreview?
    /// Whether `activity` is the newest entry in the list. Drives the
    /// "this is not what that entry produced" warning on the live
    /// group — see the type comment.
    let isNewest: Bool
    /// Whether there is anything older than `activity` to select.
    /// Only used to decide whether the self-skip note can honestly
    /// point at "the entry below this one".
    let hasOlderEntries: Bool

    @State private var showCapturedText = false
    @State private var showRawResponse = false
    @State private var showFullPrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isSelfSkip { selfSkipNote }
            SettingsGroupHeader("This capture")
            capturedRow(activity)
            llmReturnedRow(activity)
            sanitizedRow(activity)
            Divider().padding(.vertical, 4)
            liveEngineGroup
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.bundleID ?? "Unknown app")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                // Same clock as the list's rows, for the same reason
                // — see `ScreenContextActivityList`. The pane can sit
                // on one selection for minutes.
                TimelineView(.periodic(from: .now, by: RelativeTime.subMinuteBucket)) { context in
                    Text(timestampLabel(now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ScreenContextOutcomeChip(outcome: activity.outcome)
        }
    }

    /// Relative time for scanning plus the wall clock for correlating
    /// against a dictation — the list rows only carry the relative
    /// half, and several refreshes can share one "just now".
    private func timestampLabel(now: Date) -> String {
        let relative = RelativeTime.string(now: now, then: activity.timestamp, granularity: .seconds)
        let exact = activity.timestamp.formatted(.dateTime.hour().minute().second())
        return "\(relative) · \(exact) · \(activity.outcome.label)"
    }

    // MARK: - Howl's own skip

    /// Howl denylists its own bundle ID (see `ScreenContextDenylist` —
    /// reading our own AX tree self-deadlocks the app), so bringing
    /// this window to the front to inspect screen context necessarily
    /// files a skip, and that skip is necessarily the newest entry in
    /// the list. Without saying so, the very act of opening Settings
    /// looks like a bug in the feature, and the reading the user came
    /// to see looks like it never happened.
    private var isSelfSkip: Bool {
        switch activity.outcome {
        case .skippedPreReadDenylist, .skippedPostReadDenylist:
            guard let own = Bundle.main.bundleIdentifier?.lowercased(), !own.isEmpty,
                  let seen = activity.bundleID?.lowercased() else { return false }
            return own == seen
        default:
            return false
        }
    }

    @ViewBuilder
    private var selfSkipNote: some View {
        Label(
            hasOlderEntries
                ? "This is Howl skipping its own window. Opening Settings puts Howl in front, "
                    + "so one of these lands on top every time — the reading you came to look at "
                    + "is the entry below it."
                : "This is Howl skipping its own window. Opening Settings puts Howl in front, so "
                    + "one of these lands on top every time. Focus another window to capture a real "
                    + "reading.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Row 1: Captured

    @ViewBuilder
    private func capturedRow(_ activity: ScreenContextActivity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                rowLabel("Captured")
                VStack(alignment: .leading, spacing: 2) {
                    Text(capturedSummary(activity)).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = fallbackNote(activity) {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = truncationNote(activity) {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if activity.capturedText != nil {
                    Button(showCapturedText ? "Hide text" : "Show text") {
                        showCapturedText.toggle()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            if showCapturedText, let text = activity.capturedText {
                disclosedText(text)
            }
        }
    }

    private func capturedSummary(_ activity: ScreenContextActivity) -> String {
        let app = activity.bundleID ?? "unknown app"
        // The screenshot path has no text to measure — only a payload
        // size and the dimensions it was encoded at. The image itself is
        // deliberately never retained, so those two numbers are all
        // there is to show, and all there should be.
        if let bytes = activity.capturedImageBytes {
            var parts = [
                app,
                activity.source?.shortLabel ?? ScreenContextOrigin.screenshot.shortLabel,
                ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            ]
            if let pixels = activity.capturedImagePixelSize {
                parts.append("\(pixels.width)×\(pixels.height)")
            }
            return parts.joined(separator: " · ")
        }
        guard activity.capturedText != nil, let length = activity.capturedTextLength else {
            return unavailableCapturedReason(activity)
        }
        let sourceLabel = activity.source?.shortLabel ?? "?"
        return "\(app) · \(sourceLabel) · \(length.formatted()) chars"
    }

    private func unavailableCapturedReason(_ activity: ScreenContextActivity) -> String {
        switch activity.outcome {
        case .disabled:
            return "Screen context is off"
        case .skippedPreReadDenylist, .skippedPostReadDenylist:
            return "Skipped — \(activity.bundleID ?? "this app") is on the never-read list"
        case .noReadableWindowText:
            // Exactly one fact: the accessibility read came up empty.
            // WHY the screenshot path wasn't used instead is the
            // fallback note's job, and the two are different problems.
            return "No readable window text"
        case .superseded:
            return "Superseded before it finished"
        case .cacheHit, .extractionSucceeded, .extractionFailed:
            return "—"
        }
    }

    /// Why this refresh used accessibility text rather than a
    /// screenshot. Nil on the primary path, where there is nothing to
    /// explain.
    ///
    /// This is the row that answers "why are my keywords worse than I
    /// expected" for the two states that are otherwise invisible: a
    /// model that cannot see, and a screenshot that never happened.
    /// They look identical in the keyword list and have opposite fixes.
    private func fallbackNote(_ activity: ScreenContextActivity) -> String? {
        switch activity.fallbackReason {
        case .noVision:
            return "This model can't read images, so Howl used accessibility text instead. "
                + "Switch to a vision model to use screenshots."
        case .screenshotUnavailable:
            return "No screenshot was available, so Howl used accessibility text instead. "
                + "If this is every window, check Screen Recording in System Settings › Privacy & Security."
        case nil:
            return nil
        }
    }

    private func truncationNote(_ activity: ScreenContextActivity) -> String? {
        guard let text = activity.capturedText,
              text.utf8.count > ScreenContextLimits.maxWindowTextBytesForExtraction else { return nil }
        return "Truncated to \(ScreenContextLimits.maxWindowTextBytesForExtraction.formatted()) bytes before the LLM saw it"
    }

    // MARK: - Row 2: LLM returned

    @ViewBuilder
    private func llmReturnedRow(_ activity: ScreenContextActivity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                rowLabel("LLM returned")
                Text(llmReturnedSummary(activity)).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if activity.rawResponse != nil {
                    Button(showRawResponse ? "Hide raw" : "Show raw") {
                        showRawResponse.toggle()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            if showRawResponse, let raw = activity.rawResponse {
                disclosedText(raw.isEmpty ? "(empty response)" : raw)
            }
        }
    }

    private func llmReturnedSummary(_ activity: ScreenContextActivity) -> String {
        switch activity.outcome {
        case .extractionSucceeded:
            let total = activity.appliedKeywords.count + activity.dropped.count
            return "\(total) term\(total == 1 ? "" : "s")"
        case .extractionFailed:
            return "Extraction failed — provider unreachable, rate-limited, or timed out"
        case .cacheHit:
            return "Reused from an earlier read — no LLM call this time"
        default:
            return "—"
        }
    }

    // MARK: - Row 3: Sanitized

    @ViewBuilder
    private func sanitizedRow(_ activity: ScreenContextActivity) -> some View {
        HStack(alignment: .top) {
            rowLabel("Sanitized")
            Text(sanitizedSummary(activity)).font(.callout)
            Spacer()
        }
    }

    private func sanitizedSummary(_ activity: ScreenContextActivity) -> String {
        guard activity.outcome == .extractionSucceeded else { return "—" }
        let kept = activity.appliedKeywords.count
        let droppedCount = activity.dropped.count
        guard droppedCount > 0 else { return "\(kept) kept" }
        let reasons = orderedUniqueReasons(activity.dropped.map(\.reason))
            .map(friendlyDropReason)
            .joined(separator: ", ")
        return "\(kept) kept · \(droppedCount) dropped (\(reasons))"
    }

    // MARK: - Rows 4-6: live engine state

    /// The half of the chain that is NOT a property of the selected
    /// record. See the type comment for why this is fenced off rather
    /// than continuing the row list above.
    @ViewBuilder
    private var liveEngineGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SettingsGroupHeader("Whisper prompt right now")
                Text("LIVE")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
            }
            Text(liveCaption)
                .font(.caption)
                .foregroundStyle(isNewest ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.orange))
                // Without this the split view hands the column an
                // ideal height of one line and SwiftUI truncates the
                // sentence rather than wrapping it — which would clip
                // exactly the clause that says these numbers are live.
                .fixedSize(horizontal: false, vertical: true)
            if let preview {
                dedupedRow(preview)
                tokenTrimRow(preview)
                whisperRow(preview)
            } else {
                Text("Whisper prompt preview unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var liveCaption: String {
        if isNewest {
            return "What the engine would send Whisper if you dictated now. Rebuilt on every "
                + "refresh from the current dictionary plus the last stored screen keywords — "
                + "not a stored part of the entry above."
        }
        return "These numbers are the engine's, not this entry's. Later refreshes have rebuilt "
            + "the prompt since this capture — including denylist skips, which apply an empty "
            + "keyword set — so it may share nothing with what this read produced."
    }

    // MARK: - Row 4: Deduped (from the live preview)

    @ViewBuilder
    private func dedupedRow(_ preview: ScreenContextPreview) -> some View {
        HStack(alignment: .top) {
            rowLabel("Deduped")
            Text(dedupedSummary(preview)).font(.callout)
            Spacer()
        }
    }

    private func dedupedSummary(_ preview: ScreenContextPreview) -> String {
        let dictDupes = preview.dropped.filter { $0.source == "screen" && $0.stage == "duplicate_of_dictionary" }.count
        let selfDupes = preview.dropped.filter { $0.source == "screen" && $0.stage == "duplicate" }.count
        let kept = max(preview.screenKeywords.count - dictDupes - selfDupes, 0)
        var parts: [String] = []
        if dictDupes > 0 { parts.append("\(dictDupes) already in dictionary") }
        if selfDupes > 0 { parts.append("\(selfDupes) repeated") }
        guard !parts.isEmpty else { return "\(kept) kept" }
        return "\(kept) kept · " + parts.joined(separator: " · ")
    }

    // MARK: - Row 5: Token trim (from the live preview)

    @ViewBuilder
    private func tokenTrimRow(_ preview: ScreenContextPreview) -> some View {
        HStack(alignment: .top) {
            rowLabel("Token trim")
            Text(tokenTrimSummary(preview)).font(.callout)
            Spacer()
        }
    }

    private func tokenTrimSummary(_ preview: ScreenContextPreview) -> String {
        let capStages: Set<String> = ["byte_prefilter", "screen_token_cap"]
        let droppedCount = preview.dropped.filter { $0.source == "screen" && capStages.contains($0.stage) }.count
        return "\(preview.screenApplied.count) kept · \(droppedCount) dropped · cap \(preview.maxScreenPromptTokens) tokens"
    }

    // MARK: - Row 6: → Whisper (from the live preview)

    @ViewBuilder
    private func whisperRow(_ preview: ScreenContextPreview) -> some View {
        HStack(alignment: .top) {
            rowLabel("→ Whisper")
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.prompt.isEmpty ? "(no prompt)" : preview.prompt)
                    .font(.callout.monospaced())
                    .lineLimit(showFullPrompt ? nil : 2)
                    .textSelection(.enabled)
                if preview.prompt.count > 160 {
                    Button(showFullPrompt ? "Show less" : "Show full prompt") {
                        showFullPrompt.toggle()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            Spacer()
            Text("\(preview.tokenCount)/\(preview.maxPromptTokens) tokens")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Shared row chrome

    private func rowLabel(_ s: String) -> some View {
        Text(s)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 96, alignment: .leading)
    }

    @ViewBuilder
    private func disclosedText(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
        .padding(6)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func orderedUniqueReasons(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for r in reasons where seen.insert(r).inserted { out.append(r) }
        return out
    }

    private func friendlyDropReason(_ reason: String) -> String {
        switch reason {
        case "empty": return "empty"
        case "too_long": return "oversize"
        case "numeric": return "numeric"
        case "duplicate": return "duplicate"
        case "keyword_cap": return "over cap"
        default: return reason
        }
    }
}
