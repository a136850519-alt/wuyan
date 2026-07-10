import Foundation

enum SecureSettingKey {
    static let webDAVPassword = "settings.webdav.password"
    static let s3SecretKey = "settings.s3.secretKey"
    static let zhipuAPIKey = "settings.zhipu.apiKey"
    static let claudeAPIKey = "settings.claude.apiKey"
    static let syncPassphrase = "sync.passphrase"
    static let legacySyncPassphrase = "settings.crypto.passphrase"

    /// 所有需要存入 Keychain 的 key（含 legacy），用于一次性迁移。
    static let allKeysForMigration: [String] = [
        webDAVPassword, s3SecretKey, zhipuAPIKey, claudeAPIKey,
        syncPassphrase, legacySyncPassphrase
    ]
}

enum SecureSettings {
    private static let keychain = Keychain()
    private static let migrationKey = "wuyan.secureSettings.migratedToKeychain"

    static func load(_ key: String, legacyDefaultsKey: String? = nil) -> String {
        // 1. 先从 Keychain 读取
        if let value = keychain.string(for: key), !value.isEmpty {
            return value
        }

        // 2. 迁移：Keychain 无值但 UserDefaults 有 → 写入 Keychain 并清掉 defaults
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: key), !value.isEmpty {
            keychain.setString(value, for: key)
            defaults.removeObject(forKey: key)
            return value
        }

        // 3. Legacy key 迁移
        if let legacyDefaultsKey,
           let value = defaults.string(forKey: legacyDefaultsKey),
           !value.isEmpty {
            keychain.setString(value, for: key)
            defaults.removeObject(forKey: legacyDefaultsKey)
            return value
        }

        return ""
    }

    static func save(_ value: String, for key: String, legacyDefaultsKey: String? = nil) {
        if value.isEmpty {
            keychain.setString(nil, for: key)
        } else {
            keychain.setString(value, for: key)
        }
        // 清掉旧的 UserDefaults 残留
        UserDefaults.standard.removeObject(forKey: key)
        if let legacyDefaultsKey, legacyDefaultsKey != key {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
    }

    /// 一次性迁移所有凭据：把 UserDefaults 里的值写入 Keychain 并删除 defaults 条目。
    static func migrateAllFromDefaults() {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        let defaults = UserDefaults.standard
        for key in SecureSettingKey.allKeysForMigration {
            if let value = defaults.string(forKey: key), !value.isEmpty {
                keychain.setString(value, for: key)
                defaults.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(true, forKey: migrationKey)
    }
}
