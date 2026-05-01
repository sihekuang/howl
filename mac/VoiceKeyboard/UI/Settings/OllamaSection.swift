#if canImport(AppKit)
import AppKit
#endif
import SwiftUI
import VoiceKeyboardCore

/// Ollama-specific settings. Shown when settings.llmProvider == "ollama".
struct OllamaSection: View {
    @Binding var settings: UserSettings

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(models: [String])
        case empty                              // reachable, 0 installed
        case failed(message: String)
    }

    @State private var loadState: LoadState = .idle
    @State private var baseURLDraft: String = ""

    private static let defaultBaseURL: String = OllamaClient.defaultBaseURL.absoluteString

    var body: some View {
        Group {
            modelRow
            advancedDisclosure
        }
        .task(id: effectiveBaseURL) {
            // Re-fires whenever effectiveBaseURL changes (incl. first appear).
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
        .task(id: settings.llmModel) {
            // Pre-warm Ollama whenever the user picks a model. This kicks
            // off a /api/generate load request in the background so by
            // the time the user closes Settings and dictates, the model
            // is already resident. Best-effort; failures are silent
            // (the next real Clean call will surface them).
            await prewarmIfNeeded()
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
                        // Keep the existing pick visible even if it's no longer installed.
                        Text("\(settings.llmModel) (not installed)").tag(settings.llmModel)
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
                .help("Refresh installed models")
            }
        case .empty:
            VStack(alignment: .leading, spacing: 6) {
                Text("No Ollama models installed.")
                Text("Run `ollama pull llama3.2` in your terminal, then refresh.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                HStack {
                    Button("Copy command") {
                        copyToPasteboard("ollama pull llama3.2")
                    }
                    Button("Refresh") { Task { await refresh() } }
                }
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn't reach Ollama at \(effectiveBaseURL)",
                      systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Text("Make sure Ollama is running, or change the base URL under Advanced.")
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
        let client = OllamaClient(baseURL: url)
        do {
            let names = try await client.listModels()
            loadState = names.isEmpty ? .empty : .loaded(models: names)
        } catch let e as OllamaClientError {
            switch e {
            case .unreachable(let u):
                loadState = .failed(message: "Connection refused at \(u.absoluteString)")
            case .http(let status, let body):
                loadState = .failed(message: "HTTP \(status): \(body.prefix(120))")
            case .decode(let detail):
                loadState = .failed(message: "Bad response from Ollama: \(detail)")
            }
        } catch {
            loadState = .failed(message: error.localizedDescription)
        }
    }

    /// Best-effort preload — fires whenever `settings.llmModel` changes
    /// (including the initial value on tab appear). No-op when model is
    /// empty. Errors are swallowed because a) this is a hint, not a
    /// contract, and b) the same failure will surface on the next real
    /// Clean call with a clearer message.
    private func prewarmIfNeeded() async {
        let model = settings.llmModel
        guard !model.isEmpty,
              let url = URL(string: effectiveBaseURL) else { return }
        let client = OllamaClient(baseURL: url)
        try? await client.preloadModel(model)
    }

    private func copyToPasteboard(_ s: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}
