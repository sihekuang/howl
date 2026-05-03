import Foundation

public struct UserSettings: Codable, Equatable, Sendable {
    public var whisperModelSize: String
    public var language: String
    public var disableNoiseSuppression: Bool
    public var llmProvider: String
    public var llmModel: String
    public var llmBaseURL: String   // empty = provider's default endpoint
    public var customDict: [String]
    public var hotkey: KeyboardShortcut
    /// CoreAudio/AVCaptureDevice unique ID for the input device.
    /// `nil` (the default) means "follow the system default".
    public var inputDeviceUID: String?
    /// Whether to apply Target Speaker Extraction during capture.
    /// Requires a completed voice enrollment in
    /// ~/Library/Application Support/VoiceKeyboard/voice/.
    public var tseEnabled: Bool
    /// When true, unlocks the Pipeline Settings tab (live inspector,
    /// per-stage capture, A/B comparison) and tells the engine to
    /// capture every dictation's per-stage WAVs + transcripts to
    /// /tmp/voicekeyboard/sessions/. Default false; casual users
    /// never see the extra surface.
    public var developerMode: Bool

    public init(
        whisperModelSize: String = "small",
        language: String = "en",
        disableNoiseSuppression: Bool = false,
        llmProvider: String = "anthropic",
        llmModel: String = "claude-sonnet-4-6",
        llmBaseURL: String = "",
        customDict: [String] = [],
        hotkey: KeyboardShortcut = .defaultPTT,
        inputDeviceUID: String? = nil,
        tseEnabled: Bool = false,
        developerMode: Bool = false
    ) {
        self.whisperModelSize = whisperModelSize
        self.language = language
        self.disableNoiseSuppression = disableNoiseSuppression
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.llmBaseURL = llmBaseURL
        self.customDict = customDict
        self.hotkey = hotkey
        self.inputDeviceUID = inputDeviceUID
        self.tseEnabled = tseEnabled
        self.developerMode = developerMode
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whisperModelSize = try c.decodeIfPresent(String.self, forKey: .whisperModelSize) ?? "small"
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        disableNoiseSuppression = try c.decodeIfPresent(Bool.self, forKey: .disableNoiseSuppression) ?? false
        llmProvider = try c.decodeIfPresent(String.self, forKey: .llmProvider) ?? "anthropic"
        llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel) ?? "claude-sonnet-4-6"
        llmBaseURL = try c.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? ""
        customDict = try c.decodeIfPresent([String].self, forKey: .customDict) ?? []
        hotkey = try c.decodeIfPresent(KeyboardShortcut.self, forKey: .hotkey) ?? .defaultPTT
        inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        tseEnabled = try c.decodeIfPresent(Bool.self, forKey: .tseEnabled) ?? false
        developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case whisperModelSize, language, disableNoiseSuppression
        case llmProvider, llmModel, llmBaseURL, customDict, hotkey, inputDeviceUID, tseEnabled
        case developerMode
    }
}

public protocol SettingsStore: Sendable {
    func get() throws -> UserSettings
    func set(_ settings: UserSettings) throws
}

/// UserDefaults-backed production impl.
public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "VoiceKeyboard.UserSettings.v1"

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
