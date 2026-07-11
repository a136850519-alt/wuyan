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
    @AppStorage(SettingKey.cryptoEnabled) private var cryptoEnabled = false
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
                        Text("冲突副本保存在 NAS 的 /Wuyan/entries/conflicts/ 目录下。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
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
                Text("云端模式会在发送日记内容前提示发送范围。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("提醒与元数据") {
                Toggle("每日提醒", isOn: $reminderEnabled)
                    .tint(Palette.cinnabar)
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
                Button("导出 Markdown / JSON / PDF") {
                    exportAll()
                }
                Button("从 JSON 备份还原") {
                    importJSONBackup()
                }
                sectionStatus(for: StatusSection.export)
            }

            Section("加密") {
                Toggle("远端同步加密", isOn: $cryptoEnabled)
                    .tint(Palette.cinnabar)
                SecureField("同步加密口令", text: $cryptoPassphrase)
                SecureField("再次输入口令", text: $cryptoConfirm)
                Button("保存加密设置") {
                    saveCryptoSettings()
                }
                sectionStatus(for: StatusSection.crypto)
                Text("开启后新上传到远端的条目、daynote、manifest 与媒体会加密；丢失口令无法恢复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                                evictYearMedia(year: year)
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
        saveStorageSettings(showMessage: false)
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

    private func saveStorageSettings(showMessage: Bool = true) {
        webDAVBaseURL = webDAVBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        webDAVUsername = webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        s3Endpoint = s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        s3Region = s3Region.trimmingCharacters(in: .whitespacesAndNewlines)
        s3Bucket = s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        s3AccessKey = s3AccessKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if storageBackend == "s3" {
            SecureSettings.save(s3SecretKey, for: SecureSettingKey.s3SecretKey, legacyDefaultsKey: SecureSettingKey.s3SecretKey)
        } else {
            SecureSettings.save(webDAVPassword, for: SecureSettingKey.webDAVPassword, legacyDefaultsKey: SecureSettingKey.webDAVPassword)
        }

        if showMessage {
            setStatus(StatusSection.storage, "存储配置已保存。")
        }
    }

    private func exportAll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let directory = panel.url {
            do {
                let entries = try appState.entries.timeline(filter: .all)
                let service = ExportService()
                try service.exportMarkdown(entries: entries, mediaDAO: appState.db.mediaAssetDAO, to: directory.appendingPathComponent("Markdown", isDirectory: true))
                try service.exportJSON(entries: entries, to: directory.appendingPathComponent("wuyan-backup.json"))
                try service.exportPDF(entries: entries, to: directory.appendingPathComponent("wuyan-export.pdf"))
                setStatus(StatusSection.export, "已导出 \(entries.count) 篇。")
            } catch {
                setStatus(StatusSection.export, error.localizedDescription)
            }
        }
    }

    private func importJSONBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let count = try ExportService().importJSON(from: url, database: appState.db)
                setStatus(StatusSection.export, "已还原 \(count) 篇。")
            } catch {
                setStatus(StatusSection.export, error.localizedDescription)
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
                await MainActor.run { setStatus(StatusSection.reminder, "已保存 \(components.count) 个提醒。") }
            } else {
                await scheduler.cancelAll()
                await MainActor.run { setStatus(StatusSection.reminder, "提醒已关闭。") }
            }
        }
    }

    private func growthBoard() -> Board? {
        (try? appState.boards.all())?.first { $0.kind == .growth }
    }

    private func saveBabyBirthday() {
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
            setStatus(StatusSection.baby, "宝贝生日已保存。")
        } catch {
            setStatus(StatusSection.baby, error.localizedDescription)
        }
    }

    private func checkAIHealth() {
        saveAISettings(showMessage: false)
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

    private func saveAISettings(showMessage: Bool = true) {
        zhipuEndpoint = zhipuEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        zhipuModel = zhipuModel.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeEndpoint = claudeEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeModel = claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        ollamaEndpoint = ollamaEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        ollamaModel = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)

        switch aiProvider {
        case "zhipu":
            SecureSettings.save(zhipuAPIKey, for: SecureSettingKey.zhipuAPIKey, legacyDefaultsKey: SecureSettingKey.zhipuAPIKey)
        case "claude":
            SecureSettings.save(claudeAPIKey, for: SecureSettingKey.claudeAPIKey, legacyDefaultsKey: SecureSettingKey.claudeAPIKey)
        default:
            break
        }
        appState.reloadAISettings()

        if showMessage {
            setStatus(StatusSection.ai, "AI 配置已保存。")
        }
    }

    private func saveCryptoSettings() {
        if cryptoPassphrase.isEmpty {
            setStatus(StatusSection.crypto, cryptoEnabled ? "加密已开启；未填写新口令，已保留现有口令。" : "加密已关闭。")
            return
        }
        guard cryptoPassphrase == cryptoConfirm || cryptoConfirm.isEmpty else {
            setStatus(StatusSection.crypto, "两次口令不一致。")
            return
        }
        SecureSettings.save(cryptoPassphrase, for: SecureSettingKey.syncPassphrase, legacyDefaultsKey: SecureSettingKey.legacySyncPassphrase)
        setStatus(StatusSection.crypto, cryptoEnabled ? "加密设置已保存。请牢记口令。" : "加密已关闭。")
    }

    private func evictYearMedia(year: Int) {
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
