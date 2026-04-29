import Foundation
import Security

public protocol SecretStore: Sendable {
    func getAPIKey() throws -> String?
    func setAPIKey(_ key: String) throws
    func deleteAPIKey() throws
}

public enum SecretStoreError: Error {
    case keychainStatus(OSStatus)
}

/// Keychain-backed production impl. Stores under a single service+account
/// pair: service="VoiceKeyboard", account="anthropic.api_key".
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service = "VoiceKeyboard"
    private let account = "anthropic.api_key"

    public init() {}

    public func getAPIKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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

    public func setAPIKey(_ key: String) throws {
        try deleteAPIKey()
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            throw SecretStoreError.keychainStatus(status)
        }
    }

    public func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SecretStoreError.keychainStatus(status)
        }
    }
}

/// In-memory impl for tests.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var key: String?
    private let lock = NSLock()

    public init() {}

    public func getAPIKey() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return key
    }

    public func setAPIKey(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        self.key = key
    }

    public func deleteAPIKey() throws {
        lock.lock(); defer { lock.unlock() }
        key = nil
    }
}
