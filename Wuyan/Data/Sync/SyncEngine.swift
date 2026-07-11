import CryptoKit
import Foundation

enum SyncError: LocalizedError {
    case decryptFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case let .decryptFailed(reason):
            return "同步解密失败：\(reason)"
        }
    }
}

actor SyncEngine {
    typealias ProgressHandler = @Sendable (SyncProgress) async -> Void

    private let provider: RemoteStorageProvider
    private let database: AppDatabase
    private let crypto: SyncCrypto?
    private let progressHandler: ProgressHandler?
    private let encoder = JSONEncoder.wuyan
    private let decoder = JSONDecoder.wuyan
    // 已归档的年份：全量同步时不再把这些年份从远端拉回本地（否则归档后又被同步回来，白腾空间）。
    private let archivedYears: Set<Int>
    private(set) var status: SyncStatus = .idle
    // 本次同步内懒加载的「已上传媒体路径」缓存；跨多次 uploadMedia 复用，避免重复探测/写入。
    private var mediaCache: Set<String>?
    /// 后端指纹：用于区分不同的远端配置（避免切换 NAS/账号后旧水位线跳过拉取）
    private let backendFingerprint: String
    /// R0-7: 明文→加密迁移标记。当 decodeRaw 检测到远端有明文数据时设置，
    /// syncNow 完成后会自动用加密方式重新上传所有条目。
    private var cryptoNeedsReEncrypt = false

    init(
        provider: RemoteStorageProvider,
        database: AppDatabase,
        crypto: SyncCrypto? = nil,
        archivedYears: Set<Int> = [],
        backendFingerprint: String,
        progressHandler: ProgressHandler? = nil
    ) {
        self.provider = provider
        self.database = database
        self.crypto = crypto
        self.archivedYears = archivedYears
        self.progressHandler = progressHandler
        // R2-5: 空指纹回退全局 key 的路径已删除；空串时从 ProviderFactory 动态推导
        self.backendFingerprint = backendFingerprint.isEmpty
            ? ProviderFactory.backendFingerprint()
            : backendFingerprint
    }

    private func year(ofDayKey key: String) -> Int? {
        Int(key.prefix(4))
    }

    func enqueueDirty() {
        Task {
            try? await syncNow()
        }
    }

    func syncNow() async throws -> SyncReport {
        status = .syncing
        var progress = SyncProgress(phase: "准备同步", completedUnitCount: 0, totalUnitCount: 7)
        do {
            await self.report(progress)
            try await ensureRemoteTree()
            progress.completedUnitCount += 1
            progress.phase = "正在读取远端索引"
            await self.report(progress)

            var manifest = try await loadManifest()

            // 一次性把本地快照/基线/日札哈希/媒体缓存读入内存，避免在下面比对时
            // 对每条远端记录都各查一次库（这是原先「读全盘」的主要本地开销）。
            let snapshots = try database.entryDAO.allSyncSnapshots()
            let baselines = try database.entryDAO.allBaselineHashes()
            let dayNotes = try database.dayNoteDAO.all()
            let dayNoteHashes = Dictionary(
                dayNotes.map { ($0.date, Hashing.dayNoteHash($0)) },
                uniquingKeysWith: { first, _ in first }
            )
            mediaCache = try database.mediaAssetDAO.uploadedPaths()

            let dirtyEntries = try database.entryDAO.dirtyEntries()
            let dayNotesToPush = dayNotes.filter { note in
                Hashing.dayNoteHash(note) != manifest.daynotes.first(where: { $0.date == note.date })?.hash
            }

            // 远端指纹与上次同步一致：说明自上次没有任何条目/日札变化，跳过整个拉取阶段
            // （本地 dirty 仍照常推送）。任一远端改动都会刷新对应 updatedAt，从而改变指纹。
            let remoteUnchanged = manifest.revision != nil && manifest.revision == Self.lastManifestRevision(forKey: revisionKey)

            let pullUnits = remoteUnchanged ? 0 : manifest.entries.count + manifest.daynotes.count
            let totalUnits = max(1, 7 + pullUnits + dirtyEntries.count + dayNotesToPush.count)
            progress = SyncProgress(
                phase: remoteUnchanged ? "远端无变化，跳过拉取" : "正在拉取远端日记",
                completedUnitCount: 2,
                totalUnitCount: totalUnits
            )
            await self.report(progress)

            var report = SyncReport()
            if remoteUnchanged {
                // 无变化：直接推进进度，不遍历 manifest。
                progress.completedUnitCount += pullUnits
            } else {
                report.pulled += try await pullRemoteChanges(
                    from: manifest, snapshots: snapshots, baselines: baselines, report: &report, progress: &progress
                )
                progress.phase = "正在同步日札"
                await self.report(progress)
                report.pulled += try await pullRemoteDayNotes(from: manifest, localHashes: dayNoteHashes, progress: &progress)
            }
            progress.phase = "正在推送本地日记"
            await self.report(progress)
            report.pushed += try await pushDirtyEntries(dirtyEntries, into: &manifest, report: &report, progress: &progress)
            progress.phase = "正在推送日札"
            await self.report(progress)
            report.pushed += try await pushDayNotes(dayNotesToPush, into: &manifest, progress: &progress)
            progress.phase = "正在保存同步索引"
            await self.report(progress)
            // 先裁剪陈旧墓碑，再据裁剪后的内容计算指纹，保证「无变化」时指纹稳定不抖动。
            manifest = pruneManifest(manifest)
            manifest.boards = try database.boardDAO.all()

            // R0-7: 明文→加密迁移——如果拉取阶段检测到远端有明文数据，
            // 用加密格式重新上传全部条目和日札，覆盖远端明文。
            if cryptoNeedsReEncrypt {
                progress.phase = "正在迁移远端明文→加密"
                await self.report(progress)
                let allEntries = try database.entryDAO.timeline(filter: .all)
                let allDayNotes = try database.dayNoteDAO.all()
                var migrationProgress = SyncProgress(
                    phase: "明文→加密迁移",
                    completedUnitCount: 0,
                    totalUnitCount: max(1, allEntries.count + allDayNotes.count)
                )
                var migrationReport = SyncReport()
                _ = try await pushDirtyEntries(allEntries, into: &manifest, report: &migrationReport, progress: &migrationProgress)
                try await pushDayNotes(allDayNotes, into: &manifest, progress: &migrationProgress)
                manifest.boards = try database.boardDAO.all()
                WuyanLog.sync.info("明文→加密迁移完成，已重新上传 \(allEntries.count) 条目和 \(allDayNotes.count) 日札")
            }

            let savedRevision = try await saveManifest(manifest)
            Self.storeLastRevision(savedRevision, forKey: revisionKey)
            progress.completedUnitCount += 1
            progress.phase = "正在记录同步状态"
            await self.report(progress)
            try await saveDeviceState(report)
            progress.completedUnitCount = progress.totalUnitCount
            progress.phase = "同步完成"
            progress.detail = "推送 \(report.pushed)，拉取 \(report.pulled)，媒体 \(report.mediaUploaded)"
            await self.report(progress)
            status = .idle
            return report
        } catch {
            status = .error(error.localizedDescription)
            throw error
        }
    }

    /// 按年归档：把「这一年」的全部日记/日札/附件推送到远端（不只 dirty —— 本地随后要删除，
    /// 必须确保都已落到 NAS）。不做全量双向同步，也不拉取或改动其它年份。
    func archiveYear(_ year: Int) async throws -> SyncReport {
        status = .syncing
        var progress = SyncProgress(phase: "\(year) 年归档准备中", completedUnitCount: 0, totalUnitCount: 1)
        do {
            await self.report(progress)
            try await ensureRemoteTree()
            var manifest = try await loadManifest()

            // 推送本年「全部」条目（pushDirtyEntries 会逐条上传附件并更新索引），而非只推 dirty。
            let yearEntries = try database.entryDAO.timeline(filter: .year(year))
            let yearPrefix = String(format: "%04d-", year)
            let yearNotes = try database.dayNoteDAO.all().filter { $0.date.hasPrefix(yearPrefix) }

            var report = SyncReport()
            progress = SyncProgress(
                phase: "正在推送本年日记与附件",
                completedUnitCount: 0,
                totalUnitCount: max(1, yearEntries.count + yearNotes.count)
            )
            await self.report(progress)
            report.pushed += try await pushDirtyEntries(yearEntries, into: &manifest, report: &report, progress: &progress)
            progress.phase = "正在推送本年日札"
            await self.report(progress)
            report.pushed += try await pushDayNotes(yearNotes, into: &manifest, progress: &progress)

            manifest.boards = try database.boardDAO.all()
            try await saveManifest(manifest)
            progress.completedUnitCount = progress.totalUnitCount
            progress.phase = "归档推送完成"
            await self.report(progress)
            status = .idle
            return report
        } catch {
            status = .error(error.localizedDescription)
            throw error
        }
    }

    /// 按年拉取：把某一年的日记/日札从远端索引拉回本地（忽略「已归档跳过」规则）。
    /// 供「从已归档下载回本地」使用；附件由调用方按需下载。
    func pullYear(_ year: Int) async throws -> Int {
        status = .syncing
        do {
            try await ensureRemoteTree()
            let manifest = try await loadManifest()
            let prefix = String(format: "%04d-", year)
            var pulled = 0
            for board in manifest.boards where (try database.boardDAO.board(id: board.id)) == nil {
                try database.boardDAO.save(board)
            }
            for remote in manifest.entries where remote.dayDate.hasPrefix(prefix) && !remote.deleted {
                try await pullRemoteEntry(remote)
                pulled += 1
            }
            for remote in manifest.daynotes where remote.date.hasPrefix(prefix) {
                let data = try await provider.get(remote.path)
                let note = try decode(DayNote.self, from: data)
                try database.dayNoteDAO.upsert(note)
            }
            status = .idle
            return pulled
        } catch {
            status = .error(error.localizedDescription)
            throw error
        }
    }

    func uploadMedia(for entries: [Entry]) async throws -> Int {
        try await ensureRemoteTree()
        var uploaded = 0
        for entry in entries {
            uploaded += try await uploadMedia(for: entry)
        }
        return uploaded
    }

    private func ensureRemoteTree() async throws {
        // 目录树一旦建好就基本不会再消失：命中缓存时只做一次轻量存在性校验，
        // 替代原先每次同步都串行发十几个 MKCOL 的固定开销。校验失败说明目录被外部清掉，重建并刷新缓存。
        let key = backendFingerprint.isEmpty ? "sync.remoteTreeReady" : "sync.remoteTreeReady.\(backendFingerprint)"
        if UserDefaults.standard.bool(forKey: key) {
            if try await provider.exists("/Wuyan/.sync/") { return }
        }
        try await provider.mkcolRecursive("/Wuyan/entries/")
        try await provider.mkcolRecursive("/Wuyan/daynotes/")
        try await provider.mkcolRecursive("/Wuyan/media/")
        try await provider.mkcolRecursive("/Wuyan/media/thumbnails/")
        try await provider.mkcolRecursive("/Wuyan/.sync/")
        try await provider.mkcolRecursive("/Wuyan/.trash/")
        UserDefaults.standard.set(true, forKey: key)
    }

    private func loadManifest() async throws -> Manifest {
        guard try await provider.exists(SyncPaths.manifest) else {
            var manifest = Manifest()
            manifest.boards = try database.boardDAO.all()
            return manifest
        }
        let data = try await provider.get(SyncPaths.manifest)
        return try decode(Manifest.self, from: data)
    }

    // 写入 manifest 并返回其内容指纹 revision，供调用方持久化为「下次同步的水位线」。
    @discardableResult
    private func saveManifest(_ manifest: Manifest) async throws -> String {
        var manifest = manifest
        manifest.crypto = crypto?.manifestHeader
        manifest.revision = Self.computeRevision(entries: manifest.entries, daynotes: manifest.daynotes)
        let data = try encode(manifest)
        try await provider.put(SyncPaths.manifest, data: data, contentType: "application/json")
        return manifest.revision ?? ""
    }

    private func pullRemoteChanges(
        from manifest: Manifest,
        snapshots: [String: EntrySyncSnapshot],
        baselines: [String: String],
        report: inout SyncReport,
        progress: inout SyncProgress
    ) async throws -> Int {
        var count = 0
        for remote in manifest.entries {
            // 已归档年份：不拉回本地，保持本地腾空状态。
            if let y = year(ofDayKey: remote.dayDate), archivedYears.contains(y) {
                progress.completedUnitCount += 1
                continue
            }
            progress.detail = remote.dayDate
            await self.report(progress)

            let snap = snapshots[remote.id.uuidString]
            let baseline = baselines[remote.id.uuidString]

            if remote.deleted {
                if let snap {
                    // 远端已删除：若本地自上次同步后另有改动，先留存冲突副本，避免静默丢失。
                   if let baseline, baseline != snap.contentHash {
                      if let full = try database.entryDAO.entry(id: remote.id) {
                          try await writeConflictCopy(full)
                       report.conflicts.append(remote.id)
                       }
                   }
                   if !snap.deleted {
                        try database.entryDAO.softDelete(id: remote.id)
                        count += 1
                    }
                }
                progress.completedUnitCount += 1
                continue
            }

            guard let snap else {
                // 本地没有这条 → 拉取。
                try await pullRemoteEntry(remote)
                count += 1
                progress.completedUnitCount += 1
                continue
            }

            if snap.contentHash == remote.hash {
                // 完全一致，跳过。
                progress.completedUnitCount += 1
                continue
            }

            // 三方合并：以上次同步的 baseline 区分到底是哪一边变了。
            if baseline == remote.hash {
                // 远端自上次同步未变，仅本地改动 → 本地优先，留给推送阶段，不要拉取覆盖本地编辑。
            } else if baseline == snap.contentHash {
                // 本地自上次同步未变，仅远端改动 → 拉取远端。
                try await pullRemoteEntry(remote)
                count += 1
            } else {
                // 双方都变（或无 baseline 的独立创建）→ 冲突：留存本地副本后取远端。
                if let full = try database.entryDAO.entry(id: remote.id) {
                    try await writeConflictCopy(full)
                }
                report.conflicts.append(remote.id)
                try await pullRemoteEntry(remote)
                count += 1
            }
            progress.completedUnitCount += 1
        }
        progress.detail = nil
        await self.report(progress)
        return count
    }

    private func pullRemoteEntry(_ remote: ManifestEntry) async throws {
        let data = try await provider.get(remote.path)
        let envelope = try decode(EntryEnvelope.self, from: data)
        if let board = envelope.board, try database.boardDAO.board(id: board.id) == nil {
            try database.boardDAO.save(board)
        }
        if let dayNote = envelope.dayNote {
            try database.dayNoteDAO.upsert(dayNote)
        }
        try database.entryDAO.saveRemote(envelope.entry)
        try database.entryDAO.upsertBaseline(for: envelope.entry)
    }

    // manifest 内容指纹：仅由条目/日札的「计数 + 两侧最大 updatedAt」决定。
    // 这些值只有在内容真正变化时才会变，所以无操作的重复写入指纹稳定，可作为增量水位线。
    private static func computeRevision(entries: [ManifestEntry], daynotes: [ManifestDayNote]) -> String {
        let maxEntry = entries.map(\.updatedAt).max() ?? .distantPast
        let maxNote = daynotes.map(\.updatedAt).max() ?? .distantPast
        return "e\(entries.count)-\(Int(maxEntry.timeIntervalSince1970))|n\(daynotes.count)-\(Int(maxNote.timeIntervalSince1970))"
    }

    private static let revisionKeyBase = "sync.lastManifestRevision"

    private var revisionKey: String {
        backendFingerprint.isEmpty ? Self.revisionKeyBase : "\(Self.revisionKeyBase).\(backendFingerprint)"
    }

    private static func lastManifestRevision(forKey key: String) -> String? {
        let v = UserDefaults.standard.string(forKey: key)
        return (v?.isEmpty == false) ? v : nil
    }

    private static func storeLastRevision(_ revision: String?, forKey key: String) {
        UserDefaults.standard.set(revision, forKey: key)
    }

    // 裁剪陈旧的删除墓碑：超过保留期的 deleted 条目从索引里移除（只动索引，不碰数据文件），
    // 防止 manifest 随删除积累而无界膨胀。保留期内仍保留墓碑，保证其它设备能同步到删除动作。
    private func pruneManifest(_ manifest: Manifest, now: Date = Date(), retention: TimeInterval = 90 * 86_400) -> Manifest {
        var manifest = manifest
        let cutoff = now.addingTimeInterval(-retention)
        manifest.entries.removeAll { $0.deleted && $0.updatedAt < cutoff }
        return manifest
    }

    // 懒加载本机「已上传媒体路径」缓存：sync_uploaded 表 + 本次同步内新增。跨多次 uploadMedia 复用。
    private func uploadedCache() throws -> Set<String> {
        if let cache = mediaCache { return cache }
        let cache = try database.mediaAssetDAO.uploadedPaths()
        mediaCache = cache
        return cache
    }

    private func pullRemoteDayNotes(
        from manifest: Manifest,
        localHashes: [String: String],
        progress: inout SyncProgress
    ) async throws -> Int {
        var pulled = 0
        for remote in manifest.daynotes {
            if let y = year(ofDayKey: remote.date), archivedYears.contains(y) {
                progress.completedUnitCount += 1
                continue
            }
            progress.detail = remote.date
            await self.report(progress)
            // 用预算好的本地哈希表比对，避免对每条远端日札都查一次库。
            let localHash = localHashes[remote.date]
            if localHash == nil || localHash != remote.hash {
                let data = try await provider.get(remote.path)
                let note = try decode(DayNote.self, from: data)
                try database.dayNoteDAO.upsert(note)
                pulled += 1
            }
            progress.completedUnitCount += 1
        }
        progress.detail = nil
        await self.report(progress)
        return pulled
    }

    private func writeConflictCopy(_ entry: Entry) async throws {
        let path = "/Wuyan/entries/conflicts/\(entry.id.uuidString)-conflict-\(Int(Date().timeIntervalSince1970)).json"
        try await provider.mkcolRecursive("/Wuyan/entries/conflicts/")
        let data = try encode(EntryEnvelope(entry: entry, board: try database.boardDAO.board(id: entry.boardId), dayNote: try database.dayNoteDAO.note(dayKey: entry.dayDate)))
        try await provider.put(path, data: data, contentType: "application/json")
    }

    private func pushDirtyEntries(
        _ dirty: [Entry],
        into manifest: inout Manifest,
        report: inout SyncReport,
        progress: inout SyncProgress
    ) async throws -> Int {
        var pushed = 0
        for entry in dirty {
            progress.detail = entry.dayDate
            await self.report(progress)
            report.mediaUploaded += try await uploadMedia(for: entry)
            let path = SyncPaths.entryPath(entry)
            let parent = (path as NSString).deletingLastPathComponent
            try await provider.mkcolRecursive(parent + "/")
            let envelope = EntryEnvelope(
                entry: entry,
                board: try database.boardDAO.board(id: entry.boardId),
                dayNote: try database.dayNoteDAO.note(dayKey: entry.dayDate)
            )
            let data = try encode(envelope)
            try await provider.put(path, data: data, contentType: "application/json")
            try database.entryDAO.markClean(id: entry.id, expectedHash: entry.contentHash)
            let item = ManifestEntry(id: entry.id, boardId: entry.boardId, dayDate: entry.dayDate, path: path, updatedAt: entry.updatedAt, hash: entry.contentHash, deleted: entry.deleted)
            if let index = manifest.entries.firstIndex(where: { $0.id == entry.id }) {
                manifest.entries[index] = item
            } else {
                manifest.entries.append(item)
            }
            pushed += 1
            progress.completedUnitCount += 1
        }
        progress.detail = nil
        await self.report(progress)
        return pushed
    }

    private func pushDayNotes(
        _ notes: [DayNote],
        into manifest: inout Manifest,
        progress: inout SyncProgress
    ) async throws -> Int {
        var pushed = 0
        for note in notes {
            progress.detail = note.date
            await self.report(progress)
            let hash = Hashing.dayNoteHash(note)
            let path = SyncPaths.dayNotePath(note)
            let parent = (path as NSString).deletingLastPathComponent
            try await provider.mkcolRecursive(parent + "/")
            let data = try encode(note)
            try await provider.put(path, data: data, contentType: "application/json")
            let item = ManifestDayNote(date: note.date, path: path, updatedAt: note.createdAt, hash: hash)
            if let index = manifest.daynotes.firstIndex(where: { $0.date == note.date }) {
                manifest.daynotes[index] = item
            } else {
                manifest.daynotes.append(item)
            }
            pushed += 1
            progress.completedUnitCount += 1
        }
        progress.detail = nil
        await self.report(progress)
        return pushed
    }

    private func uploadMedia(for entry: Entry) async throws -> Int {
        let assets = try database.mediaAssetDAO.allAssets(for: entry.mediaIds)
        let cache = try uploadedCache()
        var uploaded = 0
        var newlyUploaded: [String] = []
        for asset in assets {
            guard let localPath = asset.localPath else { continue }
            // R2-1: 使用模型层计算属性替代 LocalMediaStore.resolvePath
            let absoluteLocalPath = asset.absoluteLocalPath!
            let remotePath = crypto == nil
                ? SyncPaths.mediaPath(sha256: asset.sha256, filename: asset.filename)
                : SyncPaths.encryptedMediaPath(sha256: asset.sha256, filename: asset.filename)
            // 内容寻址媒体一旦上传就永久存在：命中缓存直接跳过；未命中才探测一次远端，
            // 探测结果（在或刚传）都记进缓存，后续同步不再逐个 PROPFIND。
            if !cache.contains(remotePath) {
                if !(try await provider.exists(remotePath)) {
                    let parent = (remotePath as NSString).deletingLastPathComponent
                    try await provider.mkcolRecursive(parent + "/")
                    if crypto == nil {
                        try await provider.putResumable(remotePath, fileURL: URL(fileURLWithPath: absoluteLocalPath), chunkSize: 8 * 1024 * 1024)
                    } else {
                        let data = try Data(contentsOf: URL(fileURLWithPath: absoluteLocalPath))
                        try await provider.put(remotePath, data: try encodeRaw(data), contentType: "application/octet-stream")
                    }
                    uploaded += 1
                }
                newlyUploaded.append(remotePath)
                mediaCache?.insert(remotePath)
            }

            if let thumbnailPath = asset.thumbnailPath {
                // R2-1: 使用模型层计算属性替代 LocalMediaStore.resolvePath
                let absoluteThumbnailPath = asset.absoluteThumbnailPath!
                let thumbnailRemotePath = SyncPaths.thumbnailPath(sha256: asset.sha256)
                if !cache.contains(thumbnailRemotePath) {
                    if !(try await provider.exists(thumbnailRemotePath)) {
                        try await provider.mkcolRecursive("/Wuyan/media/thumbnails/")
                        try await provider.putChunked(thumbnailRemotePath, fileURL: URL(fileURLWithPath: absoluteThumbnailPath), chunkSize: 512 * 1024)
                        uploaded += 1
                    }
                    newlyUploaded.append(thumbnailRemotePath)
                    mediaCache?.insert(thumbnailRemotePath)
                }
            }
        }
        if !newlyUploaded.isEmpty {
            try database.mediaAssetDAO.recordUploaded(paths: newlyUploaded)
        }
        return uploaded
    }

    private func saveDeviceState(_ report: SyncReport) async throws {
        let deviceId = Self.deviceId()
        let state = SyncDeviceState(
            deviceId: deviceId,
            syncedAt: Date(),
            pushed: report.pushed,
            pulled: report.pulled,
            mediaUploaded: report.mediaUploaded,
            conflicts: report.conflicts
        )
        let data = try encode(state)
        try await provider.put(SyncPaths.deviceStatePath(deviceId: deviceId), data: data, contentType: "application/json")
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try encoder.encode(value)
        return try encodeRaw(data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let plaintext = try decodeRaw(data)
        return try decoder.decode(type, from: plaintext)
    }

    private func encodeRaw(_ data: Data) throws -> Data {
        guard let crypto else { return data }
        let ciphertext = try crypto.box.seal(data, key: crypto.key)
        let payload = EncryptedPayload(
            saltBase64: crypto.params.salt.base64EncodedString(),
            iterations: crypto.params.iterations,
            ciphertextBase64: ciphertext.base64EncodedString()
        )
        return try encoder.encode(payload)
    }

    private func decodeRaw(_ data: Data) throws -> Data {
        guard let crypto else { return data }
        // 加密模式下，优先尝试解密 EncryptedPayload。
        if let payload = try? decoder.decode(EncryptedPayload.self, from: data),
           let ciphertext = Data(base64Encoded: payload.ciphertextBase64) {
            do {
                let key = try crypto.key(forSaltBase64: payload.saltBase64, iterations: payload.iterations)
                return try crypto.box.open(ciphertext, key: key)
            } catch {
                throw SyncError.decryptFailed(reason: "解密失败：口令可能不正确（\(error.localizedDescription)）")
            }
        }
        // R0-7: 明文→加密迁移宽容处理——如果数据看起来是合法 JSON（明文旧数据），
        // 不直接报错，而是返回明文并设置迁移标记，供调用方后续用加密格式覆盖上传。
        // 这样用户从明文切换到加密时不会因旧数据解密失败而阻塞同步。
        if let _ = try? decoder.decode(Manifest.self, from: data),
           data.count > 2 {
            // 看起来是有效 JSON（Manifest 或 EntryEnvelope 等），按明文处理
            WuyanLog.sync.info("检测到远端明文数据，将进行加密覆盖迁移")
            cryptoNeedsReEncrypt = true
            return data
        }
        // 尝试作为裸 UTF-8 JSON 解析（非 EncryptedPayload 也非 Manifest 的条目/日札数据）
        if let first = data.first, first == 0x7B || first == 0x5B {
            WuyanLog.sync.info("检测到远端明文 JSON 数据，将进行加密覆盖迁移")
            cryptoNeedsReEncrypt = true
            return data
        }
        throw SyncError.decryptFailed(reason: "远端数据不是合法的加密格式，口令可能不正确或文件被篡改")
    }

    private func report(_ progress: SyncProgress) async {
        await progressHandler?(progress)
    }

    private static func deviceId() -> String {
        let key = "sync.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

final class SyncCrypto: @unchecked Sendable {
    let box = AESGCMCryptoBox()
    let params: KDFParams          // 本机加密时用的盐/迭代次数
    let key: SymmetricKey          // 对应 params.salt 的密钥
    private let passphrase: String
    private var keyCache: [String: SymmetricKey]
    private let lock = NSLock()

    var manifestHeader: CryptoManifestHeader {
        CryptoManifestHeader(
            saltBase64: params.salt.base64EncodedString(),
            iterations: params.iterations
        )
    }

    init(passphrase: String, salt: Data) throws {
        self.passphrase = passphrase
        let params = KDFParams(salt: salt)
        self.params = params
        let key = try box.deriveKey(passphrase: passphrase, salt: salt, params: params)
        self.key = key
        self.keyCache = [salt.base64EncodedString(): key]
    }

    // 按密文携带的盐派生密钥（缓存，PBKDF2 每个盐只算一次）。修复多设备解密。
    func key(forSaltBase64 saltB64: String, iterations: Int) throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached = keyCache[saltB64] {
            return cached
        }
        guard let salt = Data(base64Encoded: saltB64) else {
            throw RemoteStorageError.missingConfiguration("加密盐无效")
        }
        let derived = try box.deriveKey(passphrase: passphrase, salt: salt, params: KDFParams(salt: salt, iterations: iterations))
        keyCache[saltB64] = derived
        return derived
    }
}
