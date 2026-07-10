import CryptoKit
import Foundation
import Security

/// 远端存储/AI/加密 的工厂方法：从 UserDefaults + Keychain 读取配置并构建 provider 实例。
enum ProviderFactory {
    static func makeAIProvider() -> AIProvider? {
        let provider = AppSettings.aiProvider
        if provider == "zhipu" {
            let endpoint = urlFromDefaults(
                key: SettingKey.zhipuEndpoint,
                fallback: AppSettings.zhipuEndpoint
            )
            return ZhipuProvider(
                apiKey: SecureSettings.load(SecureSettingKey.zhipuAPIKey, legacyDefaultsKey: SecureSettingKey.zhipuAPIKey),
                model: AppSettings.zhipuModel,
                endpoint: endpoint
            )
        }
        if provider == "claude" {
            let endpoint = urlFromDefaults(
                key: SettingKey.claudeEndpoint,
                fallback: AppSettings.claudeEndpoint
            )
            return ClaudeProvider(
                apiKey: SecureSettings.load(SecureSettingKey.claudeAPIKey, legacyDefaultsKey: SecureSettingKey.claudeAPIKey),
                model: AppSettings.claudeModel,
                endpoint: endpoint
            )
        }
        let endpoint = URL(string: AppSettings.ollamaEndpoint) ?? URL(string: "http://localhost:11434")!
        return OllamaProvider(
            endpoint: endpoint,
            model: AppSettings.ollamaModel,
            embeddingModel: AppSettings.ollamaEmbeddingModel
        )
    }

    static func makeRemoteStorageProvider() throws -> any RemoteStorageProvider {
        let backend = AppSettings.storageBackend
        if backend == "s3" {
            guard let endpoint = URL(string: AppSettings.s3Endpoint) else {
                throw RemoteStorageError.invalidBaseURL
            }
            let bucket = AppSettings.s3Bucket
            guard !bucket.isEmpty else { throw RemoteStorageError.missingConfiguration("S3 bucket") }
            let secretKey = SecureSettings.load(SecureSettingKey.s3SecretKey, legacyDefaultsKey: SecureSettingKey.s3SecretKey)
            guard !AppSettings.s3AccessKey.isEmpty, !secretKey.isEmpty else {
                throw RemoteStorageError.missingCredentials
            }
            return S3Provider(
                endpoint: endpoint,
                bucket: bucket,
                region: AppSettings.s3Region,
                accessKey: AppSettings.s3AccessKey,
                secretKey: secretKey,
                pathStyle: AppSettings.s3PathStyle
            )
        }

        guard let url = URL(string: AppSettings.webDAVBaseURL) else {
            throw RemoteStorageError.invalidBaseURL
        }
        let username = AppSettings.webDAVUsername
        let password = SecureSettings.load(SecureSettingKey.webDAVPassword, legacyDefaultsKey: SecureSettingKey.webDAVPassword)
        guard !username.isEmpty, !password.isEmpty else {
            throw RemoteStorageError.missingCredentials
        }
        return WebDAVProvider(
            baseURL: url,
            username: username,
            password: password
        )
    }

    static func makeSyncCrypto() -> SyncCrypto? {
        guard AppSettings.cryptoEnabled else { return nil }
        let passphrase = SecureSettings.load(SecureSettingKey.syncPassphrase, legacyDefaultsKey: SecureSettingKey.legacySyncPassphrase)
        guard !passphrase.isEmpty else { return nil }
        let salt: Data
        if let existing = AppSettings.cryptoSalt, let data = Data(base64Encoded: existing) {
            salt = data
        } else {
            var bytes = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            salt = Data(bytes)
            UserDefaults.standard.set(salt.base64EncodedString(), forKey: SettingKey.cryptoSalt)
        }
        return try? SyncCrypto(passphrase: passphrase, salt: salt)
    }

    static func backendFingerprint() -> String {
        let backend = AppSettings.storageBackend
        var identity: String
        if backend == "s3" {
            identity = "s3:\(AppSettings.s3Endpoint):\(AppSettings.s3Bucket)"
        } else {
            identity = "webdav:\(AppSettings.webDAVBaseURL):\(AppSettings.webDAVUsername)"
        }
        let digest = CryptoKit.SHA256.hash(data: Data(identity.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.prefix(8).joined()
    }

    private static func urlFromDefaults(key: String, fallback: String) -> URL {
        let raw = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: raw?.isEmpty == false ? raw! : fallback) ?? URL(string: fallback)!
    }
}
