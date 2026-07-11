import Foundation
import Combine

/// 同步/归档/下载的管理器，从 AppState 中剥离。
/// @MainActor ObservableObject，RootView 注入环境。
@MainActor
final class SyncCoordinator: ObservableObject {
    let db: AppDatabase
    let entries: EntryDAO
    let mediaStore: LocalMediaStore

    @Published var syncMessage: String?
    @Published var syncProgress: SyncProgress?
    @Published var syncConflicts: [UUID] = []
    /// 同步内部错误状态。外部应通过 AppState.errorMessage 读取（已通过 onError 转发）。
    @Published private(set) var errorMessage: String?

    /// R0-1: 同步错误回调。由 AppState 注册，将错误统一汇聚到 AppState.errorMessage，
    /// 确保 RootView 的全局 alert 能弹出同步失败信息。
    var onError: (@MainActor (String) -> Void)?

    /// R0-2: 归档完成回调。参数为归档年份，由 AppState 注册以更新 archivedYears。
    var onArchiveComplete: (@MainActor (Int) -> Void)?

    /// R0-2: 下载完成回调。参数为下载年份，由 AppState 注册以更新 archivedYears。
    var onDownloadComplete: (@MainActor (Int) -> Void)?

    /// 设置同步错误信息，同时通过 onError 回调通知 AppState。
    private func setSyncError(_ message: String) {
        errorMessage = message
        onError?(message)
    }

    /// 清空同步错误（开始新一轮同步/归档/下载时调用）。
    private func clearSyncError() {
        errorMessage = nil
    }

    // MARK: - 自动同步

    /// 编辑防抖定时器：上次保存后 5 分钟自动同步
    private var editDebounceTask: Task<Void, Never>?
    private static let editDebounceInterval: Duration = .seconds(300) // 5 minutes

    /// 启动后自动同步延迟
    private static let startupSyncDelay: Duration = .seconds(10)

    /// 通知编辑已完成，触发防抖自动同步
    func notifyEditCompleted() {
        editDebounceTask?.cancel()
        editDebounceTask = Task {
            try? await Task.sleep(for: Self.editDebounceInterval)
            guard !Task.isCancelled else { return }
            WuyanLog.sync.info("编辑防抖触发自动同步")
            autoSyncIfConfigured()
        }
    }

    /// 启动后延迟自动同步（由 WuyanApp.onAppear 调用一次）
    func scheduleStartupSync() {
        Task {
            try? await Task.sleep(for: Self.startupSyncDelay)
            guard !Task.isCancelled else { return }
            WuyanLog.sync.info("启动后延迟自动同步")
            autoSyncIfConfigured()
        }
    }

    /// 系统从睡眠恢复后自动同步
    func handleWakeFromSleep() {
        WuyanLog.sync.info("系统从睡眠恢复，触发自动同步")
        autoSyncIfConfigured()
    }

    /// 仅在已配置存储后端时执行自动同步
    private func autoSyncIfConfigured() {
        // 如果没配置 WebDAV/S3，静默跳过
        guard let _ = try? ProviderFactory.makeRemoteStorageProvider() else { return }
        guard syncProgress == nil else { return } // 正在同步中，不重复触发
        let archivedYears = UserDefaults.standard.array(forKey: "archive.years") as? [Int] ?? []
        syncNow(archivedYears: Set(archivedYears))
    }

    init(database: AppDatabase) {
        self.db = database
        self.entries = database.entryDAO
        self.mediaStore = try! LocalMediaStore(database: database)
    }

    func syncNow(archivedYears: Set<Int>) {
        guard syncProgress == nil else { return }
        WuyanLog.sync.info("开始同步，归档年份: \(archivedYears.map(String.init).joined(separator: ","))")
        syncMessage = "同步中…"
        syncProgress = SyncProgress(phase: "准备同步", completedUnitCount: 0, totalUnitCount: 1)
        syncConflicts = []
        clearSyncError()

        let provider: any RemoteStorageProvider
        do {
            provider = try ProviderFactory.makeRemoteStorageProvider()
        } catch {
            syncMessage = nil
            syncProgress = nil
            setSyncError(error.localizedDescription)
            return
        }
        if AppSettings.cryptoEnabled {
            let passphrase = SecureSettings.load(SecureSettingKey.syncPassphrase, legacyDefaultsKey: SecureSettingKey.legacySyncPassphrase)
            if passphrase.isEmpty {
                syncMessage = nil
                syncProgress = nil
                setSyncError("请先在设置中填写同步加密口令。")
                return
            }
        }
        let dbRef = db
        let fingerprint = ProviderFactory.backendFingerprint()
        Task {
            let crypto = ProviderFactory.makeSyncCrypto()
            let engine = SyncEngine(provider: provider, database: dbRef, crypto: crypto, archivedYears: archivedYears, backendFingerprint: fingerprint) { progress in
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
                    self.syncConflicts = report.conflicts
                    let conflictText = report.conflicts.isEmpty ? "" : "，冲突 \(report.conflicts.count)"
                    self.syncMessage = "同步完成：推送 \(report.pushed)，拉取 \(report.pulled)，媒体 \(report.mediaUploaded)\(conflictText)。"
                    self.syncProgress = nil
                    WuyanLog.sync.info("同步完成：推送\(report.pushed)，拉取\(report.pulled)，媒体\(report.mediaUploaded)，冲突\(report.conflicts.count)")
                }
            } catch {
                await MainActor.run {
                    self.syncMessage = nil
                    self.syncProgress = nil
                    self.setSyncError(error.localizedDescription)
                    WuyanLog.sync.error("同步失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func archiveYearToRemote(_ year: Int, archivedYears: Set<Int>) {
        guard syncProgress == nil else { return }
        syncMessage = "\(year) 年归档中…"
        syncProgress = SyncProgress(phase: "\(year) 年归档准备中", completedUnitCount: 0, totalUnitCount: 1)
        clearSyncError()

        let provider: any RemoteStorageProvider
        do {
            provider = try ProviderFactory.makeRemoteStorageProvider()
        } catch {
            syncMessage = nil
            syncProgress = nil
            setSyncError(error.localizedDescription)
            return
        }
        let database = db
        let mediaStore = mediaStore
        let fingerprint = ProviderFactory.backendFingerprint()
        Task {
            let crypto = ProviderFactory.makeSyncCrypto()
            do {
                let yearEntries = try entries.timeline(filter: .year(year))
                let engine = SyncEngine(provider: provider, database: database, crypto: crypto, archivedYears: archivedYears, backendFingerprint: fingerprint) { progress in
                    await MainActor.run {
                        self.syncProgress = progress
                        self.syncMessage = "\(year) 年归档：\(progress.phase)"
                    }
                }
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
                    syncMessage = "\(year) 年归档完成：上传媒体 \(uploaded)，清理本地附件 \(removed)，已删除本地 \(yearEntries.count) 篇日记。"
                    syncProgress = nil
                    // R0-2: 通知 AppState 将该年加入 archivedYears
                    onArchiveComplete?(year)
                }
            } catch {
                await MainActor.run {
                    self.syncMessage = nil
                    self.syncProgress = nil
                    self.setSyncError(error.localizedDescription)
                }
            }
        }
    }

    func downloadYearFromRemote(_ year: Int) {
        guard syncProgress == nil else { return }
        syncMessage = "\(year) 年下载中…"
        syncProgress = SyncProgress(phase: "\(year) 年下载准备中", completedUnitCount: 0, totalUnitCount: 1)
        clearSyncError()

        let provider: any RemoteStorageProvider
        do {
            provider = try ProviderFactory.makeRemoteStorageProvider()
        } catch {
            syncMessage = nil
            syncProgress = nil
            setSyncError(error.localizedDescription)
            return
        }
        let database = db
        let fingerprint = ProviderFactory.backendFingerprint()
        Task {
            let crypto = ProviderFactory.makeSyncCrypto()
            do {
                let engine = SyncEngine(provider: provider, database: database, crypto: crypto, archivedYears: Set(), backendFingerprint: fingerprint) { progress in
                    await MainActor.run {
                        self.syncProgress = progress
                        self.syncMessage = "\(year) 年下载：\(progress.phase)"
                    }
                }
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
                    syncMessage = "\(year) 年下载完成：本地附件 \(downloaded)。"
                    syncProgress = nil
                    // R0-2: 通知 AppState 将该年从 archivedYears 移除
                    onDownloadComplete?(year)
                }
            } catch {
                await MainActor.run {
                    self.syncMessage = nil
                    self.syncProgress = nil
                    self.setSyncError(error.localizedDescription)
                }
            }
        }
    }

    func downloadMediaIfNeeded(_ asset: MediaAsset) async throws -> URL? {
        if let localPath = asset.localPath {
            let absolutePath = LocalMediaStore.resolvePath(localPath)
            if FileManager.default.fileExists(atPath: absolutePath) {
                return URL(fileURLWithPath: absolutePath)
            }
        }

        let provider = try ProviderFactory.makeRemoteStorageProvider()
        let plainPath = SyncPaths.mediaPath(sha256: asset.sha256, filename: asset.filename)
        let encPath = SyncPaths.encryptedMediaPath(sha256: asset.sha256, filename: asset.filename)

        if (try? await provider.contentLength(plainPath)) != nil {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("wuyan-download-\(asset.sha256)")
            try await provider.getResumable(plainPath, into: tempURL)
            return try mediaStore.storeRemoteMediaFile(movingFrom: tempURL, for: asset)
        }

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

        let provider = try ProviderFactory.makeRemoteStorageProvider()
        let data = try await provider.get(SyncPaths.thumbnailPath(sha256: asset.sha256))
        try mediaStore.storeRemoteThumbnail(data, for: asset)
        return true
    }

    private static func decryptRemoteDataIfNeeded(_ data: Data) throws -> Data {
        guard let crypto = ProviderFactory.makeSyncCrypto() else { return data }
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
