import HowlCore
import SwiftUI

/// The "Never read" list, collapsed behind a `DisclosureGroup`.
///
/// This is configuration the user touches once and then forgets, so it
/// spends its life closed with a count in the label ("Never read — 11
/// apps") rather than occupying a screenful of rows above the activity
/// inspector, which is the thing people actually open this page to
/// read.
///
/// Both halves of the list are shown, and the difference between them
/// matters: `ScreenContextDenylist.builtIn` is compiled in and cannot
/// be removed (that is the point of it — a password manager's window
/// is a secret by definition), while the user's own additions are
/// editable. Only the second list is bound; the first is rendered from
/// the same constant the coordinator actually consults, so it can
/// never drift into claiming coverage that isn't there.
///
/// Behaviour is unchanged from when these rows lived inline in
/// `ScreenContextSection`: the binding is still just
/// `UserSettings.screenContextDenylist`, and the page's `onChange`
/// still persists it.
struct ScreenContextDenylistEditor: View {
    @Binding var denylist: [String]

    @State private var newBundleID: String = ""
    @State private var isExpanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                builtInList
                Divider()
                userList
                addRow
            }
            .padding(.top, 8)
        } label: {
            Text(summaryLabel).font(.callout)
        }
    }

    /// Label doubles as the count, so the collapsed state still tells
    /// the user how much protection is in force.
    private var summaryLabel: String {
        let total = ScreenContextDenylist.builtIn.count + denylist.count
        return "Never read — \(total) app\(total == 1 ? "" : "s")"
    }

    // MARK: - Built in

    @ViewBuilder
    private var builtInList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Always, built in")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ScreenContextDenylist.builtIn, id: \.self) { id in
                Text(id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // Not part of `builtIn` — it is resolved at runtime from
            // `Bundle.main.bundleIdentifier` (see ScreenContextDenylist)
            // — so it is described rather than listed, and left out of
            // the count so the count matches the rows above.
            Text("Howl's own windows are never read either.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - User additions

    @ViewBuilder
    private var userList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your additions")
                .font(.caption).foregroundStyle(.secondary)
            if denylist.isEmpty {
                Text("None yet.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(denylist, id: \.self) { id in
                HStack {
                    Text(id).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("Remove") {
                        denylist.removeAll { $0 == id }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder
    private var addRow: some View {
        HStack {
            TextField("com.example.app", text: $newBundleID)
                .textFieldStyle(.roundedBorder)
            Button("Add") { add() }
                .disabled(trimmedNewBundleID.isEmpty)
        }
    }

    private var trimmedNewBundleID: String {
        newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        let trimmed = trimmedNewBundleID
        guard !trimmed.isEmpty, !denylist.contains(trimmed) else { return }
        denylist.append(trimmed)
        newBundleID = ""
    }
}
