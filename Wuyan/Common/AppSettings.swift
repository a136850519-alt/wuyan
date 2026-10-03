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
    /// 仅手动同步模式（默认关）：false 时禁用启动/唤醒/编辑防抖三处自动触发，只保留菜单 ⌘⇧S。
    static let syncAutoSyncEnabled = "settings.sync.autoSyncEnabled"

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

    // MARK: - 归档与同步
    // R2-6: 从 AppState/SyncCoordinator 硬编码提取到此
    static let archivedYears = "archive.years"
}

/// 类型化访问器：读 UserDefaults 时提供默认值，避免散落各处。
enum AppSettings {
    /// Q01：设置读取的 UserDefaults 实例。生产固定为 .standard；
    /// 测试通过 injectDefaultsForTesting 注入随机 suite，保证测试不会
    /// 读写/删除用户真实的偏好配置，也不依赖测试 runner 的默认域。
    private static var defaults: UserDefaults = .standard

    /// 仅测试目标可调用：注入隔离的 UserDefaults。
    /// 生产代码绝不能调用（调用后设置将不再持久化到用户偏好）。
    static func injectDefaultsForTesting(_ injected: UserDefaults) {
        defaults = injected
    }

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
    static var syncAutoSyncEnabled: Bool {
        defaults.bool(forKey: SettingKey.syncAutoSyncEnabled)
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
        // R2-7: trim 语义纳入访问器，替代 ProviderFactory.urlFromDefaults
        (defaults.string(forKey: SettingKey.zhipuEndpoint) ?? "https://open.bigmodel.cn/api/paas/v4")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var zhipuModel: String {
        defaults.string(forKey: SettingKey.zhipuModel) ?? "glm-5.2"
    }
    static var claudeEndpoint: String {
        // R2-7: trim 语义纳入访问器
        (defaults.string(forKey: SettingKey.claudeEndpoint) ?? "https://api.anthropic.com/v1/messages")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var claudeModel: String {
        defaults.string(forKey: SettingKey.claudeModel) ?? "claude-sonnet-5"
    }
    static var ollamaEndpoint: String {
        (defaults.string(forKey: SettingKey.ollamaEndpoint) ?? "http://localhost:11434")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// Q01：写入也必须走注入的 defaults，保证测试与生产共享同一条读写链路。
    static func setReminderTimes(_ times: [String]) {
        defaults.set(times, forKey: SettingKey.reminderTimes)
    }
    static var metadataEnabled: Bool {
        defaults.object(forKey: SettingKey.metadataEnabled) as? Bool ?? true
    }

    // MARK: - 加密
    static var cryptoEnabled: Bool {
        defaults.bool(forKey: SettingKey.cryptoEnabled)
    }
    static func setCryptoEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: SettingKey.cryptoEnabled)
    }
    static var cryptoSalt: String? {
        defaults.string(forKey: SettingKey.cryptoSalt)
    }

    // MARK: - 归档与同步
    // R2-6: 替代 AppState/SyncCoordinator 中的硬编码 "archive.years"
    static var archivedYears: [Int] {
        defaults.array(forKey: SettingKey.archivedYears) as? [Int] ?? []
    }
    static func setArchivedYears(_ years: [Int]) {
        defaults.set(years, forKey: SettingKey.archivedYears)
    }
}
