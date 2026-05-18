import Foundation
import Security
import os

/// One-shot migration from the pre-rename "VoiceKeyboard" namespace to
/// "Howl". Idempotent: safe to call on every launch. Once a 0.5.5+ build
/// has migrated an install, subsequent launches no-op.
///
/// Three migrations run, each independent and conditional on the
/// destination being absent (so a partial prior run can complete):
///   1. ~/Library/Application Support/VoiceKeyboard/  -> Howl/
///   2. UserDefaults  VoiceKeyboard.UserSettings.v1   -> Howl.UserSettings.v1
///   3. Keychain      service="VoiceKeyboard"          -> service="Howl"
///
/// Must run BEFORE any read of UserDefaults / Keychain / Application
/// Support paths — call it as the first line of
/// AppDelegate.applicationDidFinishLaunching.
enum DataMigration {
    private static let log = Logger(subsystem: "com.howl.app", category: "DataMigration")

    private static let oldNamespace = "VoiceKeyboard"
    private static let newNamespace = "Howl"
    private static let oldDefaultsKey = "VoiceKeyboard.UserSettings.v1"
    private static let newDefaultsKey = "Howl.UserSettings.v1"

    static func runIfNeeded() {
        migrateApplicationSupportDir()
        migrateUserDefaultsKey()
        migrateKeychainService()
    }

    // MARK: - Application Support

    private static func migrateApplicationSupportDir() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let oldDir = appSupport.appendingPathComponent(oldNamespace)
        let newDir = appSupport.appendingPathComponent(newNamespace)

        let oldExists = fm.fileExists(atPath: oldDir.path)
        let newExists = fm.fileExists(atPath: newDir.path)

        if !oldExists {
            return
        }
        if newExists {
            // Both exist: prior run partially completed, or user manually
            // created the new dir. Leave both alone — merging could
            // silently clobber files.
            log.info("Application Support: both \(oldNamespace, privacy: .public)/ and \(newNamespace, privacy: .public)/ exist; skipping rename")
            return
        }
        do {
            try fm.moveItem(at: oldDir, to: newDir)
            log.info("Application Support: renamed \(oldNamespace, privacy: .public)/ -> \(newNamespace, privacy: .public)/")
        } catch {
            log.error("Application Support: rename failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - UserDefaults

    private static func migrateUserDefaultsKey() {
        let defaults = UserDefaults.standard
        guard let oldValue = defaults.data(forKey: oldDefaultsKey) else {
            return
        }
        if defaults.data(forKey: newDefaultsKey) != nil {
            defaults.removeObject(forKey: oldDefaultsKey)
            log.info("UserDefaults: \(newDefaultsKey, privacy: .public) already present; removed stale old key")
            return
        }
        defaults.set(oldValue, forKey: newDefaultsKey)
        defaults.removeObject(forKey: oldDefaultsKey)
        log.info("UserDefaults: migrated \(oldDefaultsKey, privacy: .public) -> \(newDefaultsKey, privacy: .public)")
    }

    // MARK: - Keychain

    private static func migrateKeychainService() {
        // Enumerate all generic-password items under the old service,
        // copy each to the new service, then delete the old.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldNamespace,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return
        }
        if status != errSecSuccess {
            log.error("Keychain: copyMatching failed status=\(status, privacy: .public)")
            return
        }
        guard let items = result as? [[String: Any]] else { return }
        var migrated = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else {
                continue
            }
            let probe: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: newNamespace,
                kSecAttrAccount as String: account,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            let exists = SecItemCopyMatching(probe as CFDictionary, nil) == errSecSuccess
            if !exists {
                let add: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: newNamespace,
                    kSecAttrAccount as String: account,
                    kSecValueData as String: data,
                ]
                let addStatus = SecItemAdd(add as CFDictionary, nil)
                if addStatus != errSecSuccess {
                    log.error("Keychain: add for account=\(account, privacy: .public) failed status=\(addStatus, privacy: .public)")
                    continue
                }
            }
            let del: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: oldNamespace,
                kSecAttrAccount as String: account,
            ]
            _ = SecItemDelete(del as CFDictionary)
            migrated += 1
        }
        if migrated > 0 {
            log.info("Keychain: migrated \(migrated, privacy: .public) item(s) from service=\(oldNamespace, privacy: .public) -> \(newNamespace, privacy: .public)")
        }
    }
}
