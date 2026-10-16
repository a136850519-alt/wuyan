import SwiftUI
import OSLog

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    // Storage and AI controls are drafts. They are committed only by the
    // explicit save actions, so connection tests can safely use unsaved input.
    @State private var storageBackend = AppSettings.storageBackend
    @State private var webDAVBaseURL = AppSettings.webDAVBaseURL
    @State private var webDAVUsername = AppSettings.webDAVUsername
    @State private var s3Endpoint = AppSettings.s3Endpoint
    @State private var s3Region = AppSettings.s3Region
    @State private var s3Bucket = AppSettings.s3Bucket
    @State private var s3AccessKey = AppSettings.s3AccessKey
    @State private var s3PathStyle = AppSettings.s3PathStyle
    @State private var aiEnabled = AppSettings.aiEnabled
    @State private var ritualAI = AppSettings.aiRitual
    @State private var aiProvider = AppSettings.aiProvider
    @State private var zhipuEndpoint = AppSettings.zhipuEndpoint
    @State private var zhipuModel = AppSettings.zhipuModel
    @State private var claudeEndpoint = AppSettings.claudeEndpoint
    @State private var claudeModel = AppSettings.claudeModel
    @State private var ollamaEndpoint = AppSettings.ollamaEndpoint
    @State private var ollamaModel = AppSettings.ollamaModel
    @AppStorage(SettingKey.appearanceBodyFont) private var bodyFont = "LXGWWenKai-Regular"
    @AppStorage(SettingKey.reminderEnabled) private var reminderEnabled = false
    @AppStorage(SettingKey.reminderSkipWrittenDays) private var skipWrittenDays = true
    @AppStorage(SettingKey.metadataEnabled) private var metadataEnabled = true
    // UI-01（已确认）：加密开关不再即时生效，改为草稿状态、点「保存加密设置」才应用
    @State private var cryptoEnabledDraft = false
    @State private var showsDisableCryptoConfirm = false
    @State private var showsConflictList = false
    @State private var diaryPasswordSheetMode: DiaryPasswordSheetMode?
    @State private var diaryIdleTimeout = AppSettings.diaryIdleTimeoutMinutes
    @FocusState private var conflictEntryFocused: Bool
    @State private var pendingRestoreDirectory: URL?
    @State private var pendingJSONImportURL: URL?
    @State private var pendingEvictYear: Int?
    @State private var webDAVPassword = ""
    @State private var s3SecretKey = ""
    @State private var zhipuAPIKey = ""
    @State private var claudeAPIKey = ""
    @State private var reminderTimes: [Date] = []
    @State private var isTestingStorage = false
    @State private var isTestingAI = false
    @State private var unavailableSecureKeys: Set<String> = []
    @State private var cryptoPassphrase = ""
    @State private var cryptoConfirm = ""
    @State private var babyBirthday = Date()
    @State private var conflictSummaries: [UUID: EntrySummary] = [:]
    /// Each settings section owns its feedback lifecycle. Errors and active
    /// operations remain visible until the next meaningful state transition.
    @State private var statusMessages: [String: SectionStatusMessage] = [:]
    @State private var statusWorkItems: [String: DispatchWorkItem] = [:]
    @State private var aiConfigurationRevision = 0
    /// R1-1: 缓存媒体统计，避免 body 中每次重算
    @State private var mediaTotalSize: Int64 = 0
    @State private var mediaYearSizes: [Int: Int64] = [:]

    // R2-10: Section 名称常量
    private enum StatusSection {
        static let storage = "storage"
        static let ai = "ai"
        static let reminder = "reminder"
        static let baby = "baby"
        static let export = "export"
        static let crypto = "crypto"
        static let media = "media"
        static let diag = "diag"
    }

    private enum StatusSeverity {
        case error, processing, warning, info, success

        var icon: String {
            switch self {
            case .error: return "exclamationmark.triangle.fill"
            case .processing: return "arrow.triangle.2.circlepath"
            case .warning: return "exclamationmark.circle"
            case .info: return "info.circle"
            case .success: return "checkmark.circle"
            }
        }

        var color: Color {
            switch self {
            case .error: return Palette.adaptive(light: "#A23F35", dark: "#F0A39B")
            case .processing: return Palette.muted
            case .warning: return Palette.adaptive(light: "#A17B3C", dark: "#DFBF7D")
            case .info: return Palette.muted
            case .success: return Palette.adaptive(light: "#416857", dark: "#A7C4A3")
            }
        }
    }

    private struct SectionStatusMessage: Identifiable {
        let id = UUID()
        let section: String
        let text: String
        let severity: StatusSeverity
    }

    var body: some View {
        Form {
            Section("存储与同步") {
                Picker("存储后端", selection: $storageBackend) {
                    Text("WebDAV").tag("webDAV")
                    Text("S3 / MinIO").tag("s3")
                }
                .pickerStyle(.segmented)

                if storageBackend == "s3" {
                    TextField("Endpoint", text: $s3Endpoint)
                    TextField("Region", text: $s3Region)
                    TextField("Bucket", text: $s3Bucket)
                    TextField("Access Key", text: $s3AccessKey)
                    SecureField("Secret Key", text: $s3SecretKey)
                    Toggle("Path-style URL", isOn: $s3PathStyle)
                        .tint(Palette.cinnabar)
                } else {
                    TextField("WebDAV 地址", text: $webDAVBaseURL)
                    TextField("账号", text: $webDAVUsername)
                    SecureField("密码", text: $webDAVPassword)
                }

                Button("保存存储配置") {
                    saveStorageSettings()
                }
                Button {
                    testStorage()
                } label: {
                    if isTestingStorage {
                        Label("正在测试", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Text("测试连接")
                    }
                }
                .disabled(isTestingStorage)
                Text("测试连接只发送一条简短探测请求，不发送日记正文。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button {
                    appState.syncNow()
                } label: {
                    if appState.syncProgress != nil {
                        Label("正在同步", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Text("立即同步")
                    }
                }
                .disabled(appState.syncProgress != nil)
                if let progress = appState.syncProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress.fractionCompleted)
                        HStack {
                            Text(progress.phase)
                            Spacer()
                            Text("\(progress.completedUnitCount)/\(progress.totalUnitCount) · \(progress.percentageText)")
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let detail = progress.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if let syncMessage = appState.syncMessage {
                    Text(syncMessage)
                        .foregroundStyle(.secondary)
                }
                // R2-10: 统一消息展示
                sectionStatus(for: StatusSection.storage)

                if !appState.syncConflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("检测到 \(appState.syncConflicts.count) 个同步冲突", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Palette.cinnabar)
                        ForEach(appState.syncConflicts, id: \.self) { id in
                            Button {
                                appState.selectedEntryId = id
                                appState.sidebarSelection = .all
                            } label: {
                                if let summary = conflictSummaries[id] {
                                    let dateStr = summary.dayDate
                                    let titleText = summary.title?.isEmpty == false ? summary.title! : String(summary.bodyPreview.prefix(30))
                                    Text("\(dateStr) · \(titleText)")
                                } else {
                                    Text(id.uuidString.prefix(8) + "…")
                                }
                            }
                            .buttonStyle(.link)
                        }
                        Text("冲突副本保存在 NAS 的 /Wuyan/entries/conflicts/ 目录下，并已留档本地。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Button("冲突列表（查看本地留档副本并恢复）") {
                    showsConflictList = true
                }
                .focused($conflictEntryFocused)
            }

            Section("日记密码") {
                if appState.isDiaryPasswordEnabled {
                    Label("日记密码已启用", systemImage: "lock.fill")
                        .foregroundStyle(Palette.cinnabar)
                    Picker("静置多久后锁定", selection: $diaryIdleTimeout) {
                        Text("1 分钟").tag(1)
                        Text("5 分钟").tag(5)
                        Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30)
                        Text("60 分钟").tag(60)
                        Text("不自动锁定").tag(0)
                    }
                    .onChange(of: diaryIdleTimeout) { _, value in
                        appState.updateDiaryIdleTimeout(minutes: value)
                    }
                    Button("立即锁定") { appState.lockDiary() }
                    Button("修改密码") { diaryPasswordSheetMode = .change }
                    Button("关闭日记密码", role: .destructive) { diaryPasswordSheetMode = .disable }
                    Text("重启、睡眠或系统锁屏后会立即要求解锁。锁定只保护晤言界面，不会回收已导出的外部文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("设置日记密码") { diaryPasswordSheetMode = .enable }
                    Text("密码只对当前 Mac 生效，至少 8 个字符，使用系统钥匙串保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("AI 辅助") {
                WuyanCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("隐私门控", systemImage: "lock.shield")
                            .foregroundStyle(Palette.cinnabar)
                        Text("本地 Ollama 不发送日记内容。使用云端智谱或 Claude 时，每次 AI 动作都应确认发送范围。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("启用 AI", isOn: $aiEnabled)
                    .tint(Palette.cinnabar)
                Toggle("仪式 AI 润色", isOn: $ritualAI)
                    .tint(Palette.cinnabar)
                Picker("Provider", selection: $aiProvider) {
                    Text("云端智谱").tag("zhipu")
                    Text("本地 Ollama").tag("ollama")
                    Text("云端 Claude").tag("claude")
                }
                if aiProvider == "zhipu" {
                    TextField("智谱 Base URL", text: $zhipuEndpoint)
                    TextField("智谱模型", text: $zhipuModel)
                    HStack {
                        SecureField("智谱 API Key", text: $zhipuAPIKey)
                        Button("移除") { removeAPIKey(SecureSettingKey.zhipuAPIKey, service: "智谱") }
                            .buttonStyle(.link)
                    }
                } else if aiProvider == "claude" {
                    TextField("Claude URL", text: $claudeEndpoint)
                    TextField("Claude 模型", text: $claudeModel, prompt: Text("如 claude-sonnet-5、claude-opus-5"))
                    HStack {
                        SecureField("Claude API Key", text: $claudeAPIKey)
                        Button("移除") { removeAPIKey(SecureSettingKey.claudeAPIKey, service: "Claude") }
                            .buttonStyle(.link)
                    }
                } else {
                    TextField("Ollama URL", text: $ollamaEndpoint)
                    TextField("Ollama 模型", text: $ollamaModel)
                }
                Button("保存 AI 配置") {
                    saveAISettings()
                }
                Button {
                    checkAIHealth()
                } label: {
                    if isTestingAI {
                        Label("正在测试", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Text("测试连接")
                    }
                }
                .disabled(isTestingAI)
                Text("测试连接只发送一条简短测试请求，不发送日记正文。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                sectionStatus(for: StatusSection.ai)
                Text("云端模式会在发送日记内容前提示发送范围。自动采集位置与天气时，会把约 3km 精度的坐标发送给 Apple 地理编码和 Open-Meteo。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("提醒与元数据") {
                Toggle("每日提醒", isOn: $reminderEnabled)
                    .tint(Palette.cinnabar)
                    .onChange(of: reminderEnabled) { _, enabled in
                        guard !enabled else { return }
                        Task { await ReminderScheduler().cancelAll() }
                    }
                ForEach(reminderTimes.indices, id: \.self) { index in
                    HStack {
                        DatePicker("提醒 \(index + 1)", selection: $reminderTimes[index], displayedComponents: .hourAndMinute)
                        Button {
                            reminderTimes.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(reminderTimes.count == 1)
                    }
                }
                Button {
                    reminderTimes.append(Date())
                } label: {
                    Label("添加提醒时间", systemImage: "plus.circle")
                }
                Button("保存提醒") { saveReminder() }
                Toggle("已记录则不提醒", isOn: $skipWrittenDays)
                    .tint(Palette.cinnabar)
                Toggle("自动采集位置与天气", isOn: $metadataEnabled)
                    .tint(Palette.cinnabar)
                sectionStatus(for: StatusSection.reminder)
                Text("天气使用无需 API Key 的 Open-Meteo；授权失败不会影响写作。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("宝贝成长") {
                DatePicker("宝贝生日", selection: $babyBirthday, displayedComponents: .date)
                Button("保存宝贝生日") {
                    saveBabyBirthday()
                }
                if let ageText = growthBoard()?.ageText(on: Date()) {
                    Text("当前年龄：\(ageText)")
                        .foregroundStyle(.secondary)
                }
                sectionStatus(for: StatusSection.baby)
            }

            Section("外观") {
                Picker("正文字体", selection: $bodyFont) {
                    Text("霞鹜文楷").tag("LXGWWenKai-Regular")
                    Text("系统衬线").tag("serif")
                }
                .pickerStyle(.segmented)
            }

            Section("导出与备份") {
                // UI-03（已确认）：完整备份与阅读导出分离
                Button("创建完整备份（含媒体文件，可独立恢复）") {
                    exportFullBackup()
                }
                .disabled(appState.isBackupTaskRunning)
                Button("从完整备份还原…") {
                    pickFullBackupForRestore()
                }
                .disabled(appState.isBackupTaskRunning)
                Divider()
                Button("导出 Markdown / JSON / PDF（阅读用）") {
                    exportAll()
                }
                .disabled(appState.isBackupTaskRunning)
                Button("从 JSON 备份还原（旧格式）") {
                    importJSONBackup()
                }
                .disabled(appState.isBackupTaskRunning)
                if appState.isBackupTaskRunning {
                    ProgressView("正在处理备份…")
                }
                sectionStatus(for: StatusSection.export)
            }

            Section("加密") {
                Toggle("远端同步加密（点保存后生效）", isOn: $cryptoEnabledDraft)
                    .tint(Palette.cinnabar)
                SecureField("同步加密口令", text: $cryptoPassphrase)
                SecureField("再次输入口令", text: $cryptoConfirm)
                Button("保存加密设置") {
                    saveCryptoSettings()
                }
                sectionStatus(for: StatusSection.crypto)
                if AppSettings.cryptoEnabled {
                    // UI-01（已确认）：数据密钥协议说明
                    Text("加密已启用（数据密钥协议）。更换口令只重新包装数据密钥，秒级完成、数据无需重传；关闭加密会把远端全部数据迁移为明文。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("日记数据由随机数据密钥加密，口令只负责保护该密钥；丢失口令仍无法解密。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .confirmationDialog("关闭加密并迁移远端为明文？", isPresented: $showsDisableCryptoConfirm) {
                Button("关闭加密并迁移", role: .destructive) {
                    cryptoEnabledDraft = false
                    setStatus(StatusSection.crypto, "正在迁移远端数据为明文…")
                    appState.syncCoordinator.disableEncryptionMigration { message in
                        setStatus(StatusSection.crypto, message)
                    }
                }
                Button("取消", role: .cancel) {
                    cryptoEnabledDraft = AppSettings.cryptoEnabled
                }
            } message: {
                Text("将把远端全部加密对象下载并以明文重传，耗时取决于数据量；迁移失败时加密配置保持不变。期间请保持网络连接。")
            }

            Section("媒体磁盘") {
                Text("本地媒体总大小：\(ByteCountFormatter.string(fromByteCount: mediaTotalSize, countStyle: .file))")
                    .foregroundStyle(.secondary)
                if !mediaYearSizes.isEmpty {
                    ForEach(mediaYearSizes.keys.sorted().reversed(), id: \.self) { year in
                        HStack {
                            Text("\(year) 年")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: mediaYearSizes[year] ?? 0, countStyle: .file))
                                .foregroundStyle(.secondary)
                            Button("清理本地") {
                                pendingEvictYear = year
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Palette.cinnabar)
                        }
                    }
                }
                sectionStatus(for: StatusSection.media)
                Text("清理仅删除已上传远端的本地副本，远端数据不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                Text("晤言 · Wuyan")
                    .font(WuyanFont.body(18))
                Text("本地优先的私有日记。")
                    .foregroundStyle(.secondary)
                Text("朱砂 #D85A30 · 霞鹜文楷")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("导出诊断日志") {
                    exportDiagnosticLog()
                }
                sectionStatus(for: StatusSection.diag)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .onAppear {
            loadSecureSettings()
            cryptoEnabledDraft = AppSettings.cryptoEnabled
            loadBabyBirthday()
            if reminderTimes.isEmpty {
                reminderTimes = AppState.reminderDatesFromDefaults()
                if reminderTimes.isEmpty {
                    reminderTimes = [Date()]
                }
            }

            loadConflictSummaries()
            // R1-1: 延迟加载媒体统计，不阻塞首屏
            loadMediaStats()
        }
        .onChange(of: appState.syncConflicts) {
            loadConflictSummaries()
        }
        .confirmationDialog("还原策略", isPresented: Binding(
            get: { pendingRestoreDirectory != nil },
            set: { if !$0 { pendingRestoreDirectory = nil } }
        )) {
            Button("覆盖同 ID 条目（以备份为准）", role: .destructive) {
                runRestore(.overwrite)
            }
            Button("跳过已存在的条目") {
                runRestore(.skipExisting)
            }
            Button("取消", role: .cancel) {
                pendingRestoreDirectory = nil
            }
        } message: {
            Text("还原前会自动快照当前数据库；备份包校验失败时原库不变。")
        }
        .confirmationDialog("导入旧格式 JSON？", isPresented: Binding(
            get: { pendingJSONImportURL != nil },
            set: { if !$0 { pendingJSONImportURL = nil } }
        )) {
            Button("导入并覆盖同 ID 条目", role: .destructive) {
                runJSONImport()
            }
            Button("取消", role: .cancel) { pendingJSONImportURL = nil }
        } message: {
            Text("导入前会创建数据库快照；导入条目会标记为待同步，可能覆盖其它设备的版本。")
        }
        .confirmationDialog("清理本地媒体？", isPresented: Binding(
            get: { pendingEvictYear != nil },
            set: { if !$0 { pendingEvictYear = nil } }
        )) {
            Button("清理并保留远端副本", role: .destructive) {
                if let year = pendingEvictYear {
                    pendingEvictYear = nil
                    evictYearMedia(year: year)
                }
            }
            Button("取消", role: .cancel) { pendingEvictYear = nil }
        } message: {
            if let year = pendingEvictYear {
                let bytes = mediaYearSizes[year] ?? 0
                Text("将检查远端副本后清理 \(year) 年本地媒体，预计释放 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))。远端不存在的文件会保留。")
            }
        }
        .sheet(isPresented: $showsConflictList, onDismiss: { conflictEntryFocused = true }) {
            ConflictListView()
                .environmentObject(appState)
        }
        .sheet(item: $diaryPasswordSheetMode) { mode in
            DiaryPasswordSheet(mode: mode)
                .environmentObject(appState)
        }
    }

    // MARK: - R2-10: 统一消息

    /// 显示某个 Section 的状态消息（如果有）
    @ViewBuilder
    private func sectionStatus(for section: String) -> some View {
        if let msg = statusMessages[section] {
            Label(msg.text, systemImage: msg.severity.icon)
                .foregroundStyle(msg.severity.color)
                .symbolEffect(.pulse, isActive: msg.severity == .processing)
                .textSelection(.enabled)
        }
    }

    private func setStatus(_ section: String, _ text: String, severity explicitSeverity: StatusSeverity? = nil) {
        let severity = explicitSeverity ?? inferSeverity(text)
        statusWorkItems[section]?.cancel()
        let message = SectionStatusMessage(section: section, text: text, severity: severity)
        statusMessages[section] = message

        let duration: TimeInterval?
        switch severity {
        case .error, .processing: duration = nil
        case .warning: duration = 8
        case .info: duration = 6
        case .success: duration = 4
        }
        guard let duration else { return }
        let id = message.id
        let work = DispatchWorkItem {
            Task { @MainActor in
                guard self.statusMessages[section]?.id == id else { return }
                self.statusMessages[section] = nil
                self.statusWorkItems[section] = nil
            }
        }
        statusWorkItems[section] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// 清除某个 Section 的状态消息
    private func clearStatus(_ section: String) {
        statusWorkItems[section]?.cancel()
        statusWorkItems[section] = nil
        statusMessages[section] = nil
    }

    private func inferSeverity(_ text: String) -> StatusSeverity {
        if text.contains("正在") || text.contains("处理中") || text.contains("迁移中") { return .processing }
        if text.contains("失败") || text.contains("错误") || text.contains("无法") || text.contains("未") || text.contains("不") || text.contains("拒绝") || text.contains("超时") || text.contains("异常") || text.contains("缺少") || text.contains("无效") {
            return .error
        }
        if text.contains("部分") || text.contains("跳过") || text.contains("提示") { return .warning }
        if text.contains("成功") || text.contains("已保存") || text.contains("已完成") || text.contains("已创建") || text.contains("已导出") || text.contains("已还原") || text.contains("已清理") || text.contains("已关闭") { return .success }
        return .info
    }

    private func setStatus(_ section: String, _ text: String) {
        setStatus(section, text, severity: nil)
    }

    // MARK: - 数据加载

    private func loadSecureSettings() {
        unavailableSecureKeys.removeAll()
        webDAVPassword = loadSecureValue(SecureSettingKey.webDAVPassword)
        s3SecretKey = loadSecureValue(SecureSettingKey.s3SecretKey)
        zhipuAPIKey = loadSecureValue(SecureSettingKey.zhipuAPIKey)
        claudeAPIKey = loadSecureValue(SecureSettingKey.claudeAPIKey)
        cryptoPassphrase = SecureSettings.load(SecureSettingKey.syncPassphrase, legacyDefaultsKey: SecureSettingKey.legacySyncPassphrase)
        diaryIdleTimeout = AppSettings.diaryIdleTimeoutMinutes
        if unavailableSecureKeys.contains(SecureSettingKey.zhipuAPIKey) || unavailableSecureKeys.contains(SecureSettingKey.claudeAPIKey) {
            setStatus(StatusSection.ai, "无法读取已保存的 API Key，请重试读取。", severity: .error)
        }
    }

    private func loadSecureValue(_ key: String) -> String {
        switch SecureSettings.readResult(key) {
        case let .value(value):
            return value
        case .missing:
            return SecureSettings.load(key, legacyDefaultsKey: key)
        case .unavailable:
            unavailableSecureKeys.insert(key)
            return ""
        }
    }

    private func loadBabyBirthday() {
        if let board = growthBoard(), let birthday = board.babyBirthday {
            babyBirthday = birthday
        }
    }

    private func removeAPIKey(_ key: String, service: String) {
        guard SecureSettings.save("", for: key, legacyDefaultsKey: key) else {
            setStatus(StatusSection.ai, "\(service) API Key 未能移除，请重试。", severity: .error)
            return
        }
        if key == SecureSettingKey.zhipuAPIKey { zhipuAPIKey = "" }
        if key == SecureSettingKey.claudeAPIKey { claudeAPIKey = "" }
        aiConfigurationRevision += 1
        setStatus(StatusSection.ai, "已移除 \(service) API Key。", severity: .warning)
    }

    private func testStorage() {
        guard !isTestingStorage else { return }
        guard let provider = draftStorageProvider() else { return }
        setStatus(StatusSection.storage, "正在测试连接…")
        isTestingStorage = true
        Task {
            do {
                try await provider.testConnection()
                await MainActor.run {
                    setStatus(StatusSection.storage, "连接成功，已完成读写探测。")
                    isTestingStorage = false
                }
            } catch {
                await MainActor.run {
                    setStatus(StatusSection.storage, error.localizedDescription)
                    isTestingStorage = false
                }
            }
        }
    }

    private func draftStorageProvider() -> (any RemoteStorageProvider)? {
        do {
            if storageBackend == "s3" {
                guard let endpoint = URL(string: s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
                      endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
                    setStatus(StatusSection.storage, "S3 Endpoint 无效，请填写完整的 HTTPS 地址。", severity: .error); return nil
                }
                guard !s3Region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    setStatus(StatusSection.storage, "尚未填写 S3 Region。", severity: .error); return nil
                }
                guard !s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    setStatus(StatusSection.storage, "尚未填写 S3 Bucket。", severity: .error); return nil
                }
                let secret = s3SecretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? SecureSettings.load(SecureSettingKey.s3SecretKey, legacyDefaultsKey: SecureSettingKey.s3SecretKey)
                    : s3SecretKey
                guard !s3AccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !secret.isEmpty else {
                    setStatus(StatusSection.storage, "请填写 S3 Access Key 和 Secret Key。", severity: .error); return nil
                }
                return S3Provider(endpoint: endpoint, bucket: s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines), region: s3Region.trimmingCharacters(in: .whitespacesAndNewlines), accessKey: s3AccessKey.trimmingCharacters(in: .whitespacesAndNewlines), secretKey: secret, pathStyle: s3PathStyle)
            }
            let value = webDAVBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
                setStatus(StatusSection.storage, "WebDAV 地址无效，请填写完整的 HTTP(S) 地址。", severity: .error); return nil
            }
            let password = webDAVPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? SecureSettings.load(SecureSettingKey.webDAVPassword, legacyDefaultsKey: SecureSettingKey.webDAVPassword)
                : webDAVPassword
            guard !webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
                setStatus(StatusSection.storage, "请填写 WebDAV 账号和密码。", severity: .error); return nil
            }
            return WebDAVProvider(baseURL: url, username: webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        }
    }

    @discardableResult
    private func saveStorageSettings(showMessage: Bool = true) -> Bool {
        webDAVBaseURL = webDAVBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        webDAVUsername = webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        s3Endpoint = s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        s3Region = s3Region.trimmingCharacters(in: .whitespacesAndNewlines)
        s3Bucket = s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        s3AccessKey = s3AccessKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if storageBackend == "s3" {
            guard let endpoint = URL(string: s3Endpoint), endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
                setStatus(StatusSection.storage, "S3 Endpoint 无效，请填写完整的 HTTPS 地址。", severity: .error); return false
            }
            guard !s3Region.isEmpty else { setStatus(StatusSection.storage, "尚未填写 S3 Region。", severity: .error); return false }
            guard !s3Bucket.isEmpty else { setStatus(StatusSection.storage, "尚未填写 S3 Bucket。", severity: .error); return false }
        } else {
            guard let url = URL(string: webDAVBaseURL), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
                setStatus(StatusSection.storage, "WebDAV 地址无效，请填写完整的 HTTP(S) 地址。", severity: .error); return false
            }
            guard !webDAVUsername.isEmpty else { setStatus(StatusSection.storage, "尚未填写 WebDAV 账号。", severity: .error); return false }
        }

        if storageBackend == "s3" {
            if !s3SecretKey.isEmpty, !SecureSettings.save(s3SecretKey, for: SecureSettingKey.s3SecretKey, legacyDefaultsKey: SecureSettingKey.s3SecretKey) {
                setStatus(StatusSection.storage, "Secret Key 未能保存，请重试。", severity: .error); return false
            }
        } else {
            if !webDAVPassword.isEmpty, !SecureSettings.save(webDAVPassword, for: SecureSettingKey.webDAVPassword, legacyDefaultsKey: SecureSettingKey.webDAVPassword) {
                setStatus(StatusSection.storage, "WebDAV 密码未能保存，请重试。", severity: .error); return false
            }
            if let url = URL(string: webDAVBaseURL), url.scheme?.lowercased() == "http",
               let host = url.host?.lowercased(),
               host != "localhost", host != "127.0.0.1", host != "::1",
               !host.hasPrefix("192.168."), !host.hasPrefix("10."),
               !(host.split(separator: ".").count == 4 && Int(host.split(separator: ".")[0]) == 172 && (16...31).contains(Int(host.split(separator: ".")[1]) ?? -1)) {
                setStatus(StatusSection.storage, "WebDAV 使用明文 HTTP，已拒绝保存非局域网地址。请改用 HTTPS。")
                return false
            }
        }

        if showMessage {
            AppSettings.setString(storageBackend, for: SettingKey.storageBackend)
            AppSettings.setString(webDAVBaseURL, for: SettingKey.webDAVBaseURL)
            AppSettings.setString(webDAVUsername, for: SettingKey.webDAVUsername)
            AppSettings.setString(s3Endpoint, for: SettingKey.s3Endpoint)
            AppSettings.setString(s3Region, for: SettingKey.s3Region)
            AppSettings.setString(s3Bucket, for: SettingKey.s3Bucket)
            AppSettings.setString(s3AccessKey, for: SettingKey.s3AccessKey)
            AppSettings.setBool(s3PathStyle, for: SettingKey.s3PathStyle)
            setStatus(StatusSection.storage, "存储配置已保存。")
        }
        return true
    }

    private func exportAll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let directory = panel.url {
            appState.isBackupTaskRunning = true
            let database = appState.db
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result {
                        let entries = try database.entryDAO.timeline(filter: .all)
                        let service = ExportService()
                        try service.exportMarkdown(entries: entries, mediaDAO: database.mediaAssetDAO, dayNotes: database.dayNoteDAO, to: directory.appendingPathComponent("Markdown", isDirectory: true))
                        try service.exportJSON(entries: entries, to: directory.appendingPathComponent("wuyan-entries.json"))
                        try service.exportPDF(entries: entries, to: directory.appendingPathComponent("wuyan-export.pdf"))
                        return entries.count
                    }
                }.value
                appState.isBackupTaskRunning = false
                switch result {
                case let .success(count): setStatus(StatusSection.export, "已导出 \(count) 篇。")
                case let .failure(error): setStatus(StatusSection.export, error.localizedDescription)
                }
            }
        }
    }

    private func importJSONBackup() {
        guard !appState.isRescueMode else {
            setStatus(StatusSection.export, "救援模式：还原已禁用。")
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { pendingJSONImportURL = url }
    }

    private func runJSONImport() {
        guard let url = pendingJSONImportURL else { return }
        pendingJSONImportURL = nil
        appState.isBackupTaskRunning = true
        let database = appState.db
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ExportService().importJSON(from: url, database: database) }
            }.value
            appState.isBackupTaskRunning = false
            switch result {
            case let .success(count): setStatus(StatusSection.export, "已还原 \(count) 篇。")
            case let .failure(error): setStatus(StatusSection.export, error.localizedDescription)
            }
        }
    }

    // MARK: - UI-03：完整备份

    private func exportFullBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择备份位置"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let target = directory.appendingPathComponent("晤言完整备份-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        appState.isBackupTaskRunning = true
        let database = appState.db
        let archived = appState.archivedYears
        if !archived.isEmpty {
            setStatus(StatusSection.export, "提示：完整备份不包含已归档年份 \(archived.sorted().map(String.init).joined(separator: "、")) 的远端内容。")
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ExportService().exportFullBackupPackage(database: database, to: target) }
            }.value
            appState.isBackupTaskRunning = false
            switch result {
            case let .success(count): setStatus(StatusSection.export, "完整备份已创建（\(count) 篇，含媒体文件）：\(target.lastPathComponent)")
            case let .failure(error): setStatus(StatusSection.export, error.localizedDescription)
            }
        }
    }

    private func pickFullBackupForRestore() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择备份包目录"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        pendingRestoreDirectory = directory
    }

    private func runRestore(_ strategy: ImportConflictStrategy) {
        guard !appState.isRescueMode else {
            setStatus(StatusSection.export, "救援模式：还原已禁用。")
            return
        }
        guard let directory = pendingRestoreDirectory else { return }
        pendingRestoreDirectory = nil
        appState.isBackupTaskRunning = true
        let database = appState.db
        let mediaStore = appState.mediaStore
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try ExportService().importFullBackupPackage(from: directory, database: database, mediaStore: mediaStore, strategy: strategy)
                }
            }.value
            appState.isBackupTaskRunning = false
            switch result {
            case let .success(report):
                setStatus(StatusSection.export, "已导入 \(report.importedEntries) 篇（跳过已存在 \(report.skippedEntries) 篇），恢复媒体 \(report.restoredMediaFiles) 个，缺失本地副本 \(report.missingLocalCopies) 个（可从远端补）。还原前快照：\(report.snapshotURL.lastPathComponent)")
            case let .failure(error): setStatus(StatusSection.export, error.localizedDescription)
            }
        }
    }

    private func saveReminder() {
        Task {
            let scheduler = ReminderScheduler()
            if !reminderEnabled {
                await scheduler.cancelAll()
                AppState.saveReminderTimesToDefaults(reminderTimes)
                await MainActor.run {
                    appState.refreshRemindersForToday(force: true)
                    setStatus(StatusSection.reminder, "提醒已关闭。", severity: .success)
                }
                return
            }
            guard await scheduler.requestAuthorization() else {
                await MainActor.run { setStatus(StatusSection.reminder, "通知授权未开启，提醒未保存。", severity: .error) }
                return
            }
            AppState.saveReminderTimesToDefaults(reminderTimes)
            let components = reminderTimes.map { Calendar.current.dateComponents([.hour, .minute], from: $0) }
            await scheduler.setDailyReminders(components)
            await MainActor.run {
                appState.refreshRemindersForToday(force: true)
                setStatus(StatusSection.reminder, "已保存 \(components.count) 个提醒。", severity: .success)
            }
        }
    }

    private func growthBoard() -> Board? {
        (try? appState.boards.all())?.first { $0.kind == .growth }
    }

    private func saveBabyBirthday() {
        guard !appState.isRescueMode else {
            setStatus(StatusSection.baby, "救援模式：设置修改已禁用。")
            return
        }
        do {
            guard let board = growthBoard() else {
                setStatus(StatusSection.baby, "没有找到宝贝成长记录板块。")
                return
            }
            let updated = Board(
                id: board.id,
                name: board.name,
                colorHex: board.colorHex,
                iconName: board.iconName,
                kind: .growth,
                babyBirthday: babyBirthday,
                disallowCloudAI: board.disallowCloudAI,
                sortOrder: board.sortOrder,
                createdAt: board.createdAt
            )
            try appState.boards.save(updated)
            appState.syncCoordinator.notifyEditCompleted()
            setStatus(StatusSection.baby, "宝贝生日已保存。")
        } catch {
            setStatus(StatusSection.baby, error.localizedDescription)
        }
    }

    private func checkAIHealth() {
        guard aiEnabled else {
            setStatus(StatusSection.ai, "AI 已关闭，请先启用。", severity: .error)
            return
        }
        guard let provider = draftAIProvider() else { return }
        let revision = aiConfigurationRevision
        setStatus(StatusSection.ai, "正在测试连接…")
        isTestingAI = true
        Task {
            do {
                let result = try await provider.complete([
                    AIMessage(role: .system, content: "只回复 OK。"),
                    AIMessage(role: .user, content: "ping")
                ], options: AIOptions(temperature: 0, maxTokens: 8))
                await MainActor.run {
                    guard revision == aiConfigurationRevision else { return }
                    setStatus(StatusSection.ai, result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "连接成功。" : "连接成功：\(result)")
                    isTestingAI = false
                }
            } catch {
                await MainActor.run {
                    guard revision == aiConfigurationRevision else { return }
                    setStatus(StatusSection.ai, error.localizedDescription)
                    isTestingAI = false
                }
            }
        }
    }

    @discardableResult
    private func saveAISettings(showMessage: Bool = true) -> Bool {
        zhipuAPIKey = zhipuAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeAPIKey = claudeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        zhipuEndpoint = zhipuEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        zhipuModel = zhipuModel.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeEndpoint = claudeEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeModel = claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        ollamaEndpoint = ollamaEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        ollamaModel = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)

        if aiEnabled {
            if aiProvider == "ollama" {
                guard !ollamaModel.isEmpty else {
                    setStatus(StatusSection.ai, "尚未填写 Ollama 模型名称。", severity: .error)
                    return false
                }
                guard (try? ProviderFactory.validateHTTPURL(ollamaEndpoint, service: "Ollama")) != nil else {
                    setStatus(StatusSection.ai, "Ollama 服务地址无效，请填写完整的 HTTP(S) 地址。", severity: .error)
                    return false
                }
            } else if aiProvider == "zhipu" {
                guard !zhipuModel.isEmpty else {
                    setStatus(StatusSection.ai, "尚未填写智谱模型名称。", severity: .error); return false
                }
                guard (try? ProviderFactory.validateHTTPURL(zhipuEndpoint, service: "智谱")) != nil else {
                    setStatus(StatusSection.ai, "智谱服务地址无效，请填写完整的 HTTP(S) 地址。", severity: .error); return false
                }
            } else if aiProvider == "claude" {
                guard !claudeModel.isEmpty else {
                    setStatus(StatusSection.ai, "尚未填写 Claude 模型名称。", severity: .error); return false
                }
                guard (try? ProviderFactory.validateHTTPURL(claudeEndpoint, service: "Claude")) != nil else {
                    setStatus(StatusSection.ai, "Claude 服务地址无效，请填写完整的 HTTP(S) 地址。", severity: .error); return false
                }
            }
        }

        switch aiProvider {
        case "zhipu":
            if !zhipuAPIKey.isEmpty {
                guard SecureSettings.save(zhipuAPIKey, for: SecureSettingKey.zhipuAPIKey, legacyDefaultsKey: SecureSettingKey.zhipuAPIKey) else {
                    setStatus(StatusSection.ai, "智谱 API Key 未能保存，请重试。", severity: .error)
                    return false
                }
            } else if aiEnabled {
                if unavailableSecureKeys.contains(SecureSettingKey.zhipuAPIKey) {
                    setStatus(StatusSection.ai, "无法读取已保存的智谱 API Key，请重试读取。", severity: .error)
                    return false
                }
                if SecureSettings.load(SecureSettingKey.zhipuAPIKey, legacyDefaultsKey: SecureSettingKey.zhipuAPIKey).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    setStatus(StatusSection.ai, "尚未填写智谱 API Key。", severity: .error)
                    return false
                }
            }
        case "claude":
            if !claudeAPIKey.isEmpty {
                guard SecureSettings.save(claudeAPIKey, for: SecureSettingKey.claudeAPIKey, legacyDefaultsKey: SecureSettingKey.claudeAPIKey) else {
                    setStatus(StatusSection.ai, "Claude API Key 未能保存，请重试。", severity: .error)
                    return false
                }
            } else if aiEnabled {
                if unavailableSecureKeys.contains(SecureSettingKey.claudeAPIKey) {
                    setStatus(StatusSection.ai, "无法读取已保存的 Claude API Key，请重试读取。", severity: .error)
                    return false
                }
                if SecureSettings.load(SecureSettingKey.claudeAPIKey, legacyDefaultsKey: SecureSettingKey.claudeAPIKey).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    setStatus(StatusSection.ai, "尚未填写 Claude API Key。", severity: .error)
                    return false
                }
            }
        default:
            break
        }
        AppSettings.setBool(aiEnabled, for: SettingKey.aiEnabled)
        AppSettings.setBool(ritualAI, for: SettingKey.aiRitual)
        AppSettings.setString(aiProvider, for: SettingKey.aiProvider)
        AppSettings.setString(zhipuEndpoint, for: SettingKey.zhipuEndpoint)
        AppSettings.setString(zhipuModel, for: SettingKey.zhipuModel)
        AppSettings.setString(claudeEndpoint, for: SettingKey.claudeEndpoint)
        AppSettings.setString(claudeModel, for: SettingKey.claudeModel)
        AppSettings.setString(ollamaEndpoint, for: SettingKey.ollamaEndpoint)
        AppSettings.setString(ollamaModel, for: SettingKey.ollamaModel)
        appState.reloadAISettings()
        aiConfigurationRevision += 1

        if showMessage {
            setStatus(StatusSection.ai, "AI 配置已保存。")
        }
        return true
    }

    /// Build a provider from the visible draft. This keeps the connection test
    /// read-only: a failed test never overwrites the last working credentials.
    private func draftAIProvider() -> AIProvider? {
        do {
            switch aiProvider {
            case "zhipu":
                guard !zhipuModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    setStatus(StatusSection.ai, "尚未填写智谱模型名称。", severity: .error); return nil
                }
                let endpoint = try ProviderFactory.validateHTTPURL(zhipuEndpoint, service: "智谱")
                let key = zhipuAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? SecureSettings.load(SecureSettingKey.zhipuAPIKey, legacyDefaultsKey: SecureSettingKey.zhipuAPIKey)
                    : zhipuAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    setStatus(StatusSection.ai, "尚未填写智谱 API Key。", severity: .error); return nil
                }
                return ZhipuProvider(apiKey: key, model: zhipuModel, endpoint: endpoint)
            case "claude":
                guard !claudeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    setStatus(StatusSection.ai, "尚未填写 Claude 模型名称。", severity: .error); return nil
                }
                let endpoint = try ProviderFactory.validateHTTPURL(claudeEndpoint, service: "Claude")
                let key = claudeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? SecureSettings.load(SecureSettingKey.claudeAPIKey, legacyDefaultsKey: SecureSettingKey.claudeAPIKey)
                    : claudeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    setStatus(StatusSection.ai, "尚未填写 Claude API Key。", severity: .error); return nil
                }
                return ClaudeProvider(apiKey: key, model: claudeModel, endpoint: endpoint)
            default:
                let endpoint = try ProviderFactory.validateHTTPURL(ollamaEndpoint, service: "Ollama")
                guard !ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    setStatus(StatusSection.ai, "尚未填写 Ollama 模型名称。", severity: .error); return nil
                }
                return OllamaProvider(endpoint: endpoint, model: ollamaModel, embeddingModel: AppSettings.ollamaEmbeddingModel)
            }
        } catch {
            setStatus(StatusSection.ai, error.localizedDescription, severity: .error)
            return nil
        }
    }

    private func saveCryptoSettings() {
        guard !appState.isRescueMode else {
            setStatus(StatusSection.crypto, "救援模式：加密设置已禁用。")
            return
        }
        // UI-01（已确认）：护栏——开关提交生效、开启必须非空口令且两次一致、
        // 换口令走数据密钥重包装协议（旧口令验证失败或迁移失败时不覆盖旧口令）。
        let stored = SecureSettings.load(SecureSettingKey.syncPassphrase, legacyDefaultsKey: SecureSettingKey.legacySyncPassphrase)

        if cryptoEnabledDraft {
            guard !cryptoPassphrase.isEmpty else {
                setStatus(StatusSection.crypto, "开启加密需要填写同步口令。")
                return
            }
            guard cryptoPassphrase == cryptoConfirm else {
                setStatus(StatusSection.crypto, "两次输入的口令不一致。")
                return
            }
        }

        if !cryptoEnabledDraft, AppSettings.cryptoEnabled {
            // 关闭加密：必须走迁移流程（远端密文全部转明文），由确认对话框触发
            showsDisableCryptoConfirm = true
            return
        }

        if !cryptoPassphrase.isEmpty, cryptoPassphrase != stored, !stored.isEmpty {
            // 换口令：远端已有加密数据——重包装数据密钥，成功后才写入新口令
            guard cryptoPassphrase == cryptoConfirm else {
                setStatus(StatusSection.crypto, "更换口令需要再次输入新口令确认。")
                return
            }
            setStatus(StatusSection.crypto, "正在更换口令…")
            appState.syncCoordinator.changeCryptoPassphrase(currentPassphrase: stored, newPassphrase: cryptoPassphrase) { message in
                self.setStatus(StatusSection.crypto, message)
            }
            return
        }

        // 其余情况：首次设置口令或口令未变化
        if !cryptoPassphrase.isEmpty {
            guard SecureSettings.save(cryptoPassphrase, for: SecureSettingKey.syncPassphrase, legacyDefaultsKey: SecureSettingKey.legacySyncPassphrase) else {
                setStatus(StatusSection.crypto, "口令无法保存到钥匙串，加密设置未生效。")
                return
            }
        }
        AppSettings.setCryptoEnabled(cryptoEnabledDraft)
        setStatus(StatusSection.crypto, cryptoEnabledDraft ? "加密设置已保存，将在下次同步时生效。请牢记口令。" : "加密已关闭。")
    }

    private func evictYearMedia(year: Int) {
        guard !appState.isRescueMode else {
            setStatus(StatusSection.media, "救援模式：清理媒体已禁用。")
            return
        }
        Task {
            do {
                let count = try await appState.mediaStore.evictYearMedia(year: year)
                setStatus(StatusSection.media, "已清理 \(year) 年本地媒体 \(count) 个。")
                // R1-1: 清理后刷新媒体统计缓存
                loadMediaStats()
            } catch {
                setStatus(StatusSection.media, "清理失败：\(error.localizedDescription)")
            }
        }
    }

    /// R1-1: 延迟加载媒体统计到缓存变量，避免 body 中每次重算
    private func loadMediaStats() {
        mediaTotalSize = appState.mediaStore.totalMediaSize()
        mediaYearSizes = appState.mediaStore.mediaSizeByYear()
    }

    private func loadConflictSummaries() {
        guard !appState.syncConflicts.isEmpty else {
            conflictSummaries = [:]
            return
        }
        conflictSummaries = (try? appState.entries.summaries(for: appState.syncConflicts)) ?? [:]
    }

    private func exportDiagnosticLog() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出诊断日志"
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        Task {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let oneHourAgo = store.position(date: Date().addingTimeInterval(-3600))
                let entries = try store.getEntries(at: oneHourAgo)
                    .compactMap { $0 as? OSLogEntryLog }
                    .filter { $0.subsystem == "com.wuyan.app" }

                var lines: [String] = ["# 晤言诊断日志", "# 导出时间：\(Date())", ""]
                for entry in entries {
                    let category = entry.category
                    let level = entry.level.rawValue
                    let time = entry.date.formatted(.iso8601)
                    let msg = entry.composedMessage
                    lines.append("[\(time)] [\(category)] [\(level)] \(msg)")
                }

                let outputURL = directory.appendingPathComponent("wuyan-diagnostic-\(Int(Date().timeIntervalSince1970)).log")
                try lines.joined(separator: "\n").write(to: outputURL, atomically: true, encoding: .utf8)
                await MainActor.run {
                    setStatus(StatusSection.diag, "已导出 \(entries.count) 条日志。")
                }
            } catch {
                await MainActor.run {
                    setStatus(StatusSection.diag, "导出失败：\(error.localizedDescription)")
                }
            }
        }
    }
}
