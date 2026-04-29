import Foundation

public struct UserSettings: Codable, Equatable, Sendable {
    public var whisperModelSize: String
    public var language: String
    public var disableNoiseSuppression: Bool
    public var llmProvider: String
    public var llmModel: String
    public var customDict: [String]
    public var hotkey: KeyboardShortcut

    public init(
        whisperModelSize: String = "small",
        language: String = "en",
        disableNoiseSuppression: Bool = false,
        llmProvider: String = "anthropic",
        llmModel: String = "claude-sonnet-4-6",
        customDict: [String] = [],
        hotkey: KeyboardShortcut = .defaultPTT
    ) {
        self.whisperModelSize = whisperModelSize
        self.language = language
        self.disableNoiseSuppression = disableNoiseSuppression
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.customDict = customDict
        self.hotkey = hotkey
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
