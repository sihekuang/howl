import HowlCore
import SwiftUI

/// Settings page for screen context.
///
/// Split out of `GeneralTab`, which had grown to own the preset
/// picker, the microphone picker, model downloads, launch-at-login AND
/// this. Screen context earns its own page for the same reason
/// `Dictionary` has one: both are recognition-biasing features whose
/// settings need room to explain themselves, and this one carries a
/// privacy disclosure plus a multi-row inspector that reads badly
/// wedged under unrelated controls.
///
/// ## Layout
///
/// Its own page still wasn't enough: a toggle, a privacy paragraph, an
/// editable denylist, a six-row inspector for the latest activity and
/// a flat recent-activity list were all stacked in one column, and only
/// the newest entry was ever inspectable.
///
/// So it now follows `PlaygroundTab`: compact controls on top, then an
/// `HSplitView` with a selectable list on the left and the selected
/// item's detail on the right. The denylist is collapsed behind a
/// disclosure (`ScreenContextDenylistEditor`), which leaves the top of
/// the page at four lines regardless of how many apps are on it.
///
/// ## Selection
///
/// See `ScreenContextActivitySelection` — the pane follows the newest
/// arrival by default, but an explicitly selected older entry is never
/// yanked away. That is load-bearing rather than polish: opening this
/// window makes Howl frontmost, Howl's own bundle ID is denylisted, so
/// a "Skipped" entry lands at the top of the list at the exact moment
/// the user wants to read the entry underneath it.
struct ScreenContextTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    /// Source of the live whisper-prompt preview shown in the detail
    /// pane's own clearly-fenced-off group.
    let engine: any CoreEngine
    /// In-memory ring buffer the coordinator pushes each refresh into.
    let screenContextActivity: ScreenContextActivityStore

    @State private var preview: ScreenContextPreview?
    @State private var selectedID: UUID?
    /// Whether `selectedID` should track new arrivals. Derived from the
    /// selection itself (see `ScreenContextActivitySelection`), stored
    /// because the answer has to be known from BEFORE the list changed.
    @State private var followsNewest = true

    private var activities: [ScreenContextActivity] { screenContextActivity.recentFirst }

    private var selected: ScreenContextActivity? {
        activities.first { $0.id == selectedID }
    }

    var body: some View {
        SettingsPane {
            Toggle("Use what's on screen to improve recognition", isOn: $settings.screenContextEnabled)
            // This paragraph is a privacy disclosure, not marketing
            // copy: it is the only place the user is told that a
            // picture of their focused window leaves the machine. Keep
            // it accurate if the capture path changes again.
            Text("""
                 Howl takes a screenshot of your focused window and sends it to your \
                 configured LLM provider, which reads it for names and jargon that bias \
                 Whisper toward the right spellings. This needs Screen Recording \
                 permission. Providers whose model can't read images fall back to the \
                 window's accessibility text instead. Password managers are never \
                 captured or read.
                 """)
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.screenContextEnabled {
                ScreenContextDenylistEditor(denylist: $settings.screenContextDenylist)
                Divider()
                activitySplit
            }
        }
        // Matches every other settings page: mutate the binding, persist
        // on change. Without this the toggle and the never-read list
        // would look editable and silently fail to save.
        .onChange(of: settings) { _, new in onSave(new) }
        .onChange(of: selectedID) { _, new in
            followsNewest = ScreenContextActivitySelection.followsNewest(new, in: activities)
        }
        // Keyed on the newest activity's id, NOT on `entries.count`:
        // the store is a fixed-capacity ring buffer, so once it is full
        // the count stops changing and a count-keyed task would never
        // fire again.
        .task(id: screenContextActivity.recentFirst.first?.id) {
            selectedID = ScreenContextActivitySelection.reconciled(
                recentFirst: activities,
                current: selectedID,
                followsNewest: followsNewest
            )
            // Refetched on every new activity: the preview reflects
            // live engine state (current dictionary + stored screen
            // keywords), which the refresh that just landed may have
            // changed — including clearing it, on a denylist skip.
            preview = await engine.screenContextPreview()
        }
    }

    /// Master/detail, mirroring `PlaygroundTab`'s split — same
    /// `HSplitView`, same narrow-list / wide-detail frames.
    ///
    /// The explicit `minHeight` is not decoration: the whole settings
    /// page lives inside `DetailView`'s `ScrollView`, so the split has
    /// no definite height to divide and the list's own `ScrollView`
    /// would otherwise collapse to nothing.
    @ViewBuilder
    private var activitySplit: some View {
        HSplitView {
            ScreenContextActivityList(activities: activities, selectedID: $selectedID)
                .frame(minWidth: 200, idealWidth: 240)
            detailColumn
                .frame(minWidth: 320)
        }
        .frame(minHeight: 360)
    }

    @ViewBuilder
    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected {
                ScreenContextActivityDetail(
                    activity: selected,
                    preview: preview,
                    isNewest: selected.id == activities.first?.id
                )
                // Disclosure state (show text / show raw / show full
                // prompt) belongs to the entry being read, not to the
                // pane — re-identify so switching selection starts
                // collapsed instead of inheriting the last entry's
                // open disclosures.
                .id(selected.id)
            } else {
                Text("Select an activity on the left.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
