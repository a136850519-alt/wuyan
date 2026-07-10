import Combine
import CryptoKit
import Foundation
import Security

enum SidebarSelection: Hashable {
    case all
    case favorites
    case drafts
    case todayInHistory
    case calendar
    case settings
    case trash
    case board(UUID)
    case year(Int)
    case yearBoard(Int, UUID)

    var boardId: UUID? {
        if case let .board(id) = self {
            return id
        }
        if case let .yearBoard(_, id) = self {
            return id
        }
        return nil
    }
}

@MainActor
final class AppState: ObservableObject {
    let db: AppDatabase
    let boards: BoardDAO
    let entries: EntryDAO
    let dayNotes: DayNoteDAO
    let aiService: AIService
    var poeticGenerator: PoeticGenerator { aiService }
    let mediaStore: LocalMediaStore
    let locationMetadata = LocationMetadataService()
    let audioRecorder = AudioRecorder()

    @Published var sidebarSelection: SidebarSelection = .all
    @Published var selectedEntryId: UUID?
    @Published var isShowingRitual = false
    @Published var boardChooserDay: String?
    @Published var errorMessage: String?
    @Published var syncMessage: String?
    @Published var syncProgress: SyncProgress?
    @Published var syncConflicts: [UUID] = []
    /// 全局云端 AI 信任标记：同一会话内确认一次后，AIAssistantView 和 RitualView 共享。
    @Published var trustCloudForSession = false
    /// 已归档年份（本地内容已删除、仅存于 NAS）。按降序排列。
    @Published var archivedYears: [Int] = []

    private static let archivedYearsKey = "archive.years"

    init(database: AppDatabase) {
        self.db = database
        self.boards = database.boardDAO
        self.entries = database.entryDAO
        self.dayNotes = database.dayNoteDAO
        self.mediaStore = try! LocalMediaStore(database: database)
        self.aiService = AIService(
            provider: AppState.makeAIProviderFromDefaults(),
            isEnabled: UserDefaults.standard.bool(forKey: "settings.ai.enabled"),
            ritualPolishingEnabled: UserDefaults.standard.object(forKey: "settings.ai.ritual") as? Bool ?? true
        )
        self.aiService.cloudBlockedBoardIds = Self.cloudBlockedBoardIds(boards)
        let stored = UserDefaults.standard.array(forKey: Self.archivedYearsKey) as? [Int] ?? []
        self.archivedYears = stored.sorted(by: >)
    }

    private func setArchivedYears(_ years: Set<Int>) {
        let sorted = years.sorted(by: >)
        archivedYears = sorted
        UserDefaults.standard.set(sorted, forKey: Self.archivedYearsKey)
    }

    private static func cloudBlockedBoardIds(_ boards: BoardDAO) -> Set<UUID> {
        let all = (try? boards.all()) ?? []
        return Set(all.filter(\.disallowCloudAI).map(\.id))
    }

    var selectedBoardId: UUID? {
        get { sidebarSelection.boardId }
        set {
            if let newValue {
                let year = Self.year(fromDayKey: DayKey.today)
                sidebarSelection = .yearBoard(year, newValue)
            } else {
                sidebarSelection = .all
            }
        }
    }

    func showNewEntryRitual() {
        isShowingRitual = true
    }

    func showBoardChooser(day: String) {
        boardChooserDay = day
    }

    func openEntry(id: UUID) {
        do {
            guard let entry = try entries.entry(id: id) else {
                selectedEntryId = nil
                return
            }
            let year = Self.year(fromDayKey: entry.dayDate)
            sidebarSelection = .yearBoard(year, entry.boardId)
            selectedEntryId = entry.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectEntry(_ entry: Entry?) {
        selectedEntryId = entry?.id
    }

    /// 永久删除条目，并清理「已无其它条目引用」的本地媒体文件（内容寻址，避免误删共享文件）。
    /// 注：NAS 端媒体不在此回收（内容寻址跨设备共享，回收需全量引用核算，留待后续）。
    func permanentlyDelete(entryId: UUID) {
        do {
            let assets = (try? entries.entry(id: entryId)).flatMap { try? db.mediaAssetDAO.allAssets(for: $0.mediaIds) } ?? []
            try entries.permanentlyDelete(id: entryId)
            for asset in assets where ((try? db.mediaAssetDAO.referenceCount(sha256: asset.sha256)) ?? 1) == 0 {
                try? mediaStore.removeLocalFiles(for: asset)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func syncNow() {
        guard syncProgress == nil else { return }
        syncMessage = "同步中…"
        syncProgress = SyncProgress(phase: "准备同步", completedUnitCount: 0, totalUnitCount: 1)
        syncConflicts = []
        errorMessage = nil

        let provider: any RemoteStorageProvider
        do {
            provider = try Self.makeRemoteStorageProviderFromDefaults()
        } catch {
            syncMessage = nil
            syncProgress = nil
            errorMessage = error.localizedDescription
            return
        }
        if UserDefaults.standard.bool(forKey: "settings.crypto.enabled") {
            let passphrase = SecureSettings.load(SecureSettingKey.syncPassphrase, legacyDefaultsKey: SecureSettingKey.legacySyncPassphrase)
            if passphrase.isEmpty {
                syncMessage = nil
                syncProgress = nil
                errorMessage = "请先在设置中填写同步加密口令。"
                return
            }
        }
        let archived = Set(archivedYears)
        let dbRef = db
        Task {
            // SyncCrypto 的 PBKDF2 密钥派生在此后台 Task 中完成，不阻塞主线程
            let crypto = Self.makeSyncCryptoFromDefaults()
            let engine = SyncEngine(provider: provider, database: dbRef, crypto: crypto, archivedYears: archived, backendFingerprint: Self.backendFingerprint()) { progress in
                await MainActor.run {
                    self.syncProgress = progress
                    if let detail = progress.detail, !detail.isEmpty {
                        self.syncMessage = "\(progress.phase)：\(detail)"
                    } else {
                        self.syncMessage = progress.phase
                    }
                }
            }
            do {
                let report = try await engine.syncNow()
                await MainActor.run {
                    syncConflicts = report.conflicts
                    let conflictText = report.conflicts.isEmpty ? "" : "，冲突 \(report.conflicts.count)"
                    syncMessage = "同步完成：推送 \(report.pushed)，拉取 \(report.pulled)，媒体 \(report.mediaUploaded)\(conflictText)。"
                    syncProgress = nil
                }
            } catch {
                await MainActor.run {
                    syncMessage = nil
                    syncProgress = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func archiveYearToRemote(_ year: Int) {
        guard syncProgress == nil else { return }
        syncMessage = "\(year) 年归档中…"
        syncProgress = SyncProgress(phase: "\(year) 年归档准备中", completedUnitCount: 0, totalUnitCount: 1)
        errorMessage = nil

        let provider: any RemoteStorageProvider
        do {
            provider = try Self.makeRemoteStorageProviderFromDefaults()
        } catch {
            syncMessage = nil
            syncProgress = nil
            errorMessage = error.localizedDescription
            return
        }
        let database = db
        let mediaStore = mediaStore
        Task {
            let crypto = Self.makeSyncCryptoFromDefaults()
            do {
                let yearEntries = try entries.timeline(filter: .year(year))
                let engine = SyncEngine(provider: provider, database: database, crypto: crypto, backendFingerprint: Self.backendFingerprint()) { progress in
                    await MainActor.run {
                        self.syncProgress = progress
                        self.syncMessage = "\(year) 年归档：\(progress.phase)"
                    }
                }
                // 只推送本年（日记 + 日札 + 附件），不做全量双向同步。
                let report = try await engine.archiveYear(year)
                let uploaded = report.mediaUploaded
                var removed = 0
                for (index, entry) in yearEntries.enumerated() {
                    await MainActor.run {
                        self.syncProgress = SyncProgress(
                            phase: "正在清理本地附件",
                            completedUnitCount: index,
                            totalUnitCount: max(1, yearEntries.count),
                            detail: entry.dayDate
                        )
                    }
                    let assets = try database.mediaAssetDAO.allAssets(for: entry.mediaIds)
                    for asset in assets {
                        let mediaPath = crypto == nil
                            ? SyncPaths.mediaPath(sha256: asset.sha256, filename: asset.filename)
                            : SyncPaths.encryptedMediaPath(sha256: asset.sha256, filename: asset.filename)
                        guard try await provider.exists(mediaPath) else { continue }
                        try mediaStore.removeLocalFiles(for: asset)
                        removed += 1
                    }
                }

                // 本年内容已确认在 NAS 上 → 删除本地正文与日札，腾出空间。
                // 保留 media_asset 行（仅清了本地文件），这样从「已归档」下载回来时仍能按 sha256 取附件。
                await MainActor.run {
                    self.syncProgress = SyncProgress(phase: "正在删除本地内容", completedUnitCount: 0, totalUnitCount: 1)
                    self.syncMessage = "\(year) 年归档：正在删除本地内容"
                }
                let yearPrefix = String(format: "%04d-", year)
                let yearNotes = try database.dayNoteDAO.all().filter { $0.date.hasPrefix(yearPrefix) }
                for entry in yearEntries {
                    try database.entryDAO.permanentlyDelete(id: entry.id)
                }
                for note in yearNotes {
                    try database.dayNoteDAO.delete(dayKey: note.date)
                }

                await MainActor.run {
                    self.setArchivedYears(Set(self.archivedYears).union([year]))
                    syncMessage = "\(year) 年归档完成：上传媒体 \(uploaded)，清理本地附件 \(removed)，已删除本地 \(yearEntries.count) 篇日记。"
                    syncProgress = nil
                }
            } catch {
                await MainActor.run {
                    syncMessage = nil
                    syncProgress = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func downloadYearFromRemote(_ year: Int) {
        guard syncProgress == nil else { return }
        syncMessage = "\(year) 年下载中…"
        syncProgress = SyncProgress(phase: "\(year) 年下载准备中", completedUnitCount: 0, totalUnitCount: 1)
        errorMessage = nil

        let provider: any RemoteStorageProvider
        do {
            provider = try Self.makeRemoteStorageProviderFromDefaults()
        } catch {
            syncMessage = nil
            syncProgress = nil
            errorMessage = error.localizedDescription
            return
        }
        let database = db
        Task {
            let crypto = Self.makeSyncCryptoFromDefaults()
            do {
                let engine = SyncEngine(provider: provider, database: database, crypto: crypto, backendFingerprint: Self.backendFingerprint()) { progress in
                    await MainActor.run {
                        self.syncProgress = progress
                        self.syncMessage = "\(year) 年下载：\(progress.phase)"
                    }
                }
                // 只拉取该年（含已归档年份），不触发全量同步。
                _ = try await engine.pullYear(year)
                let yearEntries = try entries.timeline(filter: .year(year))
                await MainActor.run {
                    self.syncProgress = SyncProgress(
                        phase: "正在下载本年附件",
                        completedUnitCount: 0,
                        totalUnitCount: max(1, yearEntries.count)
                    )
                }
                var downloaded = 0
                for (index, entry) in yearEntries.enumerated() {
                    await MainActor.run {
                        self.syncProgress = SyncProgress(
                            phase: "正在下载本年附件",
                            completedUnitCount: index,
                            totalUnitCount: max(1, yearEntries.count),
                            detail: entry.dayDate
                        )
                    }
                    let assets = try database.mediaAssetDAO.allAssets(for: entry.mediaIds)
                    for asset in assets {
                        if try await downloadMediaIfNeeded(asset) != nil {
                            downloaded += 1
                        }
                        if asset.type == .photo, asset.thumbnailPath == nil {
                            _ = try? await downloadThumbnailIfNeeded(asset)
                        }
                    }
                }
                await MainActor.run {
                    // 已下载回本地 → 移出「已归档」，恢复正常同步。
                    self.setArchivedYears(Set(self.archivedYears).subtracting([year]))
                    syncMessage = "\(year) 年下载完成：本地附件 \(downloaded)。"
                    syncProgress = nil
                }
            } catch {
                await MainActor.run {
                    syncMessage = nil
                    syncProgress = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func enrichEntryMetadataIfNeeded(_ entryId: UUID) {
        guard UserDefaults.standard.object(forKey: "settings.metadata.enabled") as? Bool ?? true else { return }
        Task {
            guard let location = await locationMetadata.requestLocation(),
                  var entry = try? entries.entry(id: entryId)
            else { return }
            let placeName = await locationMetadata.geocode(location)
            entry.location = GeoPlace(lat: location.coordinate.latitude, lon: location.coordinate.longitude, placeName: placeName)
            if let weather = try? await OpenMeteoService().current(lat: location.coordinate.latitude, lon: location.coordinate.longitude) {
                entry.weather = weather
            }
            try? entries.save(entry)
        }
    }

    func refreshRemindersForToday() {
        guard UserDefaults.standard.bool(forKey: "settings.reminder.enabled") else { return }
        let times = Self.reminderTimesFromDefaults()
        Task {
            let today = Date().dayKey
            let hasWrittenToday = ((try? entries.timeline(filter: .day(today))) ?? []).isEmpty == false
            await ReminderScheduler().refreshForToday(hasWrittenToday: hasWrittenToday, times: times)
        }
    }

    func reloadAISettings() {
        aiService.provider = Self.makeAIProviderFromDefaults()
        aiService.isEnabled = UserDefaults.standard.bool(forKey: "settings.ai.enabled")
        aiService.ritualPolishingEnabled = UserDefaults.standard.object(forKey: "settings.ai.ritual") as? Bool ?? true
        aiService.cloudBlockedBoardIds = Self.cloudBlockedBoardIds(boards)
    }

    private static func makeAIProviderFromDefaults() -> AIProvider? {
        let defaults = UserDefaults.standard
        let provider = defaults.string(forKey: "settings.ai.provider") ?? "zhipu"
        if provider == "zhipu" {
            let endpoint = urlFromDefaults(
                key: "settings.zhipu.endpoint",
                fallback: "https://open.bigmodel.cn/api/paas/v4"
            )
            return ZhipuProvider(
                apiKey: SecureSettings.load(SecureSettingKey.zhipuAPIKey, legacyDefaultsKey: SecureSettingKey.zhipuAPIKey),
                model: defaults.string(forKey: "settings.zhipu.model") ?? "glm-5.2",
                endpoint: endpoint
            )
        }
        if provider == "claude" {
            let endpoint = urlFromDefaults(
                key: "settings.claude.endpoint",
                fallback: "https://api.anthropic.com/v1/messages"
            )
            return ClaudeProvider(
                apiKey: SecureSettings.load(SecureSettingKey.claudeAPIKey, legacyDefaultsKey: SecureSettingKey.claudeAPIKey),
                model: defaults.string(forKey: "settings.claude.model") ?? "claude-sonnet-5",
                endpoint: endpoint
            )
        }
        let endpoint = URL(string: defaults.string(forKey: "settings.ollama.endpoint") ?? "http://localhost:11434") ?? URL(string: "http://localhost:11434")!
        return OllamaProvider(
            endpoint: endpoint,
            model: defaults.string(forKey: "settings.ollama.model") ?? "qwen2.5",
            embeddingModel: defaults.string(forKey: "settings.ollama.embeddingModel") ?? "nomic-embed-text"
        )
    }

    private static func urlFromDefaults(key: String, fallback: String) -> URL {
        let raw = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: raw?.isEmpty == false ? raw! : fallback) ?? URL(string: fallback)!
    }

    static func makeRemoteStorageProviderFromDefaults() throws -> any RemoteStorageProvider {
        let defaults = UserDefaults.standard
        let backend = defaults.string(forKey: "settings.storage.backend") ?? "webDAV"
        if backend == "s3" {
            guard let endpoint = URL(string: defaults.string(forKey: "settings.s3.endpoint") ?? "") else {
                throw RemoteStorageError.invalidBaseURL
            }
            let bucket = defaults.string(forKey: "settings.s3.bucket") ?? ""
            guard !bucket.isEmpty else { throw RemoteStorageError.missingConfiguration("S3 bucket") }
            let secretKey = SecureSettings.load(SecureSettingKey.s3SecretKey, legacyDefaultsKey: SecureSettingKey.s3SecretKey)
            guard !(defaults.string(forKey: "settings.s3.accessKey") ?? "").isEmpty, !secretKey.isEmpty else {
                throw RemoteStorageError.missingCredentials
            }
            return S3Provider(
                endpoint: endpoint,
                bucket: bucket,
                region: defaults.string(forKey: "settings.s3.region") ?? "us-east-1",
                accessKey: defaults.string(forKey: "settings.s3.accessKey") ?? "",
                secretKey: secretKey,
                pathStyle: defaults.object(forKey: "settings.s3.pathStyle") as? Bool ?? true
            )
        }

        guard let url = URL(string: defaults.string(forKey: "settings.webdav.baseURL") ?? "") else {
            throw RemoteStorageError.invalidBaseURL
        }
        let username = defaults.string(forKey: "settings.webdav.username")
        let password = SecureSettings.load(SecureSettingKey.webDAVPassword, legacyDefaultsKey: SecureSettingKey.webDAVPassword)
        guard username?.isEmpty == false, !password.isEmpty else {
            throw RemoteStorageError.missingCredentials
        }
        return WebDAVProvider(
            baseURL: url,
            username: username,
            password: password
        )
    }

    /// 基于 backend+baseURL+bucket 计算后端指纹（SHA256 前8位），用于区分不同远端配置
    static func backendFingerprint() -> String {
        let defaults = UserDefaults.standard
        let backend = defaults.string(forKey: "settings.storage.backend") ?? "webDAV"
        var identity: String
        if backend == "s3" {
            let endpoint = defaults.string(forKey: "settings.s3.endpoint") ?? ""
            let bucket = defaults.string(forKey: "settings.s3.bucket") ?? ""
            identity = "s3:\(endpoint):\(bucket)"
        } else {
            let baseURL = defaults.string(forKey: "settings.webdav.baseURL") ?? ""
            let username = defaults.string(forKey: "settings.webdav.username") ?? ""
            identity = "webdav:\(baseURL):\(username)"
        }
        let digest = CryptoKit.SHA256.hash(data: Data(identity.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.prefix(8).joined()
    }

    static func makeSyncCryptoFromDefaults() -> SyncCrypto? {
        guard UserDefaults.standard.bool(forKey: "settings.crypto.enabled") else { return nil }
        let passphrase = SecureSettings.load(SecureSettingKey.syncPassphrase, legacyDefaultsKey: SecureSettingKey.legacySyncPassphrase)
        guard !passphrase.isEmpty else { return nil }
        let saltKey = "settings.crypto.salt"
        let salt: Data
        if let existing = UserDefaults.standard.string(forKey: saltKey), let data = Data(base64Encoded: existing) {
            salt = data
        } else {
            var bytes = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            salt = Data(bytes)
            UserDefaults.standard.set(salt.base64EncodedString(), forKey: saltKey)
        }
        return try? SyncCrypto(passphrase: passphrase, salt: salt)
    }

    static func reminderTimesFromDefaults() -> [DateComponents] {
        let stored = UserDefaults.standard.array(forKey: "settings.reminder.times") as? [String] ?? ["21:30"]
        return stored.compactMap { value in
            let parts = value.split(separator: ":").compactMap { Int(String($0)) }
            guard parts.count == 2 else { return nil }
            return DateComponents(hour: parts[0], minute: parts[1])
        }
    }

    static func saveReminderTimesToDefaults(_ dates: [Date]) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        UserDefaults.standard.set(dates.map { formatter.string(from: $0) }, forKey: "settings.reminder.times")
    }

    static func year(fromDayKey dayKey: String) -> Int {
        Int(dayKey.prefix(4)) ?? Calendar.current.component(.year, from: Date())
    }

    static func reminderDatesFromDefaults() -> [Date] {
        let calendar = Calendar.current
        return reminderTimesFromDefaults().compactMap { components in
            calendar.date(bySettingHour: components.hour ?? 21, minute: components.minute ?? 30, second: 0, of: Date())
        }
    }

    func downloadMediaIfNeeded(_ asset: MediaAsset) async throws -> URL? {
        if let localPath = asset.localPath {
            let absolutePath = LocalMediaStore.resolvePath(localPath)
            if FileManager.default.fileExists(atPath: absolutePath) {
                return URL(fileURLWithPath: absolutePath)
            }
        }

        let provider = try Self.makeRemoteStorageProviderFromDefaults()
        let plainPath = SyncPaths.mediaPath(sha256: asset.sha256, filename: asset.filename)
        let encPath = SyncPaths.encryptedMediaPath(sha256: asset.sha256, filename: asset.filename)

        // 明文媒体：断点续传下载，直接落盘，避免把大视频读进内存。
        if (try? await provider.contentLength(plainPath)) != nil {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("wuyan-download-\(asset.sha256)")
            try await provider.getResumable(plainPath, into: tempURL)
            return try mediaStore.storeRemoteMediaFile(movingFrom: tempURL, for: asset)
        }

        // 加密媒体：整取后解密（密文需完整才能解，无法分段落盘）。
        let data = try await provider.get(encPath)
        return try mediaStore.storeRemoteMedia(try Self.decryptRemoteDataIfNeeded(data), for: asset)
    }

    private func downloadThumbnailIfNeeded(_ asset: MediaAsset) async throws -> Bool {
        if let thumbnailPath = asset.thumbnailPath {
            let absolutePath = LocalMediaStore.resolvePath(thumbnailPath)
            if FileManager.default.fileExists(atPath: absolutePath) {
                return true
            }
        }

        let provider = try Self.makeRemoteStorageProviderFromDefaults()
        let data = try await provider.get(SyncPaths.thumbnailPath(sha256: asset.sha256))
        try mediaStore.storeRemoteThumbnail(data, for: asset)
        return true
    }

    private static func decryptRemoteDataIfNeeded(_ data: Data) throws -> Data {
        guard let crypto = makeSyncCryptoFromDefaults() else { return data }
        // 加密模式下，数据必须是合法的 EncryptedPayload；不允许静默降级
        guard let payload = try? JSONDecoder.wuyan.decode(EncryptedPayload.self, from: data),
              let ciphertext = Data(base64Encoded: payload.ciphertextBase64)
        else {
            throw SyncError.decryptFailed(reason: "远端媒体数据不是合法的加密格式")
        }
        do {
            let key = try crypto.key(forSaltBase64: payload.saltBase64, iterations: payload.iterations)
            return try crypto.box.open(ciphertext, key: key)
        } catch {
            throw SyncError.decryptFailed(reason: "媒体解密失败：\(error.localizedDescription)")
        }
    }
}
