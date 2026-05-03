import SwiftUI
import VoiceKeyboardCore

/// Settings window: sidebar on the left listing each pane, detail
/// panel on the right showing the selected pane. Mirrors the design
/// of the sister oled-saver-macos project so the two apps feel like
/// one product family. The previous TabView layout is gone.

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case voice
    case hotkey
    case provider
    case dictionary
    case playground
    case pipeline   // NEW

    var id: Self { self }

    var title: String {
        switch self {
        case .general:    return "General"
        case .voice:      return "Voice"
        case .hotkey:     return "Hotkey"
        case .provider:   return "Provider"
        case .dictionary: return "Dictionary"
        case .playground: return "Playground"
        case .pipeline:   return "Pipeline"   // NEW
        }
    }

    /// SF Symbol name for the sidebar row + page header. Matches the
    /// previous TabView's `tabItem` icons so the visual identity of
    /// each pane carries over.
    var icon: String {
        switch self {
        case .general:    return "gearshape"
        case .voice:      return "person.wave.2"
        case .hotkey:     return "keyboard"
        case .provider:   return "key"
        case .dictionary: return "books.vertical"
        case .playground: return "waveform"
        case .pipeline:   return "rectangle.connected.to.line.below"   // NEW
        }
    }

    /// Background colour for the rounded-square icon tile. Apple-style
    /// preference panes use distinct colours per page so the sidebar
    /// reads at a glance.
    var iconColor: Color {
        switch self {
        case .general:    return .gray
        case .voice:      return .purple
        case .hotkey:     return .blue
        case .provider:   return .orange
        case .dictionary: return .green
        case .playground: return .pink
        case .pipeline:   return .indigo   // NEW
        }
    }
}

struct SettingsView: View {
    let composition: CompositionRoot
    @State private var settings: UserSettings = UserSettings()
    @State private var selectedPage: SettingsPage = .general

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar — Apple-style colored icon rows.
            List(selection: $selectedPage) {
                Section("Voice Keyboard") {
                    ForEach(visiblePages) { page in
                        SidebarRow(page: page).tag(page)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            // Detail panel — page header + content. Translucent
            // sidebar material matches macOS-native preference windows.
            DetailView(
                page: selectedPage,
                composition: composition,
                settings: $settings,
                save: save
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
                    .ignoresSafeArea()
            )
        }
        .frame(minWidth: 720, minHeight: 520)
        .task {
            settings = (try? composition.settings.get()) ?? UserSettings()
        }
        .onChange(of: settings.developerMode) { _, on in
            if !on, selectedPage == .pipeline {
                selectedPage = .general
            }
        }
    }

    private var visiblePages: [SettingsPage] {
        SettingsPage.allCases.filter { page in
            switch page {
            case .pipeline: return settings.developerMode
            default:        return true
            }
        }
    }

    private func save(_ s: UserSettings) {
        try? composition.settings.set(s)
        Task { @MainActor in
            // Clear the recording pause before reapplyConfig so the
            // hotkey monitor restarts with the new shortcut.
            composition.coordinator.clearHotkeyPause()
            await composition.coordinator.reapplyConfig()
        }
    }
}

// MARK: - Sidebar Row

private struct SidebarRow: View {
    let page: SettingsPage

    var body: some View {
        Label {
            Text(page.title)
        } icon: {
            Image(systemName: page.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(page.iconColor.gradient)
                )
        }
    }
}

// MARK: - Detail Panel

/// Renders the page header and dispatches into the existing tab body
/// for each page. We keep the existing tab Views (GeneralTab, VoiceTab,
/// etc.) as-is so this redesign is a pure shell change — refactoring
/// each page's internals to use SettingsSection cards is a separate
/// effort.
private struct DetailView: View {
    let page: SettingsPage
    let composition: CompositionRoot
    @Binding var settings: UserSettings
    let save: (UserSettings) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                pageBody
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: page.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(page.iconColor.gradient)
                )
            Text(page.title)
                .font(.title2)
                .fontWeight(.semibold)
        }
    }

    @ViewBuilder
    private var pageBody: some View {
        switch page {
        case .general:
            GeneralTab(
                settings: $settings,
                onSave: save,
                audioCapture: composition.audioCapture
            )
        case .voice:
            VoiceTab(
                settings: $settings,
                onSave: save,
                audioCapture: composition.audioCapture,
                engine: composition.engine
            )
        case .hotkey:
            HotkeyTab(
                settings: $settings,
                onSave: save,
                onRecordingStart: {
                    composition.coordinator.pauseHotkeyForRecording()
                },
                onRecordingEnd: {
                    Task { @MainActor in
                        await composition.coordinator.resumeHotkeyAfterRecording()
                    }
                },
                conflictChecker: composition.conflictChecker,
                permissions: composition.permissions,
                audioCapture: composition.audioCapture
            )
        case .provider:
            ProviderTab(settings: $settings, onSave: save, secrets: composition.secrets)
        case .dictionary:
            DictionaryTab(settings: $settings, onSave: save)
        case .playground:
            PlaygroundTab(
                appState: composition.appState,
                hotkey: settings.hotkey,
                coordinator: composition.coordinator
            )
        case .pipeline:
            PipelineTab(
                engine: composition.engine,
                sessions: LibVKBSessionsClient(engine: composition.engine)
            )
        }
    }
}
