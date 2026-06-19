import Foundation

public struct UserSettings: Codable, Equatable, Sendable {
    public var whisperModelSize: String
    public var language: String
    /// Optional second language for code-switch dictation. "none" (default)
    /// means single-language behavior. When set, the engine loads the
    /// multilingual large model and the dictionary primes both scripts.
    public var secondaryLanguage: String
    public var disableNoiseSuppression: Bool
    public var llmProvider: String
    public var llmModel: String
    public var llmBaseURL: String   // empty = provider's default endpoint
    public var llmPrompt: String
    public var customDict: [String]
    public var hotkey: KeyboardShortcut
    /// Optional HID device element bound as a second recording trigger,
    /// active alongside `hotkey`. `nil` (the default) means no HID trigger.
    public var hidBinding: HIDBinding?
    /// CoreAudio/AVCaptureDevice unique ID for the input device.
    /// `nil` (the default) means "follow the system default".
    public var inputDeviceUID: String?
    /// Whether to apply Target Speaker Extraction during capture.
    /// Requires a completed voice enrollment in
    /// ~/Library/Application Support/Howl/voice/.
    public var tseEnabled: Bool
    /// Cosine-similarity threshold for the post-extract speaker gate.
    /// nil or 0 disables gating. Stamped in by `applying(_:)` from the
    /// active preset's `tse.threshold`.
    public var tseThreshold: Float?
    /// TSE backend identifier (e.g. "ecapa"). Stamped in by `applying(_:)`
    /// from the active preset's `tse.backend`. Empty falls back to the
    /// engine default.
    public var tseBackend: String
    /// Pipeline run timeout in seconds. 0 disables the bound. Global —
    /// not stamped from presets, edited by the user as a standalone
    /// engine-tuning setting.
    public var pipelineTimeoutSec: Int
    /// Name of the preset the user last applied via Settings → Playground.
    /// Display-only — the actual values live in the fields above. nil for
    /// users who never picked a preset (legacy installs) or who edited
    /// individual fields after applying a preset (we don't detect drift
    /// today; the picker just shows whatever was last applied).
    public var selectedPresetName: String?

    public init(
        whisperModelSize: String = "small",
        language: String = "en",
        secondaryLanguage: String = "none",
        disableNoiseSuppression: Bool = false,
        llmProvider: String = "anthropic",
        llmModel: String = "claude-sonnet-4-6",
        llmBaseURL: String = "",
        llmPrompt: String = "",
        customDict: [String] = [],
        hotkey: KeyboardShortcut = .defaultPTT,
        hidBinding: HIDBinding? = nil,
        inputDeviceUID: String? = nil,
        tseEnabled: Bool = false,
        tseThreshold: Float? = nil,
        tseBackend: String = "",
        pipelineTimeoutSec: Int = 10,
        selectedPresetName: String? = nil
    ) {
        self.whisperModelSize = whisperModelSize
        self.language = language
        self.secondaryLanguage = secondaryLanguage
        self.disableNoiseSuppression = disableNoiseSuppression
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.llmBaseURL = llmBaseURL
        self.llmPrompt = llmPrompt
        self.customDict = customDict
        self.hotkey = hotkey
        self.hidBinding = hidBinding
        self.inputDeviceUID = inputDeviceUID
        self.tseEnabled = tseEnabled
        self.tseThreshold = tseThreshold
        self.tseBackend = tseBackend
        self.pipelineTimeoutSec = pipelineTimeoutSec
        self.selectedPresetName = selectedPresetName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whisperModelSize = try c.decodeIfPresent(String.self, forKey: .whisperModelSize) ?? "small"
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        secondaryLanguage = try c.decodeIfPresent(String.self, forKey: .secondaryLanguage) ?? "none"
        disableNoiseSuppression = try c.decodeIfPresent(Bool.self, forKey: .disableNoiseSuppression) ?? false
        llmProvider = try c.decodeIfPresent(String.self, forKey: .llmProvider) ?? "anthropic"
        llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel) ?? "claude-sonnet-4-6"
        llmBaseURL = try c.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? ""
        llmPrompt = try c.decodeIfPresent(String.self, forKey: .llmPrompt) ?? ""
        customDict = try c.decodeIfPresent([String].self, forKey: .customDict) ?? []
        hotkey = try c.decodeIfPresent(KeyboardShortcut.self, forKey: .hotkey) ?? .defaultPTT
        hidBinding = try c.decodeIfPresent(HIDBinding.self, forKey: .hidBinding)
        inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        tseEnabled = try c.decodeIfPresent(Bool.self, forKey: .tseEnabled) ?? false
        tseThreshold = try c.decodeIfPresent(Float.self, forKey: .tseThreshold)
        tseBackend = try c.decodeIfPresent(String.self, forKey: .tseBackend) ?? ""
        pipelineTimeoutSec = try c.decodeIfPresent(Int.self, forKey: .pipelineTimeoutSec) ?? 10
        selectedPresetName = try c.decodeIfPresent(String.self, forKey: .selectedPresetName)
    }

    enum CodingKeys: String, CodingKey {
        case whisperModelSize, language, secondaryLanguage, disableNoiseSuppression
        case llmProvider, llmModel, llmBaseURL, llmPrompt, customDict, hotkey, hidBinding, inputDeviceUID, tseEnabled
        case tseThreshold, tseBackend, pipelineTimeoutSec
        case selectedPresetName
    }

    /// Returns a copy with the preset-driven fields stamped in.
    ///
    /// Always stamped: denoise toggle, TSE toggle/threshold/backend, and
    /// `selectedPresetName` (display-only).
    ///
    /// Bundled (built-in) presets do NOT override the user's Whisper
    /// model / LLM provider / LLM model — those live in their dedicated
    /// Settings sections (General, LLM Provider) as user-managed globals.
    /// User-created presets DO pin those values per-preset (so a user
    /// can save a preset with a specific transcribe + LLM combo).
    ///
    /// `pipelineTimeoutSec` is intentionally NOT stamped from any preset —
    /// timeout is a global engine-tuning setting. The preset's
    /// `timeoutSec` is currently ignored on this path.
    public func applying(_ preset: Preset) -> UserSettings {
        var s = self
        s.selectedPresetName = preset.name
        if !preset.prompt.isEmpty {
            s.llmPrompt = preset.prompt
        }
        for st in preset.frameStages where st.name == "denoise" {
            s.disableNoiseSuppression = !st.enabled
        }
        for st in preset.chunkStages where st.name == "tse" {
            s.tseEnabled = st.enabled
            s.tseThreshold = st.threshold
            s.tseBackend = st.backend ?? ""
        }
        if !preset.isBundled {
            s.whisperModelSize = preset.transcribe.modelSize
            s.llmProvider = preset.llm.provider
            if let m = preset.llm.model {
                s.llmModel = m
            }
        }
        return s
    }
}

public protocol SettingsStore: Sendable {
    func get() throws -> UserSettings
    func set(_ settings: UserSettings) throws
}

/// UserDefaults-backed production impl.
public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "Howl.UserSettings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func get() throws -> UserSettings {
        guard let data = defaults.data(forKey: key) else {
            return UserSettings()
        }
        return try JSONDecoder().decode(UserSettings.self, from: data)
    }

    public func set(_ settings: UserSettings) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: key)
    }
}

/// In-memory impl for tests.
public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private var current: UserSettings?
    private let lock = NSLock()

    public init() {}

    public func get() throws -> UserSettings {
        lock.lock(); defer { lock.unlock() }
        return current ?? UserSettings()
    }

    public func set(_ settings: UserSettings) throws {
        lock.lock(); defer { lock.unlock() }
        current = settings
    }
}
