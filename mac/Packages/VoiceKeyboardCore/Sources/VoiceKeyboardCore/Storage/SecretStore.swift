import Foundation
import Security

/// Per-provider API-key storage. Each provider (e.g. "anthropic", "openai")
/// gets its own slot, so switching providers in Settings doesn't clobber
/// the previous one's key.
public protocol SecretStore: Sendable {
    func getAPIKey(forProvider provider: String) throws -> String?
    func setAPIKey(_ key: String, forProvider provider: String) throws
    func deleteAPIKey(forProvider provider: String) throws
}

public enum SecretStoreError: Error {
    case keychainStatus(OSStatus)
}

/// Keychain-backed production impl. Stores under
/// service="VoiceKeyboard", account="\(provider).api_key", so each
/// provider keeps a distinct slot. Existing "anthropic.api_key" entries
/// from before this refactor are read transparently.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service = "VoiceKeyboard"

    public init() {}

    private func account(for provider: String) -> String {
        "\(provider).api_key"
    }

    public func getAPIKey(forProvider provider: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let str = String(data: data, encoding: .utf8) else {
                return nil
            }
            return str
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychainStatus(status)
        }
    }

    public func setAPIKey(_ key: String, forProvider provider: String) throws {
        try deleteAPIKey(forProvider: provider)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
            kSecValueData as String: Data(key.utf8),
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            throw SecretStoreError.keychainStatus(status)
        }
    }

    public func deleteAPIKey(forProvider provider: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SecretStoreError.keychainStatus(status)
        }
    }
}

/// In-memory impl for tests.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var keys: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func getAPIKey(forProvider provider: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return keys[provider]
    }

    public func setAPIKey(_ key: String, forProvider provider: String) throws {
        lock.lock(); defer { lock.unlock() }
        keys[provider] = key
    }

    public func deleteAPIKey(forProvider provider: String) throws {
        lock.lock(); defer { lock.unlock() }
        keys.removeValue(forKey: provider)
    }
}
