import HowlCore
import SwiftUI

/// Left column of the Screen Context tab: one row per
/// `ScreenContextActivity`, newest first.
///
/// Mirrors `Pipeline/SessionList.swift` — same three-line row (bold
/// relative time + trailing marker, monospaced identity, tertiary
/// summary), same externally-bound selection, same accent-filled
/// selected state — so the two master/detail pages in Settings read as
/// one idiom rather than two.
///
/// Unlike `SessionList` this view owns no data and does no loading:
/// `ScreenContextActivityStore` is an in-memory `@Observable` ring
/// buffer that the coordinator pushes into, so there is nothing to
/// refresh and no failure to report. Hence no header refresh button
/// and no footer.
struct ScreenContextActivityList: View {
    let activities: [ScreenContextActivity]
    @Binding var selectedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ACTIVITY").font(.caption2).bold().foregroundStyle(.secondary)
            Text("\(activities.count) recent")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if activities.isEmpty {
            Text("No screen-context activity yet — focus another window to see it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                // The relative labels have to AGE while this pane sits
                // open. A row's body is only re-evaluated when its own
                // data changes, so a row drawn at t=0 keeps saying
                // "just now" forever however many newer entries pile
                // up above it — which is exactly what a screen-context
                // list does, since it only ever grows at the top.
                //
                // Each row is aged from its own `activity.timestamp`
                // against `context.date`, never from an elapsed offset
                // captured when the row first appeared.
                //
                // Ticking at `RelativeTime.subMinuteBucket` (5s) is
                // deliberate on both sides: slower and a label sits
                // visibly stale, faster and every extra tick recomputes
                // a string identical to the last one. It is 12 text
                // relayouts a minute, and only while this settings page
                // is on screen — the page is switched in structurally,
                // and SwiftUI suspends timeline schedules for views
                // that aren't visible.
                TimelineView(.periodic(from: .now, by: RelativeTime.subMinuteBucket)) { context in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(activities) { activity in
                            ScreenContextActivityRow(
                                activity: activity,
                                now: context.date,
                                isSelected: selectedID == activity.id,
                                onTap: { selectedID = activity.id }
                            )
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

/// One row. Selection is the parent's business; this only renders.
private struct ScreenContextActivityRow: View {
    let activity: ScreenContextActivity
    /// Current time, supplied by the list's `TimelineView` so the
    /// label ages. Never `Date()` read inside the row — that is the
    /// version of this that freezes at first render.
    let now: Date
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(RelativeTime.string(now: now, then: activity.timestamp, granularity: .seconds))
                    .font(.caption.bold())
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
                Spacer()
                ScreenContextOutcomeChip(outcome: activity.outcome, onAccentBackground: isSelected)
            }
            Text(activity.bundleID ?? "—")
                .font(.caption2.monospaced())
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .lineLimit(1)
                .truncationMode(.head)
            Text(summary)
                .font(.caption2)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    /// Applied-keyword count — the one number that says whether this
    /// refresh actually biased anything — plus the fallback reason
    /// when there was one, so "AX found nothing" and "there was no
    /// screenshot AND AX found nothing" stay distinguishable at a
    /// glance, as they were in the old flat recent-activity list.
    private var summary: String {
        let n = activity.appliedKeywords.count
        var parts = ["\(n) keyword\(n == 1 ? "" : "s")"]
        if let reason = activity.fallbackReason { parts.append(reason.shortLabel) }
        return parts.joined(separator: " · ")
    }
}
