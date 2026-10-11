import CryptoKit
import Foundation

/// 远端存储/AI/加密 的工厂方法：从 UserDefaults + Keychain 读取配置并构建 provider 实例。
enum ProviderFactory {
    /// C03：AI provider 工厂可注入。AppState 构造与 reloadAISettings 都会调用
    /// makeAIProvider()——默认智谱分支会经 SecureSettings.load 读取生产 Keychain。
    /// 测试注入后该链路被整体短路，不再触碰真实凭据；传 nil 恢复默认工厂。
    private static var aiProviderOverride: (@Sendable () -> AIProvider?)?

    /// 仅测试目标可调用：注入 AI provider 工厂（返回 nil 表示未配置 provider）。
    static func injectAIProviderForTesting(_ factory: (@Sendable () -> AIProvider?)?) {
        aiProviderOverride = factory
    }

    static func makeAIProvider() -> AIProvider? {
        if let aiProviderOverride {
            return aiProviderOverride()
        }
        let provider = AppSettings.aiProvider
        if provider == "zhipu" {
            // R2-7: 直接用 AppSettings（已含 trim），URL 化在此完成
            let endpoint = URL(string: AppSettings.zhipuEndpoint) ?? URL(string: "https://open.bigmodel.cn/api/paas/v4")!
            return ZhipuProvider(
                apiKey: SecureSettings.load(SecureSettingKey.zhipuAPIKey, legacyDefaultsKey: SecureSettingKey.zhipuAPIKey),
                model: AppSettings.zhipuModel,
                endpoint: endpoint
            )
        }
        if provider == "claude" {
            let endpoint = URL(string: AppSettings.claudeEndpoint) ?? URL(string: "https://api.anthropic.com/v1/messages")!
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
        guard !DevelopmentPreview.isEnabled else {
            throw RemoteStorageError.missingConfiguration("开发预览使用独立示例数据，云端同步未启用")
        }
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
        // Use the designated initializer. KDF work is deferred until a remote
        // header is actually unlocked (the compatibility convenience
        // initializer eagerly derives a legacy key).
        return SyncCrypto(
            passphrase: passphrase,
            persistenceKey: "sync.pendingCryptoHeader.\(backendFingerprint())"
        )
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
}
