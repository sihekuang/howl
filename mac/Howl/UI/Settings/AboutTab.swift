import SwiftUI
import AppKit
import HowlCore

/// Settings "About" page: app identity, version, a Copy button (handy for bug
/// reports), and links to the repo / release notes. Reads the live version from
/// the bundle so it never needs manual updates. The page header (icon + "About"
/// title) is drawn by `DetailView`; this is just the centered card below it.
struct AboutTab: View {
    // Info.plist never changes at runtime, so read it once rather than on
    // every `body` evaluation.
    private let version = AppVersion(
        short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    )

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("Howl")
                .font(.title)
                .fontWeight(.semibold)
            Text(version.displayString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(version.copyString, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .controlSize(.small)

            HStack(spacing: 16) {
                Link("GitHub", destination: version.repoURL)
                Link("Release notes", destination: version.releaseNotesURL)
            }
            .font(.callout)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
