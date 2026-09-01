import HowlCore
import SwiftUI

/// The screen-context diagnostic inspector: the most recent activity's
/// captured → LLM → sanitized chain, then the deduped → token-trimmed
/// → whisper chain from the engine's live preview, then a compact
/// recent-activity list.
///
/// Rendered inside `ScreenContextSection`, under the toggle and
/// denylist, and follows that file's own idiom: plain `HStack`/`Text`
/// rows and `SettingsGroupHeader`, never `Section` or `LabeledContent`
/// — `SettingsPane` is a plain `VStack`, not a `Form`/`List`, so those
/// don't render here (see `ScreenContextSection`'s header comment).
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
/// Every read path is reachable in normal operation — a screenshot read
/// locally by OCR (the default), a screenshot sent to a vision model,
/// or accessibility text when there are no pixels at all — so every row
/// that describes a capture names which one it was, and the Captured
/// row spells out why a fallback happened. "This model can't read
/// images" and "the screenshot failed" are the two reasons, and they
/// call for opposite fixes.
///
/// A `.screenshot` row with a character count was read by OCR; one with
/// a byte count was sent to a vision model. Which strategy is installed
/// is `CompositionRoot`'s business, not this view's.
struct ScreenContextInspectorView: View {
    let engine: any CoreEngine
    var activityStore: ScreenContextActivityStore

    @State private var preview: ScreenContextPreview?
    @State private var showCapturedText = false
    @State private var showRawResponse = false
    @State private var showFullPrompt = false

    private var latest: ScreenContextActivity? { activityStore.recentFirst.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsGroupHeader("Activity")
            if let latest {
                capturedRow(latest)
                llmReturnedRow(latest)
                sanitizedRow(latest)
                if let preview {
                    dedupedRow(preview)
                    tokenTrimRow(preview)
                    whisperRow(preview)
                } else {
                    Text("Whisper prompt preview unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No screen-context activity yet — focus a window to see it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if activityStore.entries.count > 1 {
                Divider().padding(.vertical, 4)
                SettingsGroupHeader("Recent activity")
                recentActivityList
            }
        }
        // Re-fetches whenever new activity lands — the preview reflects
        // live engine state (current dictionary + stored screen
        // keywords), which a new refresh may just have changed.
        .task(id: activityStore.entries.count) {
            preview = await engine.screenContextPreview()
        }
    }

    // MARK: - Row 1: Captured

    @ViewBuilder
    private func capturedRow(_ activity: ScreenContextActivity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                rowLabel("Captured")
                VStack(alignment: .leading, spacing: 2) {
                    Text(capturedSummary(activity)).font(.callout)
                    if let note = fallbackNote(activity) {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let note = truncationNote(activity) {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
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
                activity.source?.shortLabel ?? ScreenContextSource.screenshot.shortLabel,
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
        HStack {
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

    // MARK: - Row 4: Deduped (from the live preview)

    @ViewBuilder
    private func dedupedRow(_ preview: ScreenContextPreview) -> some View {
        HStack {
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
        HStack {
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

    // MARK: - Recent activity list

    private var recentActivityList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(activityStore.recentFirst.prefix(20)) { activity in
                HStack {
                    Text(activity.timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption.monospaced())
                        .frame(width: 70, alignment: .leading)
                    Text(activity.bundleID ?? "—")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(recentLabel(activity))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Outcome plus, when the refresh fell back, why — so the list
    /// distinguishes "AX found nothing" from "there was no screenshot
    /// AND AX found nothing" at a glance.
    private func recentLabel(_ activity: ScreenContextActivity) -> String {
        guard let reason = activity.fallbackReason else { return activity.outcome.label }
        return "\(activity.outcome.label) · \(reason.shortLabel)"
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

private extension ScreenContextActivity.Outcome {
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
}

private extension ScreenContextSource {
    var shortLabel: String {
        switch self {
        case .screenshot: return "screenshot"
        case .accessibility: return "AX text"
        }
    }
}

private extension ScreenContextFallbackReason {
    var shortLabel: String {
        switch self {
        case .noVision: return "no vision"
        case .screenshotUnavailable: return "no screenshot"
        }
    }
}
