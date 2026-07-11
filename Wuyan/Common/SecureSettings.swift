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

        // 2. 迁移：Keychain 无值但 UserDefaults 有 → 写入 Keychain 后验证再清 defaults
        // R0-6: 先写入 Keychain，验证读回成功后才删除 UserDefaults，防止静默丢失凭据。
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: key), !value.isEmpty {
            if keychain.setString(value, for: key),
               let readback = keychain.string(for: key), readback == value {
                defaults.removeObject(forKey: key)
                return value
            } else {
                // Keychain 写入失败，保留 UserDefaults 值
                WuyanLog.security.error("Keychain 写入失败：\(key)，保留 UserDefaults 值")
                return value
            }
        }

        // 3. Legacy key 迁移
        // R0-6: legacy key 的值应写入新 key（而非 legacy key）到 Keychain
        if let legacyDefaultsKey,
           let value = defaults.string(forKey: legacyDefaultsKey),
           !value.isEmpty {
            if keychain.setString(value, for: key),
               let readback = keychain.string(for: key), readback == value {
                defaults.removeObject(forKey: legacyDefaultsKey)
                return value
            } else {
                WuyanLog.security.error("Keychain 写入失败（legacy→\(key)），保留 UserDefaults 值")
                return value
            }
        }

        return ""
    }

    static func save(_ value: String, for key: String, legacyDefaultsKey: String? = nil) {
        // R0-6: 验证 Keychain 写入成功后再清 UserDefaults
        if value.isEmpty {
            keychain.setString(nil, for: key)
        } else {
            if !keychain.setString(value, for: key) {
                WuyanLog.security.error("Keychain 保存失败：\(key)")
            }
        }
        // 清掉旧的 UserDefaults 残留
        UserDefaults.standard.removeObject(forKey: key)
        if let legacyDefaultsKey, legacyDefaultsKey != key {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
    }

    /// 一次性迁移所有凭据：把 UserDefaults 里的值写入 Keychain 并删除 defaults 条目。
    /// R0-6: legacySyncPassphrase 不再独立写入 Keychain，而是归并到 sync.passphrase。
    static func migrateAllFromDefaults() {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        let defaults = UserDefaults.standard

        // 优先迁移 legacySyncPassphrase → sync.passphrase（归并而非独立写入）
        if let value = defaults.string(forKey: SecureSettingKey.legacySyncPassphrase), !value.isEmpty {
            if keychain.setString(value, for: SecureSettingKey.syncPassphrase),
               let readback = keychain.string(for: SecureSettingKey.syncPassphrase), readback == value {
                defaults.removeObject(forKey: SecureSettingKey.legacySyncPassphrase)
            }
        }

        // 迁移其他 key（不含 legacySyncPassphrase，已归并处理）
        let keysToMigrate = [
            SecureSettingKey.webDAVPassword,
            SecureSettingKey.s3SecretKey,
            SecureSettingKey.zhipuAPIKey,
            SecureSettingKey.claudeAPIKey,
            SecureSettingKey.syncPassphrase
        ]
        for key in keysToMigrate {
            if let value = defaults.string(forKey: key), !value.isEmpty {
                if keychain.setString(value, for: key),
                   let readback = keychain.string(for: key), readback == value {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        UserDefaults.standard.set(true, forKey: migrationKey)
    }
}
