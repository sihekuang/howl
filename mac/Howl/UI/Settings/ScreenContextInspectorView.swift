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
/// count is ever recorded, so this panel can report that a capture
/// happened and how big it was, but can never show the picture back.
/// See `ScreenContextActivity.capturedImageBytes`.
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
        // size. The image itself is deliberately never retained, so a
        // byte count is all there is to show, and all there should be.
        if let bytes = activity.capturedImageBytes {
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "\(app) · \(ScreenContextSource.screenshot.shortLabel) · \(size)"
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
            return "No screenshot and no readable window text"
        case .superseded:
            return "Superseded before it finished"
        case .cacheHit, .extractionSucceeded, .extractionFailed:
            return "—"
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
                    Text(activity.outcome.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
