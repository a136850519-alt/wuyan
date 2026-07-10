import Foundation

enum SecureSettingKey {
    static let webDAVPassword = "settings.webdav.password"
    static let s3SecretKey = "settings.s3.secretKey"
    static let zhipuAPIKey = "settings.zhipu.apiKey"
    static let claudeAPIKey = "settings.claude.apiKey"
    static let syncPassphrase = "sync.passphrase"
    static let legacySyncPassphrase = "settings.crypto.passphrase"
}

enum SecureSettings {
    static func load(_ key: String, legacyDefaultsKey: String? = nil) -> String {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: key), !value.isEmpty {
            return value
        }

        if let legacyDefaultsKey,
           let value = defaults.string(forKey: legacyDefaultsKey),
           !value.isEmpty {
            defaults.set(value, forKey: key)
            return value
        }

        return ""
    }

    static func save(_ value: String, for key: String, legacyDefaultsKey: String? = nil) {
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
        if let legacyDefaultsKey, legacyDefaultsKey != key {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
    }
}
