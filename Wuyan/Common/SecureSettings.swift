import Foundation

enum SecureSettingKey {
    static let webDAVPassword = "settings.webdav.password"
    static let s3SecretKey = "settings.s3.secretKey"
    static let zhipuAPIKey = "settings.zhipu.apiKey"
    static let claudeAPIKey = "settings.claude.apiKey"
    static let syncPassphrase = "sync.passphrase"
    static let legacySyncPassphrase = "settings.crypto.passphrase"
    static let diaryPasswordHash = "diary.lock.passwordHash"
    static let diaryPasswordSalt = "diary.lock.passwordSalt"

    /// 所有需要存入 Keychain 的 key（含 legacy），用于一次性迁移。
    static let allKeysForMigration: [String] = [
        webDAVPassword, s3SecretKey, zhipuAPIKey, claudeAPIKey,
        syncPassphrase, legacySyncPassphrase
    ]
}

enum SecureSettings {
    /// Q01：Keychain 实例可注入。生产固定使用默认生产 Keychain；
    /// 测试注入 testService 隔离实例，避免读写生产凭据。
    private static var keychain: Keychain = Keychain()
    /// Q01：legacy 凭据迁移/清理所用的 UserDefaults 同样可注入，
    /// 保证测试容器贯穿「读取—迁移—清理」整条链路而不是只换读取端。
    private static var defaults: UserDefaults = .standard
    private static let migrationKey = "wuyan.secureSettings.migratedToKeychain"

    /// 仅测试目标可调用：注入隔离的 Keychain（如 Keychain(service: Keychain.testService)）。
    static func injectKeychainForTesting(_ injected: Keychain) {
        keychain = injected
    }

    /// 仅测试目标可调用：注入隔离的 UserDefaults（legacy 迁移路径使用）。
    static func injectDefaultsForTesting(_ injected: UserDefaults) {
        defaults = injected
    }

    static func load(_ key: String, legacyDefaultsKey: String? = nil) -> String {
        // 1. 先从 Keychain 读取
        if let value = keychain.string(for: key), !value.isEmpty {
            return value
        }

        // 2. 迁移：Keychain 无值但 UserDefaults 有 → 写入 Keychain 后验证再清 defaults
        // R0-6: 先写入 Keychain，验证读回成功后才删除 UserDefaults，防止静默丢失凭据。
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

    /// 日记锁凭据只允许走钥匙串。不能回退到 UserDefaults，否则钥匙串暂时不可读
    /// 时会被误判为「未启用」并放行正文。
    static func loadKeychainOnly(_ key: String) -> Keychain.ReadResult {
        keychain.readString(for: key)
    }

    /// Preserve the distinction between a missing credential and a keychain
    /// read failure for settings UI. Callers must not turn `.unavailable` into
    /// an empty value or delete the last known credential.
    static func readResult(_ key: String) -> Keychain.ReadResult {
        keychain.readString(for: key)
    }

    @discardableResult
    static func save(_ value: String, for key: String, legacyDefaultsKey: String? = nil) -> Bool {
        // R0-6: 验证 Keychain 写入成功后再清 UserDefaults
        var persisted = false
        if value.isEmpty {
            persisted = keychain.setString(nil, for: key)
        } else {
            persisted = keychain.setString(value, for: key)
            if !persisted {
                WuyanLog.security.error("Keychain 保存失败：\(key)")
            }
        }
        // 只有钥匙串确认成功后才删除 defaults，避免保存失败时丢失旧凭据。
        if persisted {
            defaults.removeObject(forKey: key)
            if let legacyDefaultsKey, legacyDefaultsKey != key {
                defaults.removeObject(forKey: legacyDefaultsKey)
            }
        }
        return persisted
    }

    /// 一次性迁移所有凭据：把 UserDefaults 里的值写入 Keychain 并删除 defaults 条目。
    /// R0-6: legacySyncPassphrase 不再独立写入 Keychain，而是归并到 sync.passphrase。
    static func migrateAllFromDefaults() {
        guard !defaults.bool(forKey: migrationKey) else { return }

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
        // 只有所有旧值都已迁移并清除后才记完成。钥匙串暂时不可用时保留
        // 迁移机会，避免一次失败让凭据永久停留在旧的 UserDefaults 路径。
        let pendingKeys = [
            SecureSettingKey.webDAVPassword,
            SecureSettingKey.s3SecretKey,
            SecureSettingKey.zhipuAPIKey,
            SecureSettingKey.claudeAPIKey,
            SecureSettingKey.syncPassphrase,
            SecureSettingKey.legacySyncPassphrase
        ]
        let hasPendingValues = pendingKeys.contains { key in
            guard let value = defaults.string(forKey: key) else { return false }
            return !value.isEmpty
        }
        if !hasPendingValues {
            defaults.set(true, forKey: migrationKey)
        }
    }
}
