import CryptoKit
import Foundation
import Combine

/// 同步/归档/下载的管理器，从 AppState 中剥离。
/// @MainActor ObservableObject，RootView 注入环境。
@MainActor
final class SyncCoordinator: ObservableObject {
    let db: AppDatabase
    let entries: EntryDAO
    /// R1-6: 共享 AppState 的 mediaStore，不再独立创建实例
    let mediaStore: LocalMediaStore
    private let rescueMode: Bool

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

    /// UI-02：归档流程结束回调（无论成败）。AppState 用于解除该年份的编辑锁定。
    var onArchiveFinished: (@MainActor (Int) -> Void)?

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

    /// 进度发布统一入口：值未变化不重复 set。@Published 每次 set 都会触发
    /// objectWillChange 并把整棵视图树拖着重算，同步进度连发时足以打满主线程。
    private func publish(progress: SyncProgress?, message: String?) {
        if syncProgress != progress { syncProgress = progress }
        if syncMessage != message { syncMessage = message }
    }

    /// 编辑防抖定时器：上次保存后 5 分钟自动同步
    private var editDebounceTask: Task<Void, Never>?
    private static let editDebounceInterval: Duration = .seconds(300) // 5 minutes

    /// 启动后自动同步延迟
    private static let startupSyncDelay: Duration = .seconds(10)

    /// 通知编辑已完成，触发防抖自动同步
    func notifyEditCompleted() {
        guard !rescueMode else { return }
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
        guard !rescueMode else { return }
        Task {
            try? await Task.sleep(for: Self.startupSyncDelay)
            guard !Task.isCancelled else { return }
            WuyanLog.sync.info("启动后延迟自动同步")
            autoSyncIfConfigured()
        }
    }

    /// 系统从睡眠恢复后自动同步
    func handleWakeFromSleep() {
        guard !rescueMode else { return }
        WuyanLog.sync.info("系统从睡眠恢复，触发自动同步")
        autoSyncIfConfigured()
    }

    /// 仅在已配置存储后端时执行自动同步
    /// R1-5: 用轻量 UserDefaults 检查替代 makeRemoteStorageProvider() 构建，
    /// 避免每次自动同步探测都触发 Keychain 读取。
    private func autoSyncIfConfigured() {
        guard !rescueMode else {
            setSyncError("救援模式：自动同步已禁用。")
            return
        }
        let backend = AppSettings.storageBackend
        let configured: Bool
        if backend == "s3" {
            configured = !AppSettings.s3Endpoint.isEmpty && !AppSettings.s3AccessKey.isEmpty
        } else {
            configured = !AppSettings.webDAVBaseURL.isEmpty && !AppSettings.webDAVUsername.isEmpty
        }
        guard configured else { return }
        guard syncProgress == nil else { return }
        let archivedYears = UserDefaults.standard.array(forKey: "archive.years") as? [Int] ?? []
        syncNow(archivedYears: Set(archivedYears))
    }

    /// R0-5: 加密口令预检。当 cryptoEnabled 时验证口令非空。
    /// 返回 false 表示口令缺失，调用方应 early return。已清空 syncMessage/syncProgress 并设置错误。
    private func checkCryptoPassphrase() -> Bool {
        guard AppSettings.cryptoEnabled else { return true }
        let passphrase = SecureSettings.load(SecureSettingKey.syncPassphrase, legacyDefaultsKey: SecureSettingKey.legacySyncPassphrase)
        if passphrase.isEmpty {
            syncMessage = nil
            syncProgress = nil
            setSyncError("请先在设置中填写同步加密口令。")
            return false
        }
        return true
    }

    init(database: AppDatabase, mediaStore: LocalMediaStore, rescueMode: Bool = false) {
        self.db = database
        self.entries = database.entryDAO
        self.mediaStore = mediaStore
        self.rescueMode = rescueMode
    }

    func syncNow(archivedYears: Set<Int>) {
        guard !rescueMode else {
            setSyncError("救援模式：同步已禁用。")
            return
        }
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
        // R0-5: 加密守卫（统一提取）
        guard checkCryptoPassphrase() else { return }
        let dbRef = db
        let fingerprint = ProviderFactory.backendFingerprint()
        Task {
            let crypto = ProviderFactory.makeSyncCrypto()
            let engine = SyncEngine(provider: provider, database: dbRef, crypto: crypto, archivedYears: archivedYears, backendFingerprint: fingerprint) { progress in
                await MainActor.run {
                    let message: String
                    if let detail = progress.detail, !detail.isEmpty {
                        message = "\(progress.phase)：\(detail)"
                    } else {
                        message = progress.phase
                    }
                    self.publish(progress: progress, message: message)
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

    // MARK: - UI-01：加密口令管理（数据密钥协议）

    /// 更换加密口令：用旧口令解包数据密钥验证身份，仅重写远端索引头（数据不动）。
    /// 全部成功后才把新口令写入 Keychain；任一步失败旧口令保持不变。
    func changeCryptoPassphrase(currentPassphrase: String, newPassphrase: String, completion: (@MainActor (String) -> Void)? = nil) {
        guard !rescueMode else {
            completion?("救援模式：加密配置操作已禁用。")
            return
        }
        guard syncProgress == nil else {
            completion?("同步进行中，请稍后再试。")
            return
        }
        guard !newPassphrase.isEmpty else {
            completion?("新口令不能为空。")
            return
        }
        guard currentPassphrase != newPassphrase else {
            completion?("新口令与当前口令相同。")
            return
        }
        let keychainOld = SecureSettings.load(SecureSettingKey.syncPassphrase, legacyDefaultsKey: SecureSettingKey.legacySyncPassphrase)
        // 输入的当前口令必须与 Keychain 中保存的一致，防止误操作
        guard currentPassphrase == keychainOld else {
            completion?("当前口令不正确。")
            return
        }
        Task {
            // 先确认新口令能写入并读回钥匙串，再触碰远端密钥头。
            // 远端重包装失败时恢复旧值，避免出现“远端新口令、本机旧口令”的不可用状态。
            guard SecureSettings.save(newPassphrase, for: SecureSettingKey.syncPassphrase, legacyDefaultsKey: SecureSettingKey.legacySyncPassphrase) else {
                await MainActor.run { completion?("新口令无法保存到钥匙串，远端未修改。") }
                return
            }
            do {
                let provider = try ProviderFactory.makeRemoteStorageProvider()
                let rewrote = try await SyncEngine.changePassphrase(
                    provider: provider,
                    oldPassphrase: currentPassphrase,
                    newPassphrase: newPassphrase
                )
                await MainActor.run {
                    completion?(rewrote ? "口令已更换：数据密钥已用新口令重新包装，日记数据无需重传。" : "口令已保存：远端还没有加密索引，将在下次加密同步时生效。")
                }
            } catch {
                _ = SecureSettings.save(currentPassphrase, for: SecureSettingKey.syncPassphrase, legacyDefaultsKey: SecureSettingKey.legacySyncPassphrase)
                await MainActor.run {
                    completion?("更换口令失败：\(error.localizedDescription)。旧口令保持不变。")
                }
            }
        }
    }

    /// 关闭加密：把远端全部对象与索引迁移为明文，成功后才关闭配置。
    /// 迁移期间禁止再次触发。
    func disableEncryptionMigration(completion: (@MainActor (String) -> Void)? = nil) {
        guard !rescueMode else {
            completion?("救援模式：加密迁移已禁用。")
            return
        }
        guard syncProgress == nil else {
            completion?("同步进行中，请稍后再试。")
            return
        }
        guard let crypto = ProviderFactory.makeSyncCrypto() else {
            completion?("未找到加密口令，无法读取远端密文。")
            return
        }
        let provider: any RemoteStorageProvider
        do {
            provider = try ProviderFactory.makeRemoteStorageProvider()
        } catch {
            completion?(error.localizedDescription)
            return
        }
        clearSyncError()
        syncMessage = "正在关闭加密：迁移远端数据为明文…"
        syncProgress = SyncProgress(phase: "关闭加密迁移", completedUnitCount: 0, totalUnitCount: 1)
        let dbRef = db
        let fingerprint = ProviderFactory.backendFingerprint()
        Task {
            do {
                let engine = SyncEngine(
                    provider: provider, database: dbRef, crypto: crypto,
                    archivedYears: [], backendFingerprint: fingerprint,
                    plaintextMigration: true
                ) { progress in
                    await MainActor.run {
                        self.syncProgress = progress
                        self.syncMessage = progress.phase
                    }
                }
                _ = try await engine.syncNow()
                UserDefaults.standard.set(false, forKey: SettingKey.cryptoEnabled)
                await MainActor.run {
                    self.syncProgress = nil
                    self.syncMessage = "已关闭加密：远端数据已全部迁移为明文。"
                    completion?("已关闭加密：远端数据已全部迁移为明文。")
                }
            } catch {
                await MainActor.run {
                    self.syncProgress = nil
                    self.setSyncError("关闭加密失败：\(error.localizedDescription)。加密配置保持不变。")
                    completion?("关闭加密失败：\(error.localizedDescription)。加密配置保持不变。")
                }
            }
        }
    }

    // MARK: - 归档与下载

    func archiveYearToRemote(_ year: Int, archivedYears: Set<Int>) {
        guard !rescueMode else {
            setSyncError("救援模式：归档已禁用。")
            return
        }
        guard syncProgress == nil else { return }
        syncMessage = "\(year) 年归档中…"
        syncProgress = SyncProgress(phase: "\(year) 年归档准备中", completedUnitCount: 0, totalUnitCount: 1)
        clearSyncError()

        // R0-5: 加密守卫——归档前必须验证加密口令
        guard checkCryptoPassphrase() else { return }

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
                let engine = SyncEngine(provider: provider, database: database, crypto: crypto, archivedYears: archivedYears, backendFingerprint: fingerprint) { progress in
                    await MainActor.run {
                        self.publish(progress: progress, message: "\(year) 年归档：\(progress.phase)")
                    }
                }
                // UI-02：引擎已完成推送 + 读回校验；只根据验证通过的快照清理本地。
                let result = try await engine.archiveYear(year)
                let uploaded = result.report.mediaUploaded
                var removed = 0
                var skippedEdits = 0
                for entry in result.pushedEntries {
                    await MainActor.run {
                        self.syncProgress = SyncProgress(
                            phase: "正在清理本地内容",
                            completedUnitCount: 0,
                            totalUnitCount: max(1, result.pushedEntries.count),
                            detail: entry.dayDate
                        )
                    }
                    // 归档期间被再次编辑的条目不删（指纹与推送版本不一致），保留待下次归档
                    guard let current = try database.entryDAO.entry(id: entry.id),
                          current.contentHash == entry.contentHash else {
                        skippedEdits += 1
                        continue
                    }
                    let assets = try database.mediaAssetDAO.allAssets(for: entry.mediaIds)
                    for asset in assets {
                        // 共享媒体：仍被其它条目引用的本地文件不删
                        let refCount = try database.mediaAssetDAO.referenceCount(sha256: asset.sha256)
                        if refCount <= 1 {
                            try mediaStore.removeLocalFiles(for: asset)
                            removed += 1
                        }
                    }
                    // 归档是本地副本清理，不是同步删除；不能写入墓碑，否则下一轮同步
                    // 会把已经归档的远端条目标记为 deleted。
                    try database.entryDAO.removeArchivedLocal(id: entry.id)
                }

                await MainActor.run {
                    self.syncProgress = SyncProgress(phase: "正在删除本地内容", completedUnitCount: 0, totalUnitCount: 1)
                    self.syncMessage = "\(year) 年归档：正在删除本地内容"
                }
                // 日札只删「与推送版本一致」的——归档期间被编辑的不动
                let yearPrefix = String(format: "%04d-", year)
                let freshNotes = try database.dayNoteDAO.all().filter { $0.date.hasPrefix(yearPrefix) }
                let pushedNoteHashes = Set(result.pushedNotes.map { Hashing.dayNoteHash($0) })
                for note in freshNotes where pushedNoteHashes.contains(Hashing.dayNoteHash(note)) {
                    try database.dayNoteDAO.delete(dayKey: note.date)
                }

                await MainActor.run {
                    let skipText = skippedEdits > 0 ? "，\(skippedEdits) 篇因归档期间被编辑而保留本地" : ""
                    syncMessage = "\(year) 年归档完成：上传媒体 \(uploaded)，清理本地附件 \(removed)，已删除本地 \(result.pushedEntries.count - skippedEdits) 篇日记\(skipText)。"
                    syncProgress = nil
                    // R0-2: 通知 AppState 将该年加入 archivedYears
                    onArchiveComplete?(year)
                    onArchiveFinished?(year)
                }
            } catch {
                await MainActor.run {
                    self.syncMessage = nil
                    self.syncProgress = nil
                    self.setSyncError(error.localizedDescription)
                    onArchiveFinished?(year)
                }
            }
        }
    }

    func downloadYearFromRemote(_ year: Int) {
        guard !rescueMode else {
            setSyncError("救援模式：下载已禁用。")
            return
        }
        guard syncProgress == nil else { return }
        syncMessage = "\(year) 年下载中…"
        syncProgress = SyncProgress(phase: "\(year) 年下载准备中", completedUnitCount: 0, totalUnitCount: 1)
        clearSyncError()

        // R0-5: 加密守卫——下载前必须验证加密口令
        guard checkCryptoPassphrase() else { return }

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
                        self.publish(progress: progress, message: "\(year) 年下载：\(progress.phase)")
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
        guard !rescueMode else { throw SyncError.rescueModeDisabled }
        // R2-1: 使用模型层计算属性替代 LocalMediaStore.resolvePath
        if let absolutePath = asset.absoluteLocalPath {
            if FileManager.default.fileExists(atPath: absolutePath) {
                return URL(fileURLWithPath: absolutePath)
            }
        }

        let provider = try ProviderFactory.makeRemoteStorageProvider()
        let crypto = try await ensureCryptoUnlocked(provider: provider)
        let plainPath = SyncPaths.mediaPath(sha256: asset.sha256, filename: asset.filename)
        let encPath = SyncPaths.encryptedMediaPath(sha256: asset.sha256, filename: asset.filename)

        if (try? await provider.contentLength(plainPath)) != nil {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("wuyan-download-\(asset.sha256)")
            // A05：续传下载落位前对照资产 SHA-256，损坏分片拼出的内容不会被当成附件。
            try await provider.getResumable(plainPath, into: tempURL, expectedSHA256: asset.sha256)
            return try mediaStore.storeRemoteMediaFile(movingFrom: tempURL, for: asset)
        }

        let data = try await provider.get(encPath)
        return try mediaStore.storeRemoteMedia(try decryptRemoteDataIfNeeded(data, crypto: crypto), for: asset)
    }

    private func downloadThumbnailIfNeeded(_ asset: MediaAsset) async throws -> Bool {
        // R2-1: 使用模型层计算属性替代 LocalMediaStore.resolvePath
        if let absolutePath = asset.absoluteThumbnailPath {
            if FileManager.default.fileExists(atPath: absolutePath) {
                return true
            }
        }

        let provider = try ProviderFactory.makeRemoteStorageProvider()
        let crypto = try await ensureCryptoUnlocked(provider: provider)
        let data = try await provider.get(SyncPaths.thumbnailPath(sha256: asset.sha256))
        // S02：加密模式下缩略图以加密负载形式上传，下载侧必须对称解密。
        // 仅当数据「无法解析为加密负载」时按历史明文对象处理（启用加密前的旧缩略图）；
        // 能解析但解密失败（口令不对）必须报错，绝不能把密文当图片写进本地。
        let payload = try? JSONDecoder.wuyan.decode(EncryptedPayload.self, from: data)
        let isEncryptedPayload = payload.flatMap { Data(base64Encoded: $0.ciphertextBase64) } != nil
        let thumbnailData: Data
        if isEncryptedPayload {
            thumbnailData = try decryptRemoteDataIfNeeded(data, crypto: crypto)
        } else {
            if crypto != nil {
                WuyanLog.media.warning("缩略图不是加密负载，按历史明文对象处理：\(asset.sha256.prefix(8))")
            }
            thumbnailData = data
        }
        try mediaStore.storeRemoteThumbnail(thumbnailData, for: asset)
        return true
    }

    /// UI-01：媒体下载前确保数据密钥已解锁（从远端索引密钥头读取，按 keyId 缓存，幂等）。
    /// 未启用加密返回 nil；旧版索引（无密钥头）返回未解锁的 crypto，对象按 v1/v2 路径解密。
    private func ensureCryptoUnlocked(provider: any RemoteStorageProvider) async throws -> SyncCrypto? {
        guard let crypto = ProviderFactory.makeSyncCrypto() else { return nil }
        if crypto.currentHeader != nil { return crypto }
        guard try await provider.exists(SyncPaths.manifest) else { return crypto }
        let data = try await provider.get(SyncPaths.manifest)
        if let container = try? JSONDecoder.wuyan.decode(ManifestContainer.self, from: data),
           let header = container.crypto,
           header.wrappedDekBase64 != nil {
            try crypto.unlock(with: header)
        }
        return crypto
    }

    private func decryptRemoteDataIfNeeded(_ data: Data, crypto: SyncCrypto?) throws -> Data {
        guard let crypto else { return data }
        guard let payload = try? JSONDecoder.wuyan.decode(EncryptedPayload.self, from: data),
              let ciphertext = Data(base64Encoded: payload.ciphertextBase64)
        else {
            throw SyncError.decryptFailed(reason: "远端媒体数据不是合法的加密格式")
        }
        do {
            let key: SymmetricKey
            if payload.schemaVersion >= 3 {
                // UI-01：数据密钥协议对象
                key = try crypto.dekForKeyId(payload.keyId)
            } else {
                key = try crypto.key(forSaltBase64: payload.saltBase64 ?? "", iterations: payload.iterations ?? 0)
            }
            return try crypto.box.open(ciphertext, key: key)
        } catch let e as SyncError {
            throw e
        } catch {
            throw SyncError.decryptFailed(reason: "媒体解密失败：\(error.localizedDescription)")
        }
    }
}
