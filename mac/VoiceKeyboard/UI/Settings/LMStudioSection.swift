#if canImport(AppKit)
import AppKit
#endif
import SwiftUI
import VoiceKeyboardCore

/// LM Studio-specific settings. Shown when settings.llmProvider == "lmstudio".
///
/// LM Studio exposes an OpenAI-compatible REST API on port 1234 by
/// default. Like the Ollama section we surface a model picker driven by
/// the local server's /v1/models response and an Advanced disclosure
/// for overriding the base URL. No API key field — LM Studio ignores
/// auth by default.
struct LMStudioSection: View {
    @Binding var settings: UserSettings

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(models: [String])
        case empty                              // reachable, 0 available
        case failed(message: String)
    }

    @State private var loadState: LoadState = .idle
    @State private var baseURLDraft: String = ""

    private static let defaultBaseURL: String = LMStudioClient.defaultBaseURL.absoluteString

    var body: some View {
        Group {
            modelRow
            advancedDisclosure
        }
        .task(id: effectiveBaseURL) {
            await refresh()
        }
        .task(id: baseURLDraft) {
            // Debounce: write to settings.llmBaseURL 500ms after the user
            // stops typing. SwiftUI auto-cancels on view exit and on each
            // baseURLDraft change, so we don't need a manual cancel handle.
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            let new = baseURLDraft
            settings.llmBaseURL = new == Self.defaultBaseURL ? "" : new
        }
        .onAppear {
            if baseURLDraft.isEmpty { baseURLDraft = settings.llmBaseURL }
        }
    }

    // MARK: – Model row (driven by loadState)

    @ViewBuilder
    private var modelRow: some View {
        switch loadState {
        case .idle, .loading:
            HStack {
                Text("Model")
                Spacer()
                ProgressView().controlSize(.small)
            }
        case .loaded(let models):
            HStack {
                Picker("Model", selection: $settings.llmModel) {
                    if !models.contains(settings.llmModel), !settings.llmModel.isEmpty {
                        // Keep the existing pick visible even if it's no longer loaded.
                        Text("\(settings.llmModel) (not loaded)").tag(settings.llmModel)
                    }
                    ForEach(models, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh available models")
            }
        case .empty:
            VStack(alignment: .leading, spacing: 6) {
                Text("No LM Studio models available.")
                Text("Open LM Studio, download a model, then refresh.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Button("Refresh") { Task { await refresh() } }
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn't reach LM Studio at \(effectiveBaseURL)",
                      systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Text("Make sure the LM Studio server is running (Developer tab → Start Server), or change the base URL under Advanced.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Button("Retry") { Task { await refresh() } }
            }
        }
    }

    // MARK: – Advanced disclosure (base URL)

    @ViewBuilder
    private var advancedDisclosure: some View {
        DisclosureGroup("Advanced") {
            HStack {
                TextField("Base URL", text: $baseURLDraft,
                          prompt: Text(Self.defaultBaseURL))
                    .textFieldStyle(.roundedBorder)
                Button("Reset to default") {
                    baseURLDraft = ""
                    settings.llmBaseURL = ""
                }
                .disabled(baseURLDraft.isEmpty)
            }
        }
    }

    // MARK: – Behaviour

    /// The URL we should actually hit. Empty `settings.llmBaseURL` means
    /// "use the default" (mirrors Go's `omitempty`).
    private var effectiveBaseURL: String {
        settings.llmBaseURL.isEmpty ? Self.defaultBaseURL : settings.llmBaseURL
    }

    private func refresh() async {
        loadState = .loading
        guard let url = URL(string: effectiveBaseURL) else {
            loadState = .failed(message: "Invalid URL.")
            return
        }
        let client = LMStudioClient(baseURL: url)
        do {
            let names = try await client.listModels()
            loadState = names.isEmpty ? .empty : .loaded(models: names)
        } catch let e as LMStudioClientError {
            switch e {
            case .unreachable(let u):
                loadState = .failed(message: "Connection refused at \(u.absoluteString)")
            case .http(let status, let body):
                loadState = .failed(message: "HTTP \(status): \(body.prefix(120))")
            case .decode(let detail):
                loadState = .failed(message: "Bad response from LM Studio: \(detail)")
            }
        } catch {
            loadState = .failed(message: error.localizedDescription)
        }
    }
}
