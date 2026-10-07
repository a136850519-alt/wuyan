import SwiftUI
import OSLog

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(SettingKey.storageBackend) private var storageBackend = "webDAV"
    @AppStorage(SettingKey.webDAVBaseURL) private var webDAVBaseURL = "https://nas.local:5006"
    @AppStorage(SettingKey.webDAVUsername) private var webDAVUsername = ""
    @AppStorage(SettingKey.s3Endpoint) private var s3Endpoint = ""
    @AppStorage(SettingKey.s3Region) private var s3Region = "us-east-1"
    @AppStorage(SettingKey.s3Bucket) private var s3Bucket = "wuyan"
    @AppStorage(SettingKey.s3AccessKey) private var s3AccessKey = ""
    @AppStorage(SettingKey.s3PathStyle) private var s3PathStyle = true
    @AppStorage(SettingKey.aiEnabled) private var aiEnabled = false
    @AppStorage(SettingKey.aiRitual) private var ritualAI = true
    @AppStorage(SettingKey.aiProvider) private var aiProvider = "zhipu"
    @AppStorage(SettingKey.zhipuEndpoint) private var zhipuEndpoint = "https://open.bigmodel.cn/api/paas/v4"
    @AppStorage(SettingKey.zhipuModel) private var zhipuModel = "glm-5.2"
    @AppStorage(SettingKey.claudeEndpoint) private var claudeEndpoint = "https://api.anthropic.com/v1/messages"
    @AppStorage(SettingKey.claudeModel) private var claudeModel = "claude-sonnet-5"
    @AppStorage(SettingKey.ollamaEndpoint) private var ollamaEndpoint = "http://localhost:11434"
    @AppStorage(SettingKey.ollamaModel) private var ollamaModel = "qwen2.5"
    @AppStorage(SettingKey.appearanceBodyFont) private var bodyFont = "LXGWWenKai-Regular"
    @AppStorage(SettingKey.reminderEnabled) private var reminderEnabled = false
    @AppStorage(SettingKey.reminderSkipWrittenDays) private var skipWrittenDays = true
    @AppStorage(SettingKey.metadataEnabled) private var metadataEnabled = true
    // UI-01（已确认）：加密开关不再即时生效，改为草稿状态、点「保存加密设置」才应用
    @State private var cryptoEnabledDraft = false
    @State private var showsDisableCryptoConfirm = false
    @State private var showsConflictList = false
    @State private var pendingRestoreDirectory: URL?
    @State private var pendingJSONImportURL: URL?
    @State private var pendingEvictYear: Int?
    @State private var isBackupTaskRunning = false
    @State private var webDAVPassword = ""
    @State private var s3SecretKey = ""
    @State private var zhipuAPIKey = ""
    @State private var claudeAPIKey = ""
    @State private var reminderTimes: [Date] = []
    @State private var isTestingStorage = false
    @State private var isTestingAI = false
    @State private var cryptoPassphrase = ""
    @State private var cryptoConfirm = ""
    @State private var babyBirthday = Date()
    @State private var conflictSummaries: [UUID: EntrySummary] = [:]
    /// R2-10: 统一消息状态，替代 10 个并行 @State message 变量
    @State private var statusMessage: (section: String, text: String)?
    /// R2-10: 自动过期定时器
    @State private var statusTimer: Timer?
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
                    SecureField("智谱 API Key", text: $zhipuAPIKey)
                } else if aiProvider == "claude" {
                    TextField("Claude URL", text: $claudeEndpoint)
                    TextField("Claude 模型", text: $claudeModel, prompt: Text("如 claude-sonnet-5、claude-opus-5"))
                    SecureField("Claude API Key", text: $claudeAPIKey)
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
                sectionStatus(for: StatusSection.ai)
                Text("云端模式会在发送日记内容前提示发送范围。自动采集位置与天气时，会把约 3km 精度的坐标发送给 Apple 地理编码和 Open-Meteo。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("提醒与元数据") {
                Toggle("每日提醒", isOn: $reminderEnabled)
                    .tint(Palette.cinnabar)
                    .onChange(of: reminderEnabled) { enabled in
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
                .disabled(isBackupTaskRunning)
                Button("从完整备份还原…") {
                    pickFullBackupForRestore()
                }
                .disabled(isBackupTaskRunning)
                Divider()
                Button("导出 Markdown / JSON / PDF（阅读用）") {
                    exportAll()
                }
                .disabled(isBackupTaskRunning)
                Button("从 JSON 备份还原（旧格式）") {
                    importJSONBackup()
                }
                .disabled(isBackupTaskRunning)
                if isBackupTaskRunning {
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
        .sheet(isPresented: $showsConflictList) {
            ConflictListView()
                .environmentObject(appState)
        }
    }

    // MARK: - R2-10: 统一消息

    /// 显示某个 Section 的状态消息（如果有）
    @ViewBuilder
    private func sectionStatus(for section: String) -> some View {
        if let msg = statusMessage, msg.section == section {
            Text(msg.text)
                .foregroundStyle(.secondary)
        }
    }

    /// 设置状态消息，5 秒后自动清除
    private func setStatus(_ section: String, _ text: String) {
        statusMessage = (section, text)
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            Task { @MainActor in
                self.statusMessage = nil
            }
        }
    }

    /// 清除某个 Section 的状态消息
    private func clearStatus(_ section: String) {
        if let msg = statusMessage, msg.section == section {
            statusMessage = nil
        }
    }

    // MARK: - 数据加载

    private func loadSecureSettings() {
        webDAVPassword = SecureSettings.load(SecureSettingKey.webDAVPassword, legacyDefaultsKey: SecureSettingKey.webDAVPassword)
        s3SecretKey = SecureSettings.load(SecureSettingKey.s3SecretKey, legacyDefaultsKey: SecureSettingKey.s3SecretKey)
        zhipuAPIKey = SecureSettings.load(SecureSettingKey.zhipuAPIKey, legacyDefaultsKey: SecureSettingKey.zhipuAPIKey)
        claudeAPIKey = SecureSettings.load(SecureSettingKey.claudeAPIKey, legacyDefaultsKey: SecureSettingKey.claudeAPIKey)
        cryptoPassphrase = SecureSettings.load(SecureSettingKey.syncPassphrase, legacyDefaultsKey: SecureSettingKey.legacySyncPassphrase)
    }

    private func loadBabyBirthday() {
        if let board = growthBoard(), let birthday = board.babyBirthday {
            babyBirthday = birthday
        }
    }

    private func testStorage() {
        guard !isTestingStorage else { return }
        guard saveStorageSettings(showMessage: false) else { return }
        setStatus(StatusSection.storage, "正在测试连接…")
        isTestingStorage = true

        let provider: any RemoteStorageProvider
        do {
            provider = try ProviderFactory.makeRemoteStorageProvider()
        } catch {
            setStatus(StatusSection.storage, error.localizedDescription)
            isTestingStorage = false
            return
        }
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

    @discardableResult
    private func saveStorageSettings(showMessage: Bool = true) -> Bool {
        webDAVBaseURL = webDAVBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        webDAVUsername = webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        s3Endpoint = s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        s3Region = s3Region.trimmingCharacters(in: .whitespacesAndNewlines)
        s3Bucket = s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        s3AccessKey = s3AccessKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if storageBackend == "s3" {
            guard SecureSettings.save(s3SecretKey, for: SecureSettingKey.s3SecretKey, legacyDefaultsKey: SecureSettingKey.s3SecretKey) else {
                setStatus(StatusSection.storage, "Secret Key 无法保存到钥匙串，配置未生效。")
                return false
            }
        } else {
            guard SecureSettings.save(webDAVPassword, for: SecureSettingKey.webDAVPassword, legacyDefaultsKey: SecureSettingKey.webDAVPassword) else {
                setStatus(StatusSection.storage, "密码无法保存到钥匙串，配置未生效。")
                return false
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
            isBackupTaskRunning = true
            let database = appState.db
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result {
                        let entries = try database.entryDAO.timeline(filter: .all)
                        let service = ExportService()
                        try service.exportMarkdown(entries: entries, mediaDAO: database.mediaAssetDAO, to: directory.appendingPathComponent("Markdown", isDirectory: true))
                        try service.exportJSON(entries: entries, to: directory.appendingPathComponent("wuyan-entries.json"))
                        try service.exportPDF(entries: entries, to: directory.appendingPathComponent("wuyan-export.pdf"))
                        return entries.count
                    }
                }.value
                isBackupTaskRunning = false
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
        isBackupTaskRunning = true
        let database = appState.db
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ExportService().importJSON(from: url, database: database) }
            }.value
            isBackupTaskRunning = false
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
        isBackupTaskRunning = true
        let database = appState.db
        let archived = appState.archivedYears
        if !archived.isEmpty {
            setStatus(StatusSection.export, "提示：完整备份不包含已归档年份 \(archived.sorted().map(String.init).joined(separator: "、")) 的远端内容。")
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ExportService().exportFullBackupPackage(database: database, to: target) }
            }.value
            isBackupTaskRunning = false
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
        isBackupTaskRunning = true
        let database = appState.db
        let mediaStore = appState.mediaStore
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try ExportService().importFullBackupPackage(from: directory, database: database, mediaStore: mediaStore, strategy: strategy)
                }
            }.value
            isBackupTaskRunning = false
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
            guard await scheduler.requestAuthorization() else {
                await MainActor.run { setStatus(StatusSection.reminder, "通知授权未开启。") }
                return
            }
            AppState.saveReminderTimesToDefaults(reminderTimes)
            if reminderEnabled {
                let components = reminderTimes.map { Calendar.current.dateComponents([.hour, .minute], from: $0) }
                await scheduler.setDailyReminders(components)
                await MainActor.run {
                    appState.refreshRemindersForToday(force: true)
                    setStatus(StatusSection.reminder, "已保存 \(components.count) 个提醒。")
                }
            } else {
                await scheduler.cancelAll()
                await MainActor.run {
                    appState.refreshRemindersForToday(force: true)
                    setStatus(StatusSection.reminder, "提醒已关闭。")
                }
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
        guard saveAISettings(showMessage: false) else { return }
        appState.reloadAISettings()
        setStatus(StatusSection.ai, "正在测试连接…")
        isTestingAI = true
        Task {
            do {
                guard let provider = appState.aiService.provider else { throw AIError.disabled }
                let result = try await provider.complete([
                    AIMessage(role: .system, content: "只回复 OK。"),
                    AIMessage(role: .user, content: "ping")
                ], options: AIOptions(temperature: 0, maxTokens: 8))
                await MainActor.run {
                    setStatus(StatusSection.ai, result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "连接成功。" : "连接成功：\(result)")
                    isTestingAI = false
                }
            } catch {
                await MainActor.run {
                    setStatus(StatusSection.ai, error.localizedDescription)
                    isTestingAI = false
                }
            }
        }
    }

    @discardableResult
    private func saveAISettings(showMessage: Bool = true) -> Bool {
        zhipuEndpoint = zhipuEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        zhipuModel = zhipuModel.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeEndpoint = claudeEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeModel = claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        ollamaEndpoint = ollamaEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        ollamaModel = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)

        switch aiProvider {
        case "zhipu":
            guard SecureSettings.save(zhipuAPIKey, for: SecureSettingKey.zhipuAPIKey, legacyDefaultsKey: SecureSettingKey.zhipuAPIKey) else {
                setStatus(StatusSection.ai, "智谱 API Key 无法保存到钥匙串，配置未生效。")
                return false
            }
        case "claude":
            guard SecureSettings.save(claudeAPIKey, for: SecureSettingKey.claudeAPIKey, legacyDefaultsKey: SecureSettingKey.claudeAPIKey) else {
                setStatus(StatusSection.ai, "Claude API Key 无法保存到钥匙串，配置未生效。")
                return false
            }
        default:
            break
        }
        appState.reloadAISettings()

        if showMessage {
            setStatus(StatusSection.ai, "AI 配置已保存。")
        }
        return true
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
