import Foundation

/// 设置 key 常量 + 类型化访问器（默认值单一来源）。
/// 视图可用 @AppStorage(SettingKey.xxx)；非视图代码用 AppSettings.xxx 读取。
enum SettingKey {
    // MARK: - 存储与同步
    static let storageBackend = "settings.storage.backend"
    static let webDAVBaseURL = "settings.webdav.baseURL"
    static let webDAVUsername = "settings.webdav.username"
    static let s3Endpoint = "settings.s3.endpoint"
    static let s3Region = "settings.s3.region"
    static let s3Bucket = "settings.s3.bucket"
    static let s3AccessKey = "settings.s3.accessKey"
    static let s3PathStyle = "settings.s3.pathStyle"

    // MARK: - AI
    static let aiEnabled = "settings.ai.enabled"
    static let aiRitual = "settings.ai.ritual"
    static let aiProvider = "settings.ai.provider"
    static let zhipuEndpoint = "settings.zhipu.endpoint"
    static let zhipuModel = "settings.zhipu.model"
    static let claudeEndpoint = "settings.claude.endpoint"
    static let claudeModel = "settings.claude.model"
    static let ollamaEndpoint = "settings.ollama.endpoint"
    static let ollamaModel = "settings.ollama.model"
    static let ollamaEmbeddingModel = "settings.ollama.embeddingModel"

    // MARK: - 外观
    static let appearanceBodyFont = "settings.appearance.bodyFont"

    // MARK: - 提醒与元数据
    static let reminderEnabled = "settings.reminder.enabled"
    static let reminderSkipWrittenDays = "settings.reminder.skipWrittenDays"
    static let reminderTimes = "settings.reminder.times"
    static let metadataEnabled = "settings.metadata.enabled"

    // MARK: - 加密
    static let cryptoEnabled = "settings.crypto.enabled"
    static let cryptoSalt = "settings.crypto.salt"
}

/// 类型化访问器：读 UserDefaults 时提供默认值，避免散落各处。
enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - 存储与同步
    static var storageBackend: String {
        defaults.string(forKey: SettingKey.storageBackend) ?? "webDAV"
    }
    static var webDAVBaseURL: String {
        defaults.string(forKey: SettingKey.webDAVBaseURL) ?? ""
    }
    static var webDAVUsername: String {
        defaults.string(forKey: SettingKey.webDAVUsername) ?? ""
    }
    static var s3Endpoint: String {
        defaults.string(forKey: SettingKey.s3Endpoint) ?? ""
    }
    static var s3Region: String {
        defaults.string(forKey: SettingKey.s3Region) ?? "us-east-1"
    }
    static var s3Bucket: String {
        defaults.string(forKey: SettingKey.s3Bucket) ?? ""
    }
    static var s3AccessKey: String {
        defaults.string(forKey: SettingKey.s3AccessKey) ?? ""
    }
    static var s3PathStyle: Bool {
        defaults.object(forKey: SettingKey.s3PathStyle) as? Bool ?? true
    }

    // MARK: - AI
    static var aiEnabled: Bool {
        defaults.bool(forKey: SettingKey.aiEnabled)
    }
    static var aiRitual: Bool {
        defaults.object(forKey: SettingKey.aiRitual) as? Bool ?? true
    }
    static var aiProvider: String {
        defaults.string(forKey: SettingKey.aiProvider) ?? "zhipu"
    }
    static var zhipuEndpoint: String {
        defaults.string(forKey: SettingKey.zhipuEndpoint) ?? "https://open.bigmodel.cn/api/paas/v4"
    }
    static var zhipuModel: String {
        defaults.string(forKey: SettingKey.zhipuModel) ?? "glm-5.2"
    }
    static var claudeEndpoint: String {
        defaults.string(forKey: SettingKey.claudeEndpoint) ?? "https://api.anthropic.com/v1/messages"
    }
    static var claudeModel: String {
        defaults.string(forKey: SettingKey.claudeModel) ?? "claude-sonnet-5"
    }
    static var ollamaEndpoint: String {
        defaults.string(forKey: SettingKey.ollamaEndpoint) ?? "http://localhost:11434"
    }
    static var ollamaModel: String {
        defaults.string(forKey: SettingKey.ollamaModel) ?? "qwen2.5"
    }
    static var ollamaEmbeddingModel: String {
        defaults.string(forKey: SettingKey.ollamaEmbeddingModel) ?? "nomic-embed-text"
    }

    // MARK: - 外观
    static var bodyFont: String {
        defaults.string(forKey: SettingKey.appearanceBodyFont) ?? "LXGWWenKai-Regular"
    }

    // MARK: - 提醒与元数据
    static var reminderEnabled: Bool {
        defaults.bool(forKey: SettingKey.reminderEnabled)
    }
    static var reminderSkipWrittenDays: Bool {
        defaults.object(forKey: SettingKey.reminderSkipWrittenDays) as? Bool ?? true
    }
    static var reminderTimes: [String] {
        defaults.array(forKey: SettingKey.reminderTimes) as? [String] ?? ["21:30"]
    }
    static var metadataEnabled: Bool {
        defaults.object(forKey: SettingKey.metadataEnabled) as? Bool ?? true
    }

    // MARK: - 加密
    static var cryptoEnabled: Bool {
        defaults.bool(forKey: SettingKey.cryptoEnabled)
    }
    static var cryptoSalt: String? {
        defaults.string(forKey: SettingKey.cryptoSalt)
    }
}
