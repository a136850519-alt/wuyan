import CryptoKit
import Foundation

enum SyncError: LocalizedError {
    case decryptFailed(reason: String)
    case rescueModeDisabled

    var errorDescription: String? {
        switch self {
        case let .decryptFailed(reason):
            return "同步解密失败：\(reason)"
        case .rescueModeDisabled:
            return "救援模式：远端同步操作已禁用。"
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
    /// V3-11：本轮加密迁移已将远端媒体改写为目标格式。后续迁移推送只需
    /// 补齐远端缺失对象，不再把每个本地媒体再上传一遍。
    private var remoteMediaMigrated = false
    /// 后端指纹：用于区分不同的远端配置（避免切换 NAS/账号后旧水位线跳过拉取）
    private let backendFingerprint: String
    /// R0-7: 明文→加密迁移标记。当 decodeRaw 检测到远端有明文/旧版数据时设置，
    /// syncNow 完成后会自动重新上传所有条目。
    private var cryptoNeedsReEncrypt = false
    /// Whether this sync may consume legacy/plaintext remote objects. This is
    /// decided while loading the manifest, never inferred from an object that
    /// merely happens to parse as JSON.
    private var plaintextTolerated = false
    /// B03：加密迁移状态持久化在数据库（sync_state）。密钥头已发布但对象尚未全部
    /// 转换时为 "in-progress"——任何一台设备的后续同步据此强制补完迁移，
    /// 不依赖内存标记或「加密索引存在＝对象已加密」的错误推断。
    private var migrationStateKey: String {
        "sync.cryptoMigration.\(backendFingerprint)"
    }
    private var cryptoEstablishedKey: String {
        "sync.cryptoEstablished.\(backendFingerprint)"
    }
    /// B01：孤儿版本 GC 宽限期（见 init 注释）。
    private let orphanGraceInterval: TimeInterval
    /// C01：缺失对象巡检间隔。巡检发现「索引引用的对象远端已不存在」时，
    /// 用本地一致副本自动补传，不依赖用户再次编辑。0 表示每轮同步都巡检（测试用）。
    private let missingObjectAuditInterval: TimeInterval
    /// V3-15：删除墓碑/对象保留期，可注入 0 以覆盖过期清除路径。
    private let deletedRetention: TimeInterval
    /// UI-01：关闭加密迁移模式——读取仍用密钥，写出一律明文（对象与索引）。
    /// 由「关闭加密」流程通过 init 参数启用，迁移完成后调用方再关闭配置。
    private let writesPlaintext: Bool
    /// 进度上报节流：拉取/推送按条目逐条 report，每次都会把整个 UI 拖着重算，
    /// 这里限制转发频率；阶段变化与完成时刻不受节流，保证状态不被吞。
    private var lastReportedAt: ContinuousClock.Instant = .now - .seconds(3600)
    private var lastReportedProgress: SyncProgress?
    /// IDs/dates actually changed by this sync round. Concurrent manifest
    /// merges must apply only these local mutations; untouched stale values
    /// must never win over a newer remote index.
    private var changedEntryIDs: Set<UUID> = []
    private var changedDayNoteDates: Set<String> = []
    private var changedBoardIDs: Set<UUID> = []
    private static let reportThrottleInterval: Duration = .milliseconds(250)

    init(
        provider: RemoteStorageProvider,
        database: AppDatabase,
        crypto: SyncCrypto? = nil,
        archivedYears: Set<Int> = [],
        backendFingerprint: String,
        plaintextMigration: Bool = false,
        orphanGraceInterval: TimeInterval = 48 * 3600,
        missingObjectAuditInterval: TimeInterval = 24 * 3600,
        deletedRetention: TimeInterval = 90 * 86_400,
        progressHandler: ProgressHandler? = nil
    ) {
        self.provider = provider
        self.database = database
        self.crypto = crypto
        self.archivedYears = archivedYears
        self.writesPlaintext = plaintextMigration
        // B01：被取代版本对象的 GC 宽限期。登记后超过该时长且确认未被最新索引
        // 引用才删除，给「其它设备恢复旧内容」留出并发窗口。测试可注入更短宽限。
        self.orphanGraceInterval = orphanGraceInterval
        self.missingObjectAuditInterval = missingObjectAuditInterval
        self.deletedRetention = deletedRetention
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
        changedEntryIDs.removeAll()
        changedDayNoteDates.removeAll()
        changedBoardIDs.removeAll()
        remoteMediaMigrated = false
        var progress = SyncProgress(phase: "准备同步", completedUnitCount: 0, totalUnitCount: 7)
        do {
            await self.report(progress)
            try await ensureRemoteTree()
            progress.completedUnitCount += 1
            progress.phase = "正在读取远端索引"
            await self.report(progress)

            let (loadedManifest, manifestETag, manifestExisted) = try await loadManifest()
            let baseManifestRevision = loadedManifest.revision
            // 空清单始终视为后端初始化/重置状态。持久化标记只能减少工作量，
            // 不能证明远端仍然存在数据；后端被清空后若继续信任旧标记，会漏推
            // 本地已经 clean 的条目。
            let localPurged = try database.syncStateDAO.purgedEntries()
            let shouldBootstrapBackend = loadedManifest.entries.isEmpty
                && (loadedManifest.purged ?? []).isEmpty
                && localPurged.isEmpty

            // B03：迁移状态持久化在数据库。上一轮同步在发布密钥头后中断时，
            // 状态仍是 in-progress——本轮强制补完迁移，不依赖内存标记，
            // 也不把「索引已是加密格式」误读为「对象已全部加密」。
            // C02：远端索引携带的迁移标记是跨设备权威状态——加密迁移在对象阶段
            // 中断后，接续设备（空库、无本地 in-progress）也能据此补完迁移；
            // 反之，另一设备正在进行「关闭加密」迁移时，本机不得反向重加密。
            var foreignDecryptMigration = false
            if crypto == nil {
                // 未启用加密：任何遗留的迁移状态已无意义，直接清除。
                try database.syncStateDAO.set(nil, forKey: migrationStateKey)
            } else {
                if !writesPlaintext {
                    switch loadedManifest.migration?.direction {
                    case RemoteMigrationState.encrypt:
                        cryptoNeedsReEncrypt = true
                    case RemoteMigrationState.decrypt:
                        foreignDecryptMigration = true
                        cryptoNeedsReEncrypt = false
                    default:
                        break
                    }
                }
                if !writesPlaintext,
                   foreignDecryptMigration == false,
                   try database.syncStateDAO.value(forKey: migrationStateKey) == "in-progress" {
                    cryptoNeedsReEncrypt = true
                }
            }

            // A04：明文→加密迁移的第一步是把数据密钥头随索引发怖到远端，再动任何对象。
            // 发布失败（网络/5xx）时远端仍是纯明文旧状态，零污染；
            // 发布成功后即使对象迁移中断，读取端也能凭索引头解锁数据密钥——
            // 明文对象按明文读出后重传，密文对象直接解密，两个方向都可恢复。
            // B03：发布即持久化 in-progress 状态（先于任何对象写入），
            // 保证中断后原设备独立重试会补完迁移。
            // C02：发布的同时把迁移标记写入远端索引本体——迁移状态不再只存在于
            // 原设备数据库，任何持正确口令的设备都能接续完成迁移。
            var manifest = loadedManifest
            // Closing encryption is a two-phase protocol: publish the decrypt
            // marker while the index is still encrypted before touching any
            // object, so another device will not re-encrypt mixed plaintext.
            if writesPlaintext, manifestExisted,
               manifest.migration?.direction != RemoteMigrationState.decrypt {
                manifest.migration = RemoteMigrationState(
                    direction: RemoteMigrationState.decrypt,
                    startedAt: Date(),
                    startedBy: deviceId()
                )
                manifest = try await publishEncryptedManifest(manifest, loadedETag: manifestETag)
            }
            if crypto != nil, !writesPlaintext, cryptoNeedsReEncrypt, manifestExisted {
                try database.syncStateDAO.set("in-progress", forKey: migrationStateKey)
                if manifest.migration?.direction != RemoteMigrationState.encrypt {
                    manifest.migration = RemoteMigrationState(
                        direction: RemoteMigrationState.encrypt,
                        startedAt: Date(),
                        startedBy: deviceId()
                    )
                }
                manifest = try await publishEncryptedManifest(manifest, loadedETag: manifestETag)
            }

            // 一次性把本地快照/基线/日札哈希/媒体缓存读入内存，避免在下面比对时
            // 对每条远端记录都各查一次库（这是原先「读全盘」的主要本地开销）。
            let snapshots = try database.entryDAO.allSyncSnapshots()
            let baselines = try database.entryDAO.allBaselineHashes()
            let dayNotes = try database.dayNoteDAO.all()
            let dayNoteHashes = Dictionary(
                dayNotes.map { ($0.date, Hashing.dayNoteHash($0)) },
                uniquingKeysWith: { first, _ in first }
            )
            // A02：日札的三方合并基线（「已与远端确认一致」的版本指纹）。
            let dayNoteBaselines = try database.dayNoteDAO.allBaselineHashes()
            mediaCache = try database.mediaAssetDAO.uploadedPaths(backend: backendFingerprint)

            // D05：双重判断「远端无变化」。其一，远端索引自带内容摘要 revision，
            // 与当前索引内容重算值一致——保证任何内容变化（含同秒修改、只改板块）
            // 都会被发现，不再依赖「计数+最大秒」的弱指纹；其二，与本地水位线一致——
            // 摘要相等只说明远端没变过，还要求本机已同步到该版本。
            // A01：水位线存数据库（sync_state）而非 UserDefaults——它与 baseline、
            // 条目数据同库同生命周期。换空库/恢复旧库时水位线随之缺失或还原，
            // 同步必然完整拉取，不会再沿用另一份数据的「已同步」结论漏拉日记。
            let computedRevision = Self.computeRevision(
                entries: manifest.entries,
                daynotes: manifest.daynotes,
                boards: manifest.boards,
                purged: manifest.purged ?? []
            )
            let storedRevision = try database.syncStateDAO.value(forKey: revisionKey)
            let remoteUnchanged = manifest.revision == computedRevision
                && manifest.revision == storedRevision

            let pullUnits = remoteUnchanged ? 0 : manifest.entries.count + manifest.daynotes.count
            progress = SyncProgress(
                phase: remoteUnchanged ? "远端无变化，跳过拉取" : "正在拉取远端日记",
                completedUnitCount: 2,
                totalUnitCount: max(1, 7 + pullUnits)
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
                report.pulled += try await pullRemoteDayNotes(
                    from: manifest, localHashes: dayNoteHashes, baselines: dayNoteBaselines, progress: &progress
                )
            }
            try await applyRemotePurges(manifest: &manifest, report: &report)

            // C02：另一设备的「关闭加密」迁移进行中——本轮不反向重加密。
            // pull 阶段读到明文对象会重新置位迁移标记，这里统一压掉，
            // 避免推送/媒体阶段把对方尚未迁移完的明文原件重新加密或删除。
            if foreignDecryptMigration, cryptoNeedsReEncrypt {
                cryptoNeedsReEncrypt = false
                WuyanLog.sync.info("检测到远端正在进行关闭加密迁移，本轮跳过反向重加密")
            }

            // D16：板块不只是首次同步时补缺；远端名称、排序和隐私开关变化也要
            // 落到本地。删除仍保留本地条目约束，避免无条件删除有本地引用的板块。
            let localBoardsBeforePull = try database.boardDAO.allIncludingDeleted()
            let remoteBoardsByID = Dictionary(uniqueKeysWithValues: manifest.boards.map { ($0.id, $0) })
            for localBoard in localBoardsBeforePull {
                if let remoteBoard = remoteBoardsByID[localBoard.id] {
                    if localBoard.updatedAt > remoteBoard.updatedAt { changedBoardIDs.insert(localBoard.id) }
                } else {
                    changedBoardIDs.insert(localBoard.id)
                }
            }
            for remoteBoard in manifest.boards {
                guard let local = try database.boardDAO.board(id: remoteBoard.id) else {
                    try database.boardDAO.saveRemote(remoteBoard)
                    continue
                }
                // updatedAt 是板块的乐观版本。远端较新才覆盖本地；本地较新则留给
                // 当前提交计划，避免同步拉取把尚未推送的隐私设置重置掉。
                guard remoteBoard.updatedAt > local.updatedAt else { continue }
                if remoteBoard.deletedAt != nil,
                   local.deletedAt == nil,
                   try database.boardDAO.hasActiveEntries(id: remoteBoard.id) {
                    // 有活动条目时保留本地板块行，删除墓碑仍会在合并阶段传播。
                    continue
                }
                try database.boardDAO.saveRemote(remoteBoard)
            }

            // D04：提交计划必须在拉取完成之后生成。冲突分支会用远端覆盖本地、
            // 并把本地版本留作冲突副本；若沿用拉取前的 dirty 快照，推送阶段会把
            // 已被替代的旧版本再推回远端，造成两端各持不同内容的发散状态。
            // A06：clean 只代表「已提交到之前的某个后端」，不能证明「已提交到当前
            // 后端」。远端索引缺失的本地未删除条目一律加入提交计划，切换后端或
            // 后端部分丢失时才能补传，而不是只推 dirty。
            let dirtyEntries = try buildPushPlan(
                manifest: manifest, shouldBootstrapBackend: shouldBootstrapBackend
            )
            let freshDayNotes = try database.dayNoteDAO.all()
            let remoteDayNoteHashes = Dictionary(
                manifest.daynotes.map { ($0.date, $0.hash) },
                uniquingKeysWith: { first, _ in first }
            )
            let dayNotesToPush = freshDayNotes.filter { note in
                Hashing.dayNoteHash(note) != remoteDayNoteHashes[note.date]
            }
            progress.totalUnitCount = max(1, 7 + pullUnits + dirtyEntries.count + dayNotesToPush.count)

            // D03：markClean 一律推迟到 manifest 提交成功之后（见下方 pendingCleans）。
            var pendingCleans: [(id: UUID, hash: String)] = []
            // A03：记录推送前的索引对象路径。B01：不再即时删除被取代的旧版本，
            // 而是登记孤儿表延迟 GC——内容寻址路径可能被其它设备「恢复旧内容」
            // 重新引用，提交后立即删除会删掉最新索引正引用的正文。
            let previousEntryPaths = Dictionary(
                uniqueKeysWithValues: manifest.entries.map { ($0.id, $0.path) }
            )
            let previousNotePaths = Dictionary(
                uniqueKeysWithValues: manifest.daynotes.map { ($0.date, $0.path) }
            )
            // A03：本机本轮写入的版本对象路径（提交后登记孤儿，由延迟 GC 处理）。
            var pushedEntryPaths: [UUID: String] = [:]
            var pushedNotePaths: [String: String] = [:]
            progress.phase = "正在推送本地日记"
            await self.report(progress)
            report.pushed += try await pushDirtyEntries(
                dirtyEntries, into: &manifest, report: &report, progress: &progress,
                pendingCleans: &pendingCleans, pushedPaths: &pushedEntryPaths
            )
            progress.phase = "正在推送日札"
            await self.report(progress)
            report.pushed += try await pushDayNotes(
                dayNotesToPush, into: &manifest, progress: &progress, pushedPaths: &pushedNotePaths
            )
            // D11：把本地保留的删除墓碑写入索引；彻底删除的条目已不在 dirtyEntries 里，
            // 没有这一步，远端旧对象会在下一轮把条目拉回本地。
            try pushTombstones(into: &manifest)
            progress.phase = "正在保存同步索引"
            await self.report(progress)
            // 先裁剪陈旧墓碑，再据裁剪后的内容计算指纹，保证「无变化」时指纹稳定不抖动。
            let pruneCutoff = Date().addingTimeInterval(-deletedRetention)
            let pruneNow = Date()
            // UI-04（已确认）：彻底删除后远端保留 90 天，到期由同步自动清理
            // 正文对象、冲突副本及不再被引用的媒体文件。
            try await cleanupExpiredRemoteEntities(&manifest, now: pruneNow, retention: deletedRetention)
            try database.entryDAO.pruneTombstones(olderThan: pruneCutoff)
            manifest = try pruneManifest(manifest, now: pruneNow, retention: deletedRetention)
            manifest.boards = Self.mergeBoardStates(
                remote: manifest.boards,
                local: try database.boardDAO.allIncludingDeleted()
            )

            // R0-7/UI-01: 迁移——检测到远端有明文/旧版数据，或处于关闭加密迁移模式时，
            // 重新上传全部条目和日札（迁移模式下写出的对象与索引均为明文）。
            var completedMigration: RemoteMigrationState?
            if (cryptoNeedsReEncrypt || writesPlaintext), !foreignDecryptMigration {
                if writesPlaintext {
                    WuyanLog.sync.info("关闭加密迁移：将全部远端对象重传为明文")
                } else if manifest.migration?.direction != RemoteMigrationState.encrypt {
                    // 罕见路径：迁移标记此前未随索引发怖（如极旧版本写入的明文索引）。
                    // 本轮开始补课：先把标记随最终索引一起发布，避免中断后接续设备失明。
                    manifest.migration = RemoteMigrationState(
                        direction: RemoteMigrationState.encrypt,
                        startedAt: Date(),
                        startedBy: deviceId()
                    )
                }
                progress.phase = writesPlaintext ? "正在迁移远端为明文" : "正在迁移远端明文→加密"
                await self.report(progress)
                let allEntries = try database.entryDAO.timeline(filter: .all)
                let allDayNotes = try database.dayNoteDAO.all()
                var migrationProgress = SyncProgress(
                    phase: "明文→加密迁移",
                    completedUnitCount: 0,
                    totalUnitCount: max(1, allEntries.count + allDayNotes.count)
                )
                var migrationReport = SyncReport()
                try await migrateRemoteObjects(in: manifest, toPlaintext: writesPlaintext)
                remoteMediaMigrated = true
                _ = try await pushDirtyEntries(
                    allEntries, into: &manifest, report: &migrationReport, progress: &migrationProgress,
                    pendingCleans: &pendingCleans, pushedPaths: &pushedEntryPaths
                )
                _ = try await pushDayNotes(allDayNotes, into: &manifest, progress: &migrationProgress, pushedPaths: &pushedNotePaths)
                manifest.boards = Self.mergeBoardStates(
                    remote: manifest.boards,
                    local: try database.boardDAO.allIncludingDeleted()
                )
                // C02：记录本机刚完成的迁移身份，随后清除本地副本；saveManifest
                // 会据此在合并后确认清除远端标记。
                completedMigration = manifest.migration
                manifest.migration = nil
                WuyanLog.sync.info("明文→加密迁移完成，已重新上传 \(allEntries.count) 条目和 \(allDayNotes.count) 日札")
            }

            // C01：缺失对象巡检。索引引用的正文/日札/媒体对象若在远端已不存在
            //（历史缺陷误删、后端部分丢失等），只要本机仍持有指纹一致的副本，
            // 就在本轮提交前自动补传——不依赖用户再次编辑该条目。
            try await auditMissingRemoteObjects(manifest: manifest, report: &report, progress: &progress)

            // D03：远端对象、索引全部提交成功后，才按推送时的版本指纹确认本地
            // dirty/baseline。manifest PUT 失败时本地仍视为 dirty，重试会幂等地
            // 重新推送并重建索引，不会出现「条目已 clean 但索引缺失」的漏传。
            let (savedManifest, mergedForeignRevision) = try await saveManifest(
                manifest, expectedRevision: baseManifestRevision, completedMigration: completedMigration
            )
            let savedEntryHashes = Dictionary(uniqueKeysWithValues: savedManifest.entries.map { ($0.id, $0.hash) })
            // B02：水位线的语义是「本地已完整应用该索引内容」。提交时远端版本胜出
            //（本机编辑落败）或提交内容包含本次拉取之后其它设备合并进来的新状态时，
            // 本地并未应用最终索引，绝不能推进水位线——置空强制下一轮完整拉取，
            // 由三方合并应用胜出版本并把落败编辑留作冲突副本。
            var confirmWatermark = !mergedForeignRevision
            for clean in pendingCleans where savedEntryHashes[clean.id] != clean.hash {
                confirmWatermark = false
            }
            if savedManifest.revision != baseManifestRevision {
                confirmWatermark = false
            }
            // A01：水位线与数据同库存放。
            try database.syncStateDAO.set(
                confirmWatermark ? savedManifest.revision : nil,
                forKey: revisionKey
            )
            // A02：提交成功后，把「本地内容与最终索引一致」的日札写入基线，
            // 作为下一轮三方合并判断「仅哪一边修改过」的同步基线。
            let confirmedNotes = try database.dayNoteDAO.all()
            let confirmedNoteHashes = Dictionary(
                confirmedNotes.map { ($0.date, Hashing.dayNoteHash($0)) },
                uniquingKeysWith: { first, _ in first }
            )
            let confirmedNoteBaselines = savedManifest.daynotes.compactMap { item -> (date: String, hash: String)? in
                guard confirmedNoteHashes[item.date] == item.hash else { return nil }
                return (date: item.date, hash: item.hash)
            }
            try database.dayNoteDAO.setBaselines(confirmedNoteBaselines)
            for clean in pendingCleans {
                // 条件写重读合并后，远端较新的版本可能胜出。只有最终写入的
                // manifest 确实采用了本地推送版本，才允许清除 dirty/baseline。
                guard savedEntryHashes[clean.id] == clean.hash else { continue }
                try database.entryDAO.markClean(id: clean.id, expectedHash: clean.hash)
            }
            // B01：本机被取代/落败的版本对象登记孤儿，超过宽限期且确认不再被
            // 最新索引引用后由延迟 GC 删除（绝不在提交后立即删除）。
            try await reconcileOrphanVersions(
                savedManifest: savedManifest,
                previousEntryPaths: previousEntryPaths,
                pushedEntryPaths: pushedEntryPaths,
                previousNotePaths: previousNotePaths,
                pushedNotePaths: pushedNotePaths
            )
            // B03：本轮同步完整结束（含迁移块全部成功提交）后迁移视为完成。
            try database.syncStateDAO.set(nil, forKey: migrationStateKey)
            if writesPlaintext {
                try database.syncStateDAO.set(nil, forKey: cryptoEstablishedKey)
            }
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
    /// UI-02（已确认）：推送后逐项读回校验——条目比对内容指纹，媒体解密后比对 sha256；
    /// 任何不一致抛错，调用方绝不能据此清理本地唯一副本。
    func archiveYear(_ year: Int) async throws -> ArchiveResult {
        status = .syncing
        changedEntryIDs.removeAll()
        changedDayNoteDates.removeAll()
        changedBoardIDs.removeAll()
        var progress = SyncProgress(phase: "\(year) 年归档准备中", completedUnitCount: 0, totalUnitCount: 1)
        do {
            await self.report(progress)
            try await ensureRemoteTree()
            let (loadedManifest, manifestETag, manifestExisted) = try await loadManifest()
            let baseManifestRevision = loadedManifest.revision
            var manifest = loadedManifest

            // Archiving deletes the local copy after the upload. Refuse to
            // start if the remote index has moved past this device's baseline;
            // otherwise an offline archive could roll another device back.
            try validateArchiveVersions(year: year, manifest: manifest)

            // B04：归档与普通同步共用一套加密提交协议。发现远端仍是明文/旧格式时，
            // 归档先发布数据密钥头（内容不变）再写任何密文对象——中断后远端要么
            // 保持旧明文状态，要么「加密索引 + 混合对象」，均可恢复。
            // C02：发布的同时把迁移标记写入远端索引，接续设备据此补完迁移。
            if crypto != nil, !writesPlaintext, cryptoNeedsReEncrypt, manifestExisted {
                try database.syncStateDAO.set("in-progress", forKey: migrationStateKey)
                if manifest.migration?.direction != RemoteMigrationState.encrypt {
                    manifest.migration = RemoteMigrationState(
                        direction: RemoteMigrationState.encrypt,
                        startedAt: Date(),
                        startedBy: deviceId()
                    )
                }
                manifest = try await publishEncryptedManifest(manifest, loadedETag: manifestETag)
            }

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
            // D03：与 syncNow 相同，markClean 推迟到索引提交成功之后。
            var pendingCleans: [(id: UUID, hash: String)] = []
            // B01：版本对象不即时删除，登记孤儿由延迟 GC 处理。
            let previousEntryPaths = Dictionary(
                uniqueKeysWithValues: manifest.entries.map { ($0.id, $0.path) }
            )
            let previousNotePaths = Dictionary(
                uniqueKeysWithValues: manifest.daynotes.map { ($0.date, $0.path) }
            )
            var pushedEntryPaths: [UUID: String] = [:]
            var pushedNotePaths: [String: String] = [:]
            report.pushed += try await pushDirtyEntries(
                yearEntries, into: &manifest, report: &report, progress: &progress,
                pendingCleans: &pendingCleans, pushedPaths: &pushedEntryPaths
            )
            progress.phase = "正在推送本年日札"
            await self.report(progress)
            report.pushed += try await pushDayNotes(yearNotes, into: &manifest, progress: &progress, pushedPaths: &pushedNotePaths)

            progress.phase = "正在读回校验归档数据"
            await self.report(progress)
            try await verifyArchivedPush(
                entries: yearEntries,
                dayNotes: yearNotes,
                pushedEntryPaths: pushedEntryPaths,
                pushedNotePaths: pushedNotePaths,
                progress: &progress
            )

            manifest.boards = Self.mergeBoardStates(
                remote: manifest.boards,
                local: try database.boardDAO.allIncludingDeleted()
            )
            let (savedManifest, _) = try await saveManifest(manifest, expectedRevision: baseManifestRevision)
            try await verifyArchivedManifest(entries: yearEntries, dayNotes: yearNotes, expected: savedManifest)
            let savedEntryHashes = Dictionary(uniqueKeysWithValues: savedManifest.entries.map { ($0.id, $0.hash) })
            // B06：局部归档没有完成全库拉取，绝不能推进普通同步使用的全库水位线；
            // 下一次 syncNow 会完整拉取，归档年份按 archivedYears 跳过。
            // A02：归档提交成功后确认日札基线（本地与索引一致的日札）。
            let yearNoteHashes = Dictionary(
                yearNotes.map { ($0.date, Hashing.dayNoteHash($0)) },
                uniquingKeysWith: { first, _ in first }
            )
            try database.dayNoteDAO.setBaselines(
                savedManifest.daynotes.compactMap { item -> (date: String, hash: String)? in
                    guard yearNoteHashes[item.date] == item.hash else { return nil }
                    return (date: item.date, hash: item.hash)
                }
            )
            for clean in pendingCleans {
                guard savedEntryHashes[clean.id] == clean.hash else { continue }
                try database.entryDAO.markClean(id: clean.id, expectedHash: clean.hash)
            }
            // B01：归档中被取代的版本对象登记孤儿，延迟 GC 处理。
            try await reconcileOrphanVersions(
                savedManifest: savedManifest,
                previousEntryPaths: previousEntryPaths,
                pushedEntryPaths: pushedEntryPaths,
                previousNotePaths: previousNotePaths,
                pushedNotePaths: pushedNotePaths
            )
            progress.completedUnitCount = progress.totalUnitCount
            progress.phase = "归档推送完成"
            await self.report(progress)
            status = .idle
            return ArchiveResult(report: report, pushedEntries: yearEntries, pushedNotes: yearNotes)
        } catch {
            status = .error(error.localizedDescription)
            throw error
        }
    }

    private func validateArchiveVersions(year: Int, manifest: Manifest) throws {
        let prefix = String(format: "%04d-", year)
        var conflicts: [String] = []
        let remoteEntries = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.id, $0) })
        for entry in try database.entryDAO.timeline(filter: .year(year)) {
            guard let remote = remoteEntries[entry.id] else { continue }
            if remote.deleted {
                conflicts.append(entry.dayDate)
                continue
            }
            if remote.hash == entry.contentHash { continue }
            let baseline = try database.entryDAO.baselineHash(id: entry.id)
            if baseline != remote.hash { conflicts.append(entry.dayDate) }
        }
        let remoteNotes = Dictionary(uniqueKeysWithValues: manifest.daynotes.map { ($0.date, $0) })
        for note in try database.dayNoteDAO.all() where note.date.hasPrefix(prefix) {
            guard let remote = remoteNotes[note.date] else { continue }
            let localHash = Hashing.dayNoteHash(note)
            if remote.hash == localHash { continue }
            let baseline = try database.dayNoteDAO.allBaselineHashes()[note.date]
            if baseline != remote.hash { conflicts.append(note.date) }
        }
        if !conflicts.isEmpty {
            throw RemoteStorageError.archiveRequiresSync(dates: Array(Set(conflicts)).sorted())
        }
    }

    /// UI-02：归档读回校验。条目：GET 推送路径并比对内容指纹；
    /// 媒体：GET 远端对象（解密）后比对 sha256。任何不一致都抛错阻断归档完成。
    /// C01：对象路径是每次提交不复用的身份，读回校验必须用推送时实际写入的
    /// 路径，而不是从本地模型重算。
    private func verifyArchivedPush(
        entries: [Entry],
        dayNotes: [DayNote],
        pushedEntryPaths: [UUID: String],
        pushedNotePaths: [String: String],
        progress: inout SyncProgress
    ) async throws {
        for (index, entry) in entries.enumerated() {
            progress.detail = entry.dayDate
            await self.report(progress)
            let path = pushedEntryPaths[entry.id] ?? SyncPaths.entryPath(entry)
            let data = try await provider.get(path)
            let envelope = try decode(EntryEnvelope.self, from: data)
            guard envelope.entry.contentHash == entry.contentHash else {
                throw RemoteStorageError.archiveVerificationFailed(path: path)
            }
            let assets = try database.mediaAssetDAO.allAssets(for: entry.mediaIds)
            // A08：mediaIds 必须全部解析到媒体元数据。缺行说明引用完整性已破坏，
            // 此时归档会产出一个无法完整恢复的远端副本，必须明确报错并阻止
            // 后续本地清理，而不是静默跳过缺失的附件。
            let resolvedAssetIDs = Set(assets.map(\.id))
            let referencedAssetIDs = Set(entry.mediaIds)
            guard resolvedAssetIDs == referencedAssetIDs else {
                let missing = referencedAssetIDs.subtracting(resolvedAssetIDs)
                    .map(\.uuidString).joined(separator: ",")
                throw RemoteStorageError.archiveVerificationFailed(
                    path: "\(SyncPaths.entryPath(entry)) 缺少媒体元数据：\(missing)"
                )
            }
            for asset in assets {
                let remotePath = crypto == nil || writesPlaintext
                    ? SyncPaths.mediaPath(sha256: asset.sha256, filename: asset.filename)
                    : SyncPaths.encryptedMediaPath(sha256: asset.sha256, filename: asset.filename)
                let hex: String
                if crypto == nil || writesPlaintext {
                    hex = try await remoteSHA256(remotePath, expectedSize: asset.size)
                } else {
                    let mediaData = try await provider.get(remotePath)
                    let plain = try decodeRaw(mediaData)
                    hex = SHA256.hash(data: plain).map { String(format: "%02x", $0) }.joined()
                }
                // A08：即使本机没有文件副本（localPath 为 nil），远端对象也必须
                // 真实可读且与元数据指纹一致，绝不能只凭「路径存在」放行。
                guard hex == asset.sha256 else {
                    throw RemoteStorageError.archiveVerificationFailed(path: remotePath)
                }
                if let thumbnailPath = asset.thumbnailPath,
                   let thumbnailURL = asset.absoluteThumbnailPath,
                   FileManager.default.fileExists(atPath: thumbnailURL) {
                    let remoteThumbnailPath = SyncPaths.thumbnailPath(sha256: asset.sha256)
                    let sameThumbnail: Bool
                    if crypto == nil || writesPlaintext {
                        let localHash = try Hashing.sha256Hex(ofFileAt: URL(fileURLWithPath: thumbnailURL))
                        sameThumbnail = try await remoteSHA256(remoteThumbnailPath, expectedSize: nil) == localHash
                    } else {
                        let thumbnailData = try await provider.get(remoteThumbnailPath)
                        let plainThumbnail = try decodeRaw(thumbnailData)
                        let localThumbnail = try Data(contentsOf: URL(fileURLWithPath: thumbnailURL))
                        sameThumbnail = plainThumbnail == localThumbnail
                    }
                    guard sameThumbnail else {
                        throw RemoteStorageError.archiveVerificationFailed(path: remoteThumbnailPath)
                    }
                    _ = thumbnailPath
                }
            }
            progress.completedUnitCount += 1
            _ = index
        }
        for note in dayNotes {
            progress.detail = note.date
            await self.report(progress)
            let path = pushedNotePaths[note.date] ?? SyncPaths.dayNotePath(note)
            let data = try await provider.get(path)
            let remoteNote = try decode(DayNote.self, from: data)
            guard Hashing.dayNoteHash(remoteNote) == Hashing.dayNoteHash(note) else {
                throw RemoteStorageError.archiveVerificationFailed(path: path)
            }
            progress.completedUnitCount += 1
        }
        progress.detail = nil
        await self.report(progress)
    }

    private func verifyArchivedManifest(entries: [Entry], dayNotes: [DayNote], expected: Manifest) async throws {
        let snapshot = try await provider.getVersioned(SyncPaths.manifest)
        let remote = try decodeManifestData(snapshot.data)
        let remoteEntries = Dictionary(uniqueKeysWithValues: remote.entries.map { ($0.id, $0) })
        for entry in entries {
            guard remoteEntries[entry.id]?.hash == entry.contentHash else {
                throw RemoteStorageError.archiveVerificationFailed(path: SyncPaths.entryPath(entry))
            }
        }
        let remoteNotes = Dictionary(uniqueKeysWithValues: remote.daynotes.map { ($0.date, $0) })
        for note in dayNotes {
            guard remoteNotes[note.date]?.hash == Hashing.dayNoteHash(note) else {
                throw RemoteStorageError.archiveVerificationFailed(path: SyncPaths.dayNotePath(note))
            }
        }
        guard remote.revision == expected.revision else {
            throw RemoteStorageError.archiveVerificationFailed(path: SyncPaths.manifest)
        }
    }

    /// 按年拉取：把某一年的日记/日札从远端索引拉回本地（忽略「已归档跳过」规则）。
    /// 供「从已归档下载回本地」使用；附件由调用方按需下载。
    func pullYear(_ year: Int) async throws -> Int {
        status = .syncing
        do {
            try await ensureRemoteTree()
            let (manifest, _, _) = try await loadManifest()
            let prefix = String(format: "%04d-", year)
            var pulled = 0
            for board in manifest.boards where (try database.boardDAO.board(id: board.id)) == nil {
                try database.boardDAO.save(board)
            }
            var report = SyncReport()
            let localEntries = try database.entryDAO.timeline(filter: .year(year))
            let localByID = Dictionary(uniqueKeysWithValues: localEntries.map { ($0.id, $0) })
            for remote in manifest.entries where remote.dayDate.hasPrefix(prefix) {
                let local = localByID[remote.id]
                if remote.deleted {
                    guard let local, !local.deleted else { continue }
                    do {
                        try database.entryDAO.softDelete(id: remote.id, expectedContentHash: local.contentHash)
                    } catch EntrySaveError.concurrentModification {
                        if let latest = try database.entryDAO.entry(id: remote.id), !latest.deleted {
                            try await writeConflictCopy(latest)
                            report.conflicts.append(remote.id)
                            try database.entryDAO.softDelete(id: remote.id, expectedContentHash: latest.contentHash)
                        }
                    }
                    pulled += 1
                    continue
                }
                guard let local else {
                    try await pullRemoteEntryWithRecovery(remote, expectedLocalHash: nil, report: &report)
                    pulled += 1
                    continue
                }
                if local.contentHash == remote.hash { continue }
                let baseline = try database.entryDAO.baselineHash(id: remote.id)
                if baseline == remote.hash {
                    // The remote side did not change since the last sync; keep
                    // the unsynced local edit and its dirty flag.
                    continue
                }
                if baseline != local.contentHash {
                    try await writeConflictCopy(local)
                    report.conflicts.append(remote.id)
                }
                try await pullRemoteEntryWithRecovery(remote, expectedLocalHash: local.contentHash, report: &report)
                pulled += 1
            }
            for remote in manifest.daynotes where remote.date.hasPrefix(prefix) {
                let data = try await provider.get(remote.path)
                let note = try decode(DayNote.self, from: data)
                let localHash = try database.dayNoteDAO.note(dayKey: remote.date).map(Hashing.dayNoteHash)
                let baseline = try database.dayNoteDAO.allBaselineHashes()[remote.date]
                if localHash == remote.hash { continue }
                if baseline == remote.hash { continue }
                guard baseline == localHash || localHash == nil else {
                    // Both sides changed. Keep the local note for the next push,
                    // but preserve the remote losing version locally.
                    try database.dayNoteDAO.saveConflictCopy(note)
                    continue
                }
                try database.dayNoteDAO.upsert(note, expectedHash: localHash)
                // A02：拉取落地即确认基线，作为后续三方合并的参照。
                try database.dayNoteDAO.setBaseline(date: note.date, hash: Hashing.dayNoteHash(note))
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
        if (try? database.syncStateDAO.value(forKey: key)) == "1" {
            if try await provider.exists("/Wuyan/.sync/") { return }
        }
        try await provider.mkcolRecursive("/Wuyan/entries/")
        try await provider.mkcolRecursive("/Wuyan/daynotes/")
        try await provider.mkcolRecursive("/Wuyan/media/")
        try await provider.mkcolRecursive("/Wuyan/media/thumbnails/")
        try await provider.mkcolRecursive("/Wuyan/.sync/")
        try await provider.mkcolRecursive("/Wuyan/.trash/")
        try database.syncStateDAO.set("1", forKey: key)
    }

    /// 读取远端索引。返回清单、读取时的版本标识（供条件写）以及远端是否已存在索引。
    private func loadManifest() async throws -> (manifest: Manifest, etag: String?, existed: Bool) {
        plaintextTolerated = false
        guard try await provider.exists(SyncPaths.manifest) else {
            var manifest = Manifest()
            manifest.boards = Self.mergeBoardStates(
                remote: manifest.boards,
                local: try database.boardDAO.allIncludingDeleted()
            )
            // UI-01：首次启用加密且远端还没有索引——预生成数据密钥头，
            // 让本次推送的对象与随后保存的索引使用同一把数据密钥。
            if let crypto, !writesPlaintext {
                _ = try crypto.makeFreshHeaderIfAbsent()
            }
            return (manifest, nil, false)
        }
        let snapshot = try await provider.getVersioned(SyncPaths.manifest)
        let localMigrationInProgress = (try database.syncStateDAO.value(forKey: migrationStateKey)) == "in-progress"
        let established = (try database.syncStateDAO.value(forKey: cryptoEstablishedKey)) == "1"
        if crypto != nil {
            let isV3Container = (try? decoder.decode(ManifestContainer.self, from: snapshot.data))
                .flatMap { $0.crypto?.wrappedDekBase64 != nil && $0.payloadCiphertextBase64 != nil } ?? false
            let isLegacyEncrypted = (try? decoder.decode(EncryptedPayload.self, from: snapshot.data)) != nil
            plaintextTolerated = writesPlaintext || localMigrationInProgress || !established
                || isLegacyEncrypted
            if isV3Container {
                // The encrypted payload is authoritative; decodeManifestContainer
                // will narrow this to the migration flag carried in its plaintext.
                plaintextTolerated = writesPlaintext || localMigrationInProgress
            }
        }
        var manifest = try decodeManifestData(snapshot.data)
        Self.normalizePurges(&manifest)
        return (manifest, snapshot.etag, true)
    }

    /// A04：明文→加密迁移开始时发布「带数据密钥头的加密索引」（内容不变，仅换格式）。
    /// 发布顺序协议：
    /// 1. 发布失败 → 远端保持纯明文旧状态，未动任何对象，重试零负担；
    /// 2. 发布成功、对象迁移中断 → 远端为「加密索引 + 明文/密文混合对象」：
    ///    任何持正确口令的设备（含原设备）都能凭索引头解锁数据密钥，
    ///    明文对象经 decodeRaw 按明文读出并重传，密文对象直接解密，均可恢复；
    /// 3. 旧协议（先覆盖对象、最后提交索引）中断后会留下没有密钥头可解的密文
    ///    对象，明文索引无法提供 DEK，任何设备都无法读取——已废弃。
    private func publishEncryptedManifest(_ manifest: Manifest, loadedETag: String?) async throws -> Manifest {
        guard let crypto else { return manifest }
        var currentETag = loadedETag
        var current = manifest
        for _ in 0..<3 {
            // 同机重试：优先恢复本机持久化的待提交密钥头，保证使用同一把 DEK。
            _ = try crypto.makeFreshHeaderIfAbsent()
            guard let header = crypto.currentHeader else {
                throw SyncError.decryptFailed(reason: "加密密钥头缺失，无法保存索引")
            }
            var payload = current
            payload.crypto = header
            let plain = try encoder.encode(payload)
            let ciphertext = try crypto.sealWithDEK(plain)
            let container = ManifestContainer(crypto: header, payloadCiphertextBase64: ciphertext.base64EncodedString())
            do {
                try await provider.putConditionally(
                    SyncPaths.manifest,
                    data: try encoder.encode(container),
                    contentType: "application/json",
                    ifMatch: currentETag,
                    ifNoneMatch: false
                )
                try database.syncStateDAO.set("1", forKey: cryptoEstablishedKey)
                WuyanLog.sync.info("已发布加密索引密钥头，开始迁移远端对象")
                return current
            } catch let error as RemoteStorageError {
                guard case .concurrentModification = error else { throw error }
                // 另一设备改过索引：重读；若对方已发布加密索引则无需重复发布。
                let snapshot = try await provider.getVersioned(SyncPaths.manifest)
                currentETag = snapshot.etag
                cryptoNeedsReEncrypt = false
                current = try decodeManifestData(snapshot.data)
                if !cryptoNeedsReEncrypt { return current }
            }
        }
        throw RemoteStorageError.concurrentModification(path: SyncPaths.manifest)
    }

    private func decodeManifestData(_ data: Data) throws -> Manifest {
        guard let crypto else {
            // UI-01：未启用加密时远端必须是明文索引。发现加密数据要明确报错，
            // 不能把密文伪装成空索引继续写（那会覆盖掉远端的真实数据）。
            if let container = try? decoder.decode(ManifestContainer.self, from: data),
               container.crypto?.wrappedDekBase64 != nil || container.payloadCiphertextBase64 != nil {
                throw SyncError.decryptFailed(reason: "远端索引已加密：请先在设置中开启「远端同步加密」并输入口令，完成迁移后再关闭")
            }
            if (try? decoder.decode(EncryptedPayload.self, from: data)) != nil {
                throw SyncError.decryptFailed(reason: "远端索引已加密（旧版格式）：请先开启加密并输入原口令，完成迁移后再关闭")
            }
            return try decoder.decode(Manifest.self, from: data)
        }
        return try decodeManifestContainer(data: data, crypto: crypto)
    }

    /// UI-01：按格式解出 manifest——v3 容器（密钥头 + DEK 密文）、旧版整体加密、明文。
    private func decodeManifestContainer(data: Data, crypto: SyncCrypto) throws -> Manifest {
        // 1) v3 容器
        if let container = try? decoder.decode(ManifestContainer.self, from: data),
           let header = container.crypto,
           header.wrappedDekBase64 != nil,
           let payloadB64 = container.payloadCiphertextBase64,
           let ciphertext = Data(base64Encoded: payloadB64) {
            try crypto.unlock(with: header)
            let dek = try crypto.dekForKeyId(header.keyId)
            let plain = try crypto.box.open(ciphertext, key: dek)
            let manifest = try decoder.decode(Manifest.self, from: plain)
            try database.syncStateDAO.set("1", forKey: cryptoEstablishedKey)
            let localMigrationInProgress = (try database.syncStateDAO.value(forKey: migrationStateKey)) == "in-progress"
            plaintextTolerated = writesPlaintext || manifest.migration != nil || localMigrationInProgress
            return manifest
        }
        // 2) 旧版整体加密（EncryptedPayload v1/v2 包着 Manifest）——读取后升级重传
        if let payload = try? decoder.decode(EncryptedPayload.self, from: data),
           let ciphertext = Data(base64Encoded: payload.ciphertextBase64) {
            let key = try crypto.key(forSaltBase64: payload.saltBase64 ?? "", iterations: payload.iterations ?? 0)
            let plain: Data
            do {
                plain = try crypto.box.open(ciphertext, key: key)
            } catch {
                throw SyncError.decryptFailed(reason: "解密失败：口令可能不正确（\(error.localizedDescription)）")
            }
            cryptoNeedsReEncrypt = true
            WuyanLog.sync.info("检测到旧版加密索引，将升级为数据密钥格式")
            return try decoder.decode(Manifest.self, from: plain)
        }
        // 3) 明文 manifest is only valid for a first-time/legacy migration.
        guard plaintextTolerated else {
            throw SyncError.decryptFailed(reason: "远端索引变成了明文：可能是另一台设备关闭了加密，或远端被篡改。若是前者，请在本机也关闭加密；否则请检查远端存储。")
        }
        // A04：先恢复/生成数据密钥头（同机重试时还原本机持久化的待提交密钥头）。
        // 即使此前的迁移在发布索引后中断、远端残留了个别密文对象，
        // 本轮读取也能用同一把 DEK 解开，不会卡死在「密钥尚未解锁」。
        _ = try crypto.makeFreshHeaderIfAbsent()
        cryptoNeedsReEncrypt = true
        return try decoder.decode(Manifest.self, from: data)
    }

    // 写入 manifest 并返回其内容指纹 revision。指纹由写入时的完整索引内容派生，
    // 接收方据此判断「远端是否变化」。
    // UI-01：加密模式写入 v3 容器（密钥头外置 + 索引由数据密钥加密）；
    // 明文模式或关闭加密迁移写原始 JSON。
    // B02：同时返回 mergedForeignRevision——提交时合并了「本机尚未拉取应用」的
    // 其它设备版本（latest.revision != expectedRevision）时为 true，调用方据此
    // 不推进拉取水位线，强制下一轮完整拉取应用该状态。
    // C02：completedMigration 是本机本轮刚完成的迁移标记。合并远端最新索引后，
    // 若索引里的标记正是这一次迁移（同方向、同 startedAt、同发起设备），完成
    // 决定优先——清除之，避免「完成写入被合并回滚」导致迁移无限循环；
    // 其它设备新发起的迁移标记则原样保留，由其接续流程负责。
    private func saveManifest(
        _ input: Manifest,
        expectedRevision: String? = nil,
        completedMigration: RemoteMigrationState? = nil
    ) async throws -> (manifest: Manifest, mergedForeignRevision: Bool) {
        var mergedForeignRevision = false
        for attempt in 0..<3 {
            var manifest = input
            let exists = try await provider.exists(SyncPaths.manifest)
            var etag: String?
            if exists {
                let latestSnapshot = try await provider.getVersioned(SyncPaths.manifest)
                etag = latestSnapshot.etag
                let latest = try decodeManifestData(latestSnapshot.data)
                // Always merge a newer remote snapshot. The conditional write below
                // closes the remaining read/modify/write race for ETag-capable backends.
                if latest.revision != manifest.revision || latest.revision != expectedRevision {
                    mergedForeignRevision = latest.revision != expectedRevision
                    manifest = Self.mergeManifests(
                        latest,
                        with: manifest,
                        changedEntryIDs: changedEntryIDs,
                        changedDayNoteDates: changedDayNoteDates,
                        changedBoardIDs: changedBoardIDs
                    )
                    if let completedMigration, manifest.migration == completedMigration {
                        manifest.migration = nil
                    }
                }
            }
            // V3-15：旧版客户端可能保存索引时丢掉 purged；本地留存表与当前
            // 输入、远端快照取并集，保证清除记录不会因一次旧客户端写入而消失。
            var purgedByID = Dictionary(uniqueKeysWithValues: (manifest.purged ?? []).map { ($0.id, $0.deletedAt) })
            for (id, deletedAt) in try database.syncStateDAO.purgedEntries() {
                if deletedAt > (purgedByID[id] ?? .distantPast) {
                    purgedByID[id] = deletedAt
                }
            }
            let purgedBeforeNormalize = Set(purgedByID.keys)
            manifest.purged = purgedByID.map { PurgedEntry(id: $0.key, deletedAt: $0.value) }
            Self.normalizePurges(&manifest)
            let restoredIDs = purgedBeforeNormalize.subtracting(Set((manifest.purged ?? []).map(\.id)))
            if !restoredIDs.isEmpty {
                try database.syncStateDAO.dropPurged(ids: Array(restoredIDs))
            }
            if let purged = manifest.purged, !purged.isEmpty {
                try database.syncStateDAO.recordPurged(purged)
            }
            manifest.revision = Self.computeRevision(
                entries: manifest.entries,
                daynotes: manifest.daynotes,
                boards: manifest.boards,
                purged: manifest.purged ?? []
            )

            let data: Data
            if let crypto, !writesPlaintext {
                if crypto.currentHeader == nil {
                    _ = try crypto.makeFreshHeaderIfAbsent()
                }
                guard let header = crypto.currentHeader else {
                    throw SyncError.decryptFailed(reason: "加密密钥头缺失，无法保存索引")
                }
                manifest.crypto = header
                let plain = try encoder.encode(manifest)
                let ciphertext = try crypto.sealWithDEK(plain)
                let container = ManifestContainer(crypto: header, payloadCiphertextBase64: ciphertext.base64EncodedString())
                data = try encoder.encode(container)
            } else {
                manifest.crypto = nil
                data = try encoder.encode(manifest)
            }

            do {
                try await provider.putConditionally(
                    SyncPaths.manifest,
                    data: data,
                    contentType: "application/json",
                    ifMatch: etag,
                    ifNoneMatch: !exists
                )
                if crypto != nil, !writesPlaintext {
                    try database.syncStateDAO.set("1", forKey: cryptoEstablishedKey)
                }
                return (manifest, mergedForeignRevision)
            } catch let error as RemoteStorageError {
                guard case .concurrentModification = error, attempt < 2 else { throw error }
                continue
            }
        }
        throw RemoteStorageError.concurrentModification(path: SyncPaths.manifest)
    }

    private static func mergeManifests(
        _ latest: Manifest,
        with local: Manifest,
        changedEntryIDs: Set<UUID> = [],
        changedDayNoteDates: Set<String> = [],
        changedBoardIDs: Set<UUID> = []
    ) -> Manifest {
        var merged = latest
        var entryByID = Dictionary(uniqueKeysWithValues: latest.entries.map { ($0.id, $0) })
        for candidate in local.entries {
            guard changedEntryIDs.contains(candidate.id) else { continue }
            guard let existing = entryByID[candidate.id] else {
                entryByID[candidate.id] = candidate
                continue
            }
            if candidate.updatedAt >= existing.updatedAt {
                entryByID[candidate.id] = candidate
            }
        }
        merged.entries = Array(entryByID.values)
        var notes = Dictionary(uniqueKeysWithValues: latest.daynotes.map { ($0.date, $0) })
        for note in local.daynotes where changedDayNoteDates.contains(note.date) &&
            (notes[note.date] == nil || note.updatedAt >= notes[note.date]!.updatedAt) {
            notes[note.date] = note
        }
        merged.daynotes = Array(notes.values)
        let changedBoards = local.boards.filter { changedBoardIDs.contains($0.id) }
        merged.boards = mergeBoardStates(remote: latest.boards, local: changedBoards)
        var purgedByID = Dictionary(uniqueKeysWithValues: (latest.purged ?? []).map { ($0.id, $0.deletedAt) })
        for item in local.purged ?? [] where item.deletedAt > (purgedByID[item.id] ?? .distantPast) {
            purgedByID[item.id] = item.deletedAt
        }
        merged.purged = purgedByID.map { PurgedEntry(id: $0.key, deletedAt: $0.value) }
        normalizePurges(&merged)
        return merged
    }

    /// V3-15：清除记录与 entries 的一致化，保证 revision 稳定且旧客户端陈旧推送
    /// 不会重新成为活动条目。
    static func normalizePurges(_ manifest: inout Manifest) {
        guard let rawPurged = manifest.purged, !rawPurged.isEmpty else {
            manifest.purged = nil
            return
        }
        var latestByID: [UUID: Date] = [:]
        for item in rawPurged where item.deletedAt > (latestByID[item.id] ?? .distantPast) {
            latestByID[item.id] = item.deletedAt
        }
        var kept: [PurgedEntry] = []
        var removedEntryIDs = Set<UUID>()
        for (id, deletedAt) in latestByID {
            if let entry = manifest.entries.first(where: { $0.id == id }),
               !entry.deleted,
               entry.updatedAt >= deletedAt {
                // 用户在清除之后主动恢复，视为合法复活。
                continue
            }
            removedEntryIDs.insert(id)
            kept.append(PurgedEntry(id: id, deletedAt: deletedAt))
        }
        if !removedEntryIDs.isEmpty {
            manifest.entries.removeAll { removedEntryIDs.contains($0.id) }
        }
        kept.sort { $0.id.uuidString < $1.id.uuidString }
        manifest.purged = kept.isEmpty ? nil : kept
    }

    /// 删除墓碑优先于同 ID 的活动板块，避免并发提交或未同步设备将已删除板块复活。
    private static func mergeBoardStates(remote: [Board], local: [Board]) -> [Board] {
        var boards = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        for board in local {
            guard let existing = boards[board.id] else {
                boards[board.id] = board
                continue
            }
            if board.updatedAt > existing.updatedAt {
                boards[board.id] = board
            } else if board.updatedAt == existing.updatedAt,
                      existing.deletedAt == nil,
                      board.deletedAt != nil {
                // 相同版本时间下删除优先，避免并发提交把墓碑复活。
                boards[board.id] = board
            }
        }
        return Array(boards.values)
    }

    /// S03/UI-01：换口令——旧口令解包数据密钥验证身份后，仅重新包装并重写索引头，
    /// 数据对象完全不动（秒级完成）。远端还没有索引时返回 false（无需重写，
    /// 新口令会在下一次加密同步时自动生效）。旧版（v1/v2）加密索引需先同步一次完成升级。
    static func changePassphrase(provider: RemoteStorageProvider, oldPassphrase: String, newPassphrase: String) async throws -> Bool {
        guard try await provider.exists(SyncPaths.manifest) else { return false }
        let snapshot = try await provider.getVersioned(SyncPaths.manifest)
        let data = snapshot.data
        guard let container = try? JSONDecoder.wuyan.decode(ManifestContainer.self, from: data),
              let header = container.crypto,
              header.wrappedDekBase64 != nil,
              let payloadB64 = container.payloadCiphertextBase64,
              Data(base64Encoded: payloadB64) != nil
        else {
            throw SyncError.decryptFailed(reason: "远端索引不是数据密钥格式：请先同步一次完成格式升级，再更换口令")
        }
        let oldCrypto = SyncCrypto(passphrase: oldPassphrase)
        try oldCrypto.unlock(with: header)
        let newHeader = try oldCrypto.rewrappedHeader(with: newPassphrase, from: header)
        let newContainer = ManifestContainer(crypto: newHeader, payloadCiphertextBase64: payloadB64)
        try await provider.putConditionally(
            SyncPaths.manifest,
            data: try JSONEncoder.wuyan.encode(newContainer),
            contentType: "application/json",
            ifMatch: snapshot.etag,
            ifNoneMatch: false
        )
        return true
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
            // 已归档年份只跳过本地已经腾空的条目。归档后在本机新写的条目
            // 仍需接收其它设备更新，否则下一次推送会覆盖远端版本。
            if let y = year(ofDayKey: remote.dayDate), archivedYears.contains(y),
               snapshots[remote.id.uuidString] == nil {
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
                        do {
                            try database.entryDAO.softDelete(id: remote.id, expectedContentHash: snap.contentHash)
                        } catch EntrySaveError.concurrentModification {
                            if let latest = try database.entryDAO.entry(id: remote.id), !latest.deleted {
                                try await writeConflictCopy(latest)
                                report.conflicts.append(remote.id)
                                try database.entryDAO.softDelete(id: remote.id, expectedContentHash: latest.contentHash)
                            }
                        }
                        count += 1
                    }
                }
                // D11：远端索引已记录删除 → 本地墓碑的传播使命完成。
                try database.entryDAO.dropTombstone(id: remote.id)
                progress.completedUnitCount += 1
                continue
            }

            guard let snap else {
                // D11：本地已彻底删除且墓碑仍在保留期内——这是本地主动删除的结果，
                // 不能当作「新设备缺数据」拉回；等待推送阶段用墓碑覆盖索引。
                if try database.entryDAO.hasTombstone(id: remote.id) {
                    progress.completedUnitCount += 1
                    continue
                }
                // 本地没有这条 → 拉取。
                try await pullRemoteEntryWithRecovery(remote, expectedLocalHash: nil, report: &report)
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
                try await pullRemoteEntryWithRecovery(remote, expectedLocalHash: snap.contentHash, report: &report)
                count += 1
            } else {
                // 双方都变（或无 baseline 的独立创建）→ 冲突：留存本地副本后取远端。
                if let full = try database.entryDAO.entry(id: remote.id) {
                    try await writeConflictCopy(full)
                }
                report.conflicts.append(remote.id)
                try await pullRemoteEntryWithRecovery(remote, expectedLocalHash: snap.contentHash, report: &report)
                count += 1
            }
            progress.completedUnitCount += 1
        }
        progress.detail = nil
        await self.report(progress)
        return count
    }

    /// V3-15：把永久清除记录应用到本地回收站，避免离线设备把过期删除的日记推回。
    /// 先批量读取本地活动/回收站条目，再逐项写入，避免对每条清除记录重复扫库。
    private func applyRemotePurges(manifest: inout Manifest, report: inout SyncReport) async throws {
        var effective = try database.syncStateDAO.purgedEntries()
        for item in manifest.purged ?? [] {
            if item.deletedAt > (effective[item.id] ?? .distantPast) {
                effective[item.id] = item.deletedAt
            }
        }
        guard !effective.isEmpty else { return }

        let remoteLive = Dictionary(
            uniqueKeysWithValues: manifest.entries.filter { !$0.deleted }.map { ($0.id, $0) }
        )
        var restoredIDs: [UUID] = []
        for (id, deletedAt) in effective {
            if let remote = remoteLive[id], remote.updatedAt >= deletedAt {
                // 远端活动版本晚于清除记录，是合法复活；本地表不应继续拦截推送。
                restoredIDs.append(id)
            }
        }
        if !restoredIDs.isEmpty {
            try database.syncStateDAO.dropPurged(ids: restoredIDs)
            for id in restoredIDs { effective.removeValue(forKey: id) }
            let restored = Set(restoredIDs)
            manifest.purged = manifest.purged?.filter { !restored.contains($0.id) }
            Self.normalizePurges(&manifest)
        }

        let allEntries = try database.entryDAO.timeline(filter: .all) + database.entryDAO.trashedEntries()
        let localByID = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.id, $0) })
        var locallyRestoredIDs: [UUID] = []
        for (id, deletedAt) in effective {
            if let local = localByID[id], !local.deleted, local.dirty, local.updatedAt >= deletedAt,
               let baseline = try database.entryDAO.baselineHash(id: id) {
                var deletedVersion = local
                deletedVersion.deleted = true
                let deletedHash = Entry.hash(
                    title: deletedVersion.title,
                    body: deletedVersion.body,
                    bodyRTF: deletedVersion.bodyRTF,
                    tags: deletedVersion.tags,
                    mood: deletedVersion.mood,
                    weather: deletedVersion.weather,
                    location: deletedVersion.location,
                    mediaIds: deletedVersion.mediaIds,
                    boardId: deletedVersion.boardId,
                    dayDate: deletedVersion.dayDate,
                    journalDate: deletedVersion.journalDate,
                    isFavorite: deletedVersion.isFavorite,
                    isDraft: deletedVersion.isDraft,
                    deleted: true
                )
                if baseline == deletedHash {
                    // 用户从已应用的回收站中主动恢复：保留活动条目，稍后由推送阶段重新发布。
                    locallyRestoredIDs.append(id)
                    continue
                }
            }
            guard let local = localByID[id] else {
                // 本地已彻底删除：清除待推送墓碑，避免重新制造 entries。
                try database.entryDAO.dropTombstone(id: id)
                continue
            }
            if !local.deleted {
                let baseline = try database.entryDAO.baselineHash(id: id)
                let changed = local.dirty || (baseline != nil && baseline != local.contentHash)
                if changed {
                    try await writeConflictCopy(local)
                    report.conflicts.append(id)
                }
                try database.entryDAO.applyRemotePurge(id: id)
                report.purgedToTrash += 1
            } else {
                // 已在回收站也要对齐 dirty/baseline，防止下一轮再次推送。
                try database.entryDAO.applyRemotePurge(id: id)
            }
        }
        if !locallyRestoredIDs.isEmpty {
            try database.syncStateDAO.dropPurged(ids: locallyRestoredIDs)
            let restored = Set(locallyRestoredIDs)
            manifest.purged = manifest.purged?.filter { !restored.contains($0.id) }
            Self.normalizePurges(&manifest)
        }
        let restored = Set(locallyRestoredIDs)
        try database.syncStateDAO.recordPurged(
            effective.filter { !restored.contains($0.key) }
                .map { PurgedEntry(id: $0.key, deletedAt: $0.value) }
        )
    }

    private func pullRemoteEntry(_ remote: ManifestEntry, expectedLocalHash: String?) async throws {
        let data = try await provider.get(remote.path)
        let envelope = try decode(EntryEnvelope.self, from: data)
        // A02：信封内嵌的日札只是推送时刻的便捷快照。日札的合并权威在
        // pullRemoteDayNotes 的三方合并——本地已有该日期日札时，绝不能让
        // 条目拉取顺带回滚本地较新的日札（否则无关条目的远端变化会把
        // 未同步的本地日札编辑覆盖回旧值）。
        let localNote = try database.dayNoteDAO.note(dayKey: envelope.entry.dayDate)
        // D02：正文与附件元数据在单一事务内落地，避免 FK 半成品状态。
        try database.entryDAO.saveRemoteFull(
            entry: envelope.entry,
            board: envelope.board,
            dayNote: localNote == nil ? envelope.dayNote : nil,
            mediaAssets: envelope.mediaAssets ?? [],
            expectedLocalHash: expectedLocalHash
        )
    }

    /// Applies a remote version only if the local row still has the hash that
    /// was observed before the network request. If an editor saved meanwhile,
    /// preserve that version as a conflict copy and retry against its new hash.
    private func pullRemoteEntryWithRecovery(
        _ remote: ManifestEntry,
        expectedLocalHash: String?,
        report: inout SyncReport
    ) async throws {
        do {
            try await pullRemoteEntry(remote, expectedLocalHash: expectedLocalHash)
        } catch EntrySaveError.concurrentModification {
            guard let latest = try database.entryDAO.entry(id: remote.id) else {
                try await pullRemoteEntry(remote, expectedLocalHash: nil)
                return
            }
            try await writeConflictCopy(latest)
            if !report.conflicts.contains(remote.id) {
                report.conflicts.append(remote.id)
            }
            try await pullRemoteEntry(remote, expectedLocalHash: latest.contentHash)
        }
    }

    // D05：manifest 内容指纹 = 全部条目/日札/板块规范化内容的 SHA256 摘要。
    // 旧实现只取「计数 + 最大 updatedAt 秒」，同秒修改、时钟偏差下改非最大时间条目、
    // 只改板块都不会改变指纹，接收方据此跳过整个拉取阶段，远端变更被静默遗漏。
    // 摘要覆盖 id/归属/哈希/删除状态等全部业务版本信息，任何内容变化都会产生新指纹；
    // 指纹随 manifest 自身传输，比较时与内容重算值对照，不依赖任何本地水位线，
    // 恢复旧库或换新空库也不会盲目跳过拉取。
    static func computeRevision(
        entries: [ManifestEntry],
        daynotes: [ManifestDayNote],
        boards: [Board],
        purged: [PurgedEntry] = []
    ) -> String {
        var lines: [String] = []
        for entry in entries.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            lines.append("e|\(entry.id.uuidString)|\(entry.boardId.uuidString)|\(entry.dayDate)|\(entry.path)|\(entry.hash)|\(entry.deleted ? 1 : 0)|\(Int(entry.updatedAt.timeIntervalSince1970))|\(entry.deletedAt.map { Int($0.timeIntervalSince1970) } ?? 0)")
        }
        for note in daynotes.sorted(by: { $0.date < $1.date }) {
            lines.append("n|\(note.date)|\(note.path)|\(note.hash)|\(Int(note.updatedAt.timeIntervalSince1970))")
        }
        for board in boards.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            lines.append("b|\(board.id.uuidString)|\(board.name)|\(board.kind.rawValue)|\(board.sortOrder)|\(board.disallowCloudAI ? 1 : 0)|\(Int(board.updatedAt.timeIntervalSince1970))|\(board.deletedAt.map { Int($0.timeIntervalSince1970) } ?? 0)")
        }
        if !purged.isEmpty {
            for item in purged.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                lines.append("p|\(item.id.uuidString)|\(Int(item.deletedAt.timeIntervalSince1970))")
            }
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return "sha256-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    // D05：本地水位线——记录本机最后一次提交的 manifest 内容摘要。
    // 仅与内容重算摘要联合使用：摘要相等 + 水位线相等才允许跳过拉取；
    // 水位线缺失（新设备/恢复的库/换库）时永远完整拉取。
    // A01：水位线持久化在数据库 sync_state 表（key 按后端指纹区分），
    // 与它所描述的同步状态（baseline、条目）同库同生命周期；
    // UserDefaults 只绑定后端、不绑定数据集，换库/恢复后会错误地跳过拉取。
    private static let revisionKeyBase = "sync.lastManifestRevision"

    private var revisionKey: String {
        backendFingerprint.isEmpty ? Self.revisionKeyBase : "\(Self.revisionKeyBase).\(backendFingerprint)"
    }

    // 裁剪陈旧的删除墓碑：超过保留期的 deleted 条目从索引里移除（只动索引，不碰数据文件），
    // 防止 manifest 随删除积累而无界膨胀。保留期内仍保留墓碑，保证其它设备能同步到删除动作。
    private func pruneManifest(_ manifest: Manifest, now: Date = Date(), retention: TimeInterval = 90 * 86_400) throws -> Manifest {
        var manifest = manifest
        let cutoff = now.addingTimeInterval(-retention)
        let expired = manifest.entries.filter { $0.deleted && ($0.deletedAt ?? $0.updatedAt) < cutoff }
        if !expired.isEmpty {
            let existing = Set((manifest.purged ?? []).map(\.id))
            let newlyPurged = expired
                .filter { !existing.contains($0.id) }
                .map { PurgedEntry(id: $0.id, deletedAt: $0.deletedAt ?? $0.updatedAt) }
            if !newlyPurged.isEmpty {
                try database.syncStateDAO.recordPurged(newlyPurged)
            }
            manifest.purged = (manifest.purged ?? []) + newlyPurged
            manifest.entries.removeAll { $0.deleted && ($0.deletedAt ?? $0.updatedAt) < cutoff }
        }
        Self.normalizePurges(&manifest)
        return manifest
    }

    /// UI-04（已确认：彻底删除＝本地立即删，远端保留 90 天后由同步清理）。
    /// 保留期到期的墓碑条目：删除远端正文对象与本条目的冲突副本；
    /// 媒体文件仅当「整个索引都携带 mediaShas（新协议全覆盖）」且无任何存活条目
    /// 引用同一 sha 时才删除——旧索引或引用不明时宁可保留文件，绝不误删。
    private func cleanupExpiredRemoteEntities(_ manifest: inout Manifest, now: Date, retention: TimeInterval) async throws {
        let cutoff = now.addingTimeInterval(-retention)
        let expired = manifest.entries.filter { $0.deleted && ($0.deletedAt ?? $0.updatedAt) < cutoff }
        guard !expired.isEmpty else { return }

        let liveEntries = manifest.entries.filter { !($0.deleted && ($0.deletedAt ?? $0.updatedAt) < cutoff) }
        // 引用完整性只有在新协议索引（全部条目携带 mediaShas）下才可信
        let mediaRefComplete = !liveEntries.isEmpty && liveEntries.allSatisfy { $0.mediaShas != nil }
        let referencedShas = Set(liveEntries.flatMap { $0.mediaShas ?? [] })

        var cleanedEntries = 0
        var cleanedMedia = 0
        for item in expired {
            // A03：条目对象已按内容版本化（<uuid>-<hash8>.json，历史为 <uuid>.json），
            // 保留期内各版本可能并存。到期清理按条目 ID 前缀删除全部版本对象；
            // 目录不可枚举时至少尝试已知路径。delete 对不存在的对象是幂等的。
            try await deleteEntryObjects(of: item)
            let conflictFiles = try await provider.list("/Wuyan/entries/conflicts/")
            for file in conflictFiles where !file.isDirectory &&
                file.path.hasPrefix("/Wuyan/entries/conflicts/\(item.id.uuidString)-conflict-") {
                try await provider.delete(file.path)
            }
            if mediaRefComplete, let shas = item.mediaShas {
                for sha in shas where !referencedShas.contains(sha) {
                    try await provider.delete(SyncPaths.thumbnailPath(sha256: sha))
                    let prefix = String(sha.prefix(2))
                    let mediaFiles = try await provider.list("/Wuyan/media/\(prefix)/")
                    for file in mediaFiles where !file.isDirectory && file.path.contains(sha) {
                        try await provider.delete(file.path)
                    }
                    cleanedMedia += 1
                }
            }
            try database.entryDAO.dropTombstone(id: item.id)
            try database.entryDAO.dropConflictCopy(id: item.id)
            cleanedEntries += 1
        }
        if cleanedEntries > 0 {
            WuyanLog.sync.info("已清理 \(cleanedEntries) 个超过 90 天保留期的远端删除对象（媒体 \(cleanedMedia) 个）")
        }
    }

    /// A03：按条目 ID 前缀删除其在远端的全部版本对象（含旧版无哈希路径）。
    private func deleteEntryObjects(of item: ManifestEntry) async throws {
        let directory = (item.path as NSString).deletingLastPathComponent + "/"
        let files = try await provider.list(directory)
        let prefix = item.id.uuidString
        var targets = files
            .filter { !$0.isDirectory && ($0.path as NSString).lastPathComponent.hasPrefix(prefix) }
            .map(\.path)
        if targets.isEmpty { targets = [item.path] }
        for path in targets {
            try await provider.delete(path)
        }
    }

    // 懒加载本机「已上传媒体路径」缓存：sync_upload_cache 表 + 本次同步内新增。
    // D08：缓存按后端指纹隔离，跨多次 uploadMedia 复用，避免重复探测/写入。
    private func uploadedCache() throws -> Set<String> {
        if let cache = mediaCache { return cache }
        let cache = try database.mediaAssetDAO.uploadedPaths(backend: backendFingerprint)
        mediaCache = cache
        return cache
    }

    /// A02：日札拉取采用与条目一致的三方合并，以 daynote_baseline 为同步基线：
    /// - 仅本地修改（基线 == 远端哈希）→ 保留本地，由推送阶段上传；
    /// - 仅远端修改（基线 == 本地哈希）→ 落地远端并更新基线；
    /// - 双端修改 / 无基线（历史数据、恢复的库）→ 本地优先（未同步的用户编辑
    ///   绝不能被远端旧版本静默覆盖），推送阶段覆盖远端，同时记录警告日志；
    /// - 哈希一致 → 无操作并补记基线。
    private func pullRemoteDayNotes(
        from manifest: Manifest,
        localHashes: [String: String],
        baselines: [String: String],
        progress: inout SyncProgress
    ) async throws -> Int {
        var pulled = 0
        for remote in manifest.daynotes {
            if let y = year(ofDayKey: remote.date), archivedYears.contains(y), localHashes[remote.date] == nil {
                progress.completedUnitCount += 1
                continue
            }
            progress.detail = remote.date
            await self.report(progress)
            // 用预算好的本地哈希表比对，避免对每条远端日札都查一次库。
            let localHash = localHashes[remote.date]
            if localHash == remote.hash {
                // 一致：补记基线（恢复的旧库可能还没有），跳过拉取。
                if baselines[remote.date] != remote.hash {
                    try database.dayNoteDAO.setBaseline(date: remote.date, hash: remote.hash)
                }
                progress.completedUnitCount += 1
                continue
            }
            guard let localHash else {
                // 本地没有这条 → 拉取并确认基线。
                let data = try await provider.get(remote.path)
                let note = try decode(DayNote.self, from: data)
                try database.dayNoteDAO.upsert(note)
                try database.dayNoteDAO.setBaseline(date: remote.date, hash: remote.hash)
                pulled += 1
                progress.completedUnitCount += 1
                continue
            }
            let baseline = baselines[remote.date]
            if baseline == remote.hash {
                // 仅本地修改：保留本地，留给推送阶段。
            } else if baseline == localHash {
                // 仅远端修改：拉取远端并更新基线。
                let data = try await provider.get(remote.path)
                let note = try decode(DayNote.self, from: data)
                try database.dayNoteDAO.upsert(note)
                try database.dayNoteDAO.setBaseline(date: remote.date, hash: remote.hash)
                pulled += 1
            } else {
                // 双端修改或无基线：保留本地版本并把远端落败版本留档，
                // 由推送阶段把本地版本写回远端，避免静默丢失另一端的日札。
                let data = try await provider.get(remote.path)
                let remoteNote = try decode(DayNote.self, from: data)
                try database.dayNoteDAO.saveConflictCopy(remoteNote)
                WuyanLog.sync.warning("日札 \(remote.date) 双端均有修改，远端版本已保存到本地冲突留档")
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
        // D02：冲突副本同样携带附件元数据，之后可完整恢复该版本。
        let envelope = try buildEnvelope(for: entry)
        let data = try encode(envelope)
        try await provider.put(path, data: data, contentType: "application/json")
        // UI-06：副本同步留档本地，应用内冲突列表可查看与恢复。
        try database.entryDAO.saveConflictCopy(entry: entry, envelope: try encoder.encode(envelope), remotePath: path)
    }

    /// D11：把本地保留的删除墓碑写入索引（deleted=true）。
    /// 彻底删除后条目行已不存在，dirtyEntries 不再包含它；没有墓碑，
    /// 其它设备（以及本机下一轮拉取）会把远端旧对象当新数据拉回来。
    private func pushTombstones(into manifest: inout Manifest) throws {
        var purged = try database.syncStateDAO.purgedEntries()
        for item in manifest.purged ?? [] where item.deletedAt > (purged[item.id] ?? .distantPast) {
            purged[item.id] = item.deletedAt
        }
        for tombstone in try database.entryDAO.pendingTombstones() {
            if purged[tombstone.id] != nil {
                // V3-15：永久清除记录优先于本地墓碑，不能把已清除条目重新塞回索引。
                try database.entryDAO.dropTombstone(id: tombstone.id)
                continue
            }
            if let index = manifest.entries.firstIndex(where: { $0.id == tombstone.id }) {
                manifest.entries[index] = tombstone
            } else {
                manifest.entries.append(tombstone)
            }
            changedEntryIDs.insert(tombstone.id)
        }
    }

    /// D02：构造含附件元数据的同步包。设备私有路径不上传（置 nil），
    /// 文件本体按 sha256 内容寻址，接收端可按需下载。
    private func buildEnvelope(for entry: Entry) throws -> EntryEnvelope {
        var assets = try database.mediaAssetDAO.allAssets(for: entry.mediaIds)
        for index in assets.indices {
            assets[index].localPath = nil
            assets[index].thumbnailPath = nil
        }
        return EntryEnvelope(
            entry: entry,
            board: try database.boardDAO.board(id: entry.boardId),
            dayNote: try database.dayNoteDAO.note(dayKey: entry.dayDate),
            mediaAssets: assets.isEmpty ? nil : assets
        )
    }

    /// UI-04：条目索引项需要携带媒体引用清单，供保留期到期后的远端媒体清理判定引用。
    private func manifestItem(for entry: Entry, path: String) throws -> ManifestEntry {
        let shas = (try? database.mediaAssetDAO.allAssets(for: entry.mediaIds))?.map(\.sha256)
        return ManifestEntry(
            id: entry.id, boardId: entry.boardId, dayDate: entry.dayDate,
            path: path, updatedAt: entry.updatedAt, hash: entry.contentHash,
            deleted: entry.deleted, mediaShas: shas
        )
    }

    /// A06：生成推送计划。除了 dirty 条目，凡「远端索引缺失」的本地未删除条目
    /// 也一并加入——本地 clean 状态只证明它曾提交到某个后端，不能证明已提交到
    /// 当前后端。切换后端、后端被部分清空时，这批条目靠这里补传；
    /// 远端已有的条目仍按 dirty 判断，避免每轮全量重推。
    private func buildPushPlan(manifest: Manifest, shouldBootstrapBackend: Bool) throws -> [Entry] {
        var purged = try database.syncStateDAO.purgedEntries()
        for item in manifest.purged ?? [] where item.deletedAt > (purged[item.id] ?? .distantPast) {
            purged[item.id] = item.deletedAt
        }
        func allowed(_ entry: Entry) -> Bool {
            guard let deletedAt = purged[entry.id] else { return true }
            return entry.dirty && !entry.deleted && entry.updatedAt >= deletedAt
        }
        if shouldBootstrapBackend {
            return try database.entryDAO.timeline(filter: .all).filter(allowed)
        }
        var plan = Dictionary(uniqueKeysWithValues: try database.entryDAO.dirtyEntries().filter(allowed).map { ($0.id, $0) })
        let remoteLiveIDs = Set(manifest.entries.filter { !$0.deleted }.map(\.id))
        for entry in try database.entryDAO.timeline(filter: .all) where !remoteLiveIDs.contains(entry.id) && allowed(entry) {
            plan[entry.id] = entry
        }
        return plan.values.sorted { $0.updatedAt < $1.updatedAt }
    }

    private func pushDirtyEntries(
        _ dirty: [Entry],
        into manifest: inout Manifest,
        report: inout SyncReport,
        progress: inout SyncProgress,
        pendingCleans: inout [(id: UUID, hash: String)],
        pushedPaths: inout [UUID: String]
    ) async throws -> Int {
        var pushed = 0
        var indexes = Dictionary(uniqueKeysWithValues: manifest.entries.enumerated().map { ($0.element.id, $0.offset) })
        for entry in dirty {
            progress.detail = entry.dayDate
            await self.report(progress)
            report.mediaUploaded += try await uploadMedia(for: entry)
            let path = SyncPaths.entryPath(entry)
            let parent = (path as NSString).deletingLastPathComponent
            try await provider.mkcolRecursive(parent + "/")
            let envelope = try buildEnvelope(for: entry)
            let data = try encode(envelope)
            try await provider.put(path, data: data, contentType: "application/json")
            // A03：记录本机写入的版本对象路径，提交成功后按胜负决定保留/清理。
            pushedPaths[entry.id] = path
            // D03：不再在这里 markClean——manifest 还没提交。条目可能仍在远端
            // 「不可发现」状态，此时清 dirty 会让重试跳过它，写出空索引。
            pendingCleans.append((id: entry.id, hash: entry.contentHash))
            let item = try manifestItem(for: entry, path: path)
            if let index = indexes[entry.id] {
                manifest.entries[index] = item
            } else {
                indexes[entry.id] = manifest.entries.count
                manifest.entries.append(item)
            }
            changedEntryIDs.insert(entry.id)
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
        progress: inout SyncProgress,
        pushedPaths: inout [String: String]
    ) async throws -> Int {
        var pushed = 0
        var indexes = Dictionary(uniqueKeysWithValues: manifest.daynotes.enumerated().map { ($0.element.date, $0.offset) })
        // C01：一次推送共享同一个身份令牌。日札没有编辑时间戳，恢复旧内容后再推送
        // 必须落到全新路径，保证被 GC 登记的孤儿路径永远不会被再次写入。
        let pushedAt = Date()
        for note in notes {
            progress.detail = note.date
            await self.report(progress)
            let hash = Hashing.dayNoteHash(note)
            let path = SyncPaths.dayNotePath(note, pushedAt: pushedAt)
            let parent = (path as NSString).deletingLastPathComponent
            try await provider.mkcolRecursive(parent + "/")
            let data = try encode(note)
            try await provider.put(path, data: data, contentType: "application/json")
            // B05：记录本机写入的日札版本对象路径，提交后登记孤儿由延迟 GC 处理。
            pushedPaths[note.date] = path
            let item = ManifestDayNote(date: note.date, path: path, updatedAt: pushedAt, hash: hash)
            if let index = indexes[note.date] {
                manifest.daynotes[index] = item
            } else {
                indexes[note.date] = manifest.daynotes.count
                manifest.daynotes.append(item)
            }
            changedDayNoteDates.insert(note.date)
            pushed += 1
            progress.completedUnitCount += 1
        }
        progress.detail = nil
        await self.report(progress)
        return pushed
    }

    /// B01/C01：版本对象的延迟垃圾回收。
    /// 1) 登记：本次提交后被取代（推送前路径）或落败（本机写入但未被最终索引
    ///    采纳）的版本对象路径写入 sync_orphan，按后端隔离，保留最早发现时间；
    /// 2) 删除：超过宽限期且删除前重读最新索引确认未被引用的孤儿才删除；
    ///    单个删除失败保留登记，下一轮重试。
    /// C01 安全论证：对象路径是「每次提交不复用的身份」——条目路径含 updatedAt
    /// （每次保存刷新），日札路径含推送时刻令牌。其它设备「恢复旧内容」必然产生
    /// 一个从未用过的新路径并在提交索引前先写入对象；因此「复核时未被引用」的
    /// 孤儿路径在删除之后也不可能被新提交的索引引用，检查与删除之间的竞争窗口
    /// 被协议性关闭，而不是靠宽限期缩小概率。
    private func reconcileOrphanVersions(
        savedManifest: Manifest,
        previousEntryPaths: [UUID: String],
        pushedEntryPaths: [UUID: String],
        previousNotePaths: [String: String],
        pushedNotePaths: [String: String]
    ) async throws {
        let referencedEntries = Set(savedManifest.entries.map(\.path))
        let referencedNotes = Set(savedManifest.daynotes.map(\.path))
        var orphans = Set<String>()
        for path in Set(previousEntryPaths.values).union(pushedEntryPaths.values)
        where !referencedEntries.contains(path) {
            orphans.insert(path)
        }
        for path in Set(previousNotePaths.values).union(pushedNotePaths.values)
        where !referencedNotes.contains(path) {
            orphans.insert(path)
        }
        try database.syncStateDAO.recordOrphans(paths: Array(orphans), backend: backendFingerprint, now: Date())

        let due = try database.syncStateDAO.dueOrphans(
            backend: backendFingerprint,
            before: Date().addingTimeInterval(-orphanGraceInterval)
        )
        guard !due.isEmpty else { return }
        let snapshot = try await provider.getVersioned(SyncPaths.manifest)
        let fresh = try decodeManifestData(snapshot.data)
        let freshReferenced = Set(fresh.entries.map(\.path)).union(fresh.daynotes.map(\.path))
        var deleted: [String] = []
        for path in due where !freshReferenced.contains(path) {
            do {
                try await provider.delete(path)
                deleted.append(path)
            } catch {
                // 保留登记，下一轮重试。
                WuyanLog.sync.info("孤儿对象删除失败，稍后重试：\(path)")
            }
        }
        // 仍被最新索引引用的路径同样出表：它们已被「救回」，不再是孤儿；
        // 若将来再次被取代会重新登记并重新计时。
        try database.syncStateDAO.dropOrphanPaths(deleted + due.filter { freshReferenced.contains($0) }, backend: backendFingerprint)
        if !deleted.isEmpty {
            WuyanLog.sync.info("延迟 GC 清理 \(deleted.count) 个不再被引用的旧版本对象")
        }
    }

    /// C01：缺失对象巡检。按注入的间隔限频（0 = 每轮都查）。
    /// 对最新索引里的每个活动条目/日札/媒体引用：远端对象不存在且本机持有指纹
    /// 一致的副本时重新上传。只补对象，不改索引内容（路径与哈希不变），
    /// 因此紧跟其后的 saveManifest 对其它设备而言仍是同一份索引。
    private func auditMissingRemoteObjects(
        manifest: Manifest,
        report: inout SyncReport,
        progress: inout SyncProgress
    ) async throws {
        let auditKey = "sync.lastObjectAudit.\(backendFingerprint)"
        let now = Date()
        if missingObjectAuditInterval > 0,
           let stored = try database.syncStateDAO.value(forKey: auditKey),
           let lastAudit = Date(timeIntervalSince1970String: stored),
           now.timeIntervalSince(lastAudit) < missingObjectAuditInterval {
            return
        }
        // 先记时间戳再巡检：巡检中途失败也不至于每轮同步都全量探测；
        // 本轮没补上的对象下一轮巡检周期仍会发现。
        try database.syncStateDAO.set(now.timeIntervalSince1970String, forKey: auditKey)

        progress.detail = "检查远端对象完整性"
        await self.report(progress)
        var repaired = 0
        for item in manifest.entries where !item.deleted {
            if let y = year(ofDayKey: item.dayDate), archivedYears.contains(y) { continue }
            guard let local = try database.entryDAO.entry(id: item.id),
                  local.contentHash == item.hash else { continue }
            if try await provider.exists(item.path) { continue }
            // 与 pushEntries 一致：PUT 前确保父目录（ensureRemoteTree 只建顶层骨架，
            // 年/月子目录由各推送路径自建；远端目录被清后不补建会 404）。
            try await provider.mkcolRecursive((item.path as NSString).deletingLastPathComponent + "/")
            let envelope = try buildEnvelope(for: local)
            try await provider.put(item.path, data: try encode(envelope), contentType: "application/json")
            repaired += 1
            WuyanLog.sync.warning("巡检补传缺失的条目对象：\(item.path)")
        }
        for item in manifest.daynotes {
            guard let local = try database.dayNoteDAO.note(dayKey: item.date),
                  Hashing.dayNoteHash(local) == item.hash else { continue }
            if try await provider.exists(item.path) { continue }
            try await provider.mkcolRecursive((item.path as NSString).deletingLastPathComponent + "/")
            try await provider.put(item.path, data: try encode(local), contentType: "application/json")
            repaired += 1
            WuyanLog.sync.warning("巡检补传缺失的日札对象：\(item.path)")
        }
        // 媒体与缩略图：内容寻址对象同样可能因历史缺陷/后端丢失而缺失。
        for item in manifest.entries where !item.deleted {
            if let y = year(ofDayKey: item.dayDate), archivedYears.contains(y) { continue }
            guard let local = try database.entryDAO.entry(id: item.id),
                  local.contentHash == item.hash else { continue }
            let assets = try database.mediaAssetDAO.allAssets(for: local.mediaIds)
            for asset in assets {
                // R4-01：原图与缩略图分开巡检。原图远端已存在不能跳过缩略图检查；
                // 本地原件缺失（懒下载设备只缓存了缩略图）也只跳过原图补传，
                // 缩略图仍按自身路径补齐。
                let remotePath = crypto == nil || writesPlaintext
                    ? SyncPaths.mediaPath(sha256: asset.sha256, filename: asset.filename)
                    : SyncPaths.encryptedMediaPath(sha256: asset.sha256, filename: asset.filename)
                if let absolutePath = asset.absoluteLocalPath,
                   FileManager.default.fileExists(atPath: absolutePath),
                   try await provider.exists(remotePath) == false {
                    let digest = try Hashing.sha256Hex(ofFileAt: URL(fileURLWithPath: absolutePath))
                    // 本地副本指纹不一致时不传损坏内容，但缩略图检查照常进行。
                    if digest == asset.sha256 {
                        try await provider.mkcolRecursive((remotePath as NSString).deletingLastPathComponent + "/")
                        if crypto == nil || writesPlaintext {
                            try await provider.putChunked(remotePath, fileURL: URL(fileURLWithPath: absolutePath), chunkSize: 8 * 1024 * 1024)
                        } else {
                            let data = try Data(contentsOf: URL(fileURLWithPath: absolutePath))
                            try await provider.put(remotePath, data: try encodeRaw(data), contentType: "application/octet-stream")
                        }
                        repaired += 1
                        WuyanLog.sync.warning("巡检补传缺失的媒体对象：\(remotePath)")
                    }
                }
                if asset.thumbnailPath != nil, let thumbPath = asset.absoluteThumbnailPath,
                   FileManager.default.fileExists(atPath: thumbPath) {
                    let thumbRemote = SyncPaths.thumbnailPath(sha256: asset.sha256)
                    if try await provider.exists(thumbRemote) == false {
                        try await provider.mkcolRecursive("/Wuyan/media/thumbnails/")
                        if crypto == nil || writesPlaintext {
                            try await provider.putChunked(thumbRemote, fileURL: URL(fileURLWithPath: thumbPath), chunkSize: 512 * 1024)
                        } else {
                            let thumbData = try Data(contentsOf: URL(fileURLWithPath: thumbPath))
                            try await provider.put(thumbRemote, data: try encodeRaw(thumbData), contentType: "application/octet-stream")
                        }
                        repaired += 1
                        WuyanLog.sync.warning("巡检补传缺失的缩略图对象：\(thumbRemote)")
                    }
                }
            }
        }
        report.repaired += repaired
        if repaired > 0 {
            WuyanLog.sync.info("缺失对象巡检完成，补传 \(repaired) 个对象")
        }
        progress.detail = nil
        await self.report(progress)
    }

    /// 迁移远端已有对象，不依赖本机是否仍保留归档年份、回收站或冲突副本。
    /// 每个对象先解密并成功写入目标格式，再删除旧媒体路径；中途失败可从剩余旧对象重试。
    private func migrateRemoteObjects(in manifest: Manifest, toPlaintext: Bool) async throws {
        guard crypto != nil else { return }

        for item in manifest.entries {
            guard try await provider.exists(item.path) else { continue }
            let raw = try await provider.get(item.path)
            let plain = try plaintextRemoteData(raw)
            let envelope = try decoder.decode(EntryEnvelope.self, from: plain)
            let output = toPlaintext ? plain : try encodeRaw(plain)
            try await provider.put(item.path, data: output, contentType: "application/json")

            for asset in envelope.mediaAssets ?? [] {
                let plainPath = SyncPaths.mediaPath(sha256: asset.sha256, filename: asset.filename)
                let encryptedPath = SyncPaths.encryptedMediaPath(sha256: asset.sha256, filename: asset.filename)
                let sourcePath: String
                if try await provider.exists(encryptedPath) {
                    sourcePath = encryptedPath
                } else if try await provider.exists(plainPath) {
                    sourcePath = plainPath
                } else {
                    throw RemoteStorageError.archiveVerificationFailed(path: plainPath)
                }
                let mediaPlain = try plaintextRemoteData(try await provider.get(sourcePath))
                let digest = SHA256.hash(data: mediaPlain).map { String(format: "%02x", $0) }.joined()
                guard digest == asset.sha256 else {
                    throw RemoteStorageError.archiveVerificationFailed(path: sourcePath)
                }
                let targetPath = toPlaintext ? plainPath : encryptedPath
                let targetData = toPlaintext ? mediaPlain : try encodeRaw(mediaPlain)
                try await provider.put(targetPath, data: targetData, contentType: "application/octet-stream")
                if targetPath != sourcePath {
                    try await provider.delete(sourcePath)
                }

                let thumbnailPath = SyncPaths.thumbnailPath(sha256: asset.sha256)
                if try await provider.exists(thumbnailPath) {
                    let thumbnailPlain = try plaintextRemoteData(try await provider.get(thumbnailPath))
                    let thumbnailData = toPlaintext ? thumbnailPlain : try encodeRaw(thumbnailPlain)
                    try await provider.put(thumbnailPath, data: thumbnailData, contentType: "application/octet-stream")
                }
            }
        }

        for note in manifest.daynotes {
            let raw = try await provider.get(note.path)
            let plain = try plaintextRemoteData(raw)
            let output = toPlaintext ? plain : try encodeRaw(plain)
            try await provider.put(note.path, data: output, contentType: "application/json")
        }

        // 冲突副本和设备状态不出现在 manifest，但同样可能包含日记明文。
        for root in ["/Wuyan/entries/conflicts/", "/Wuyan/.sync/"] {
            let files = try await provider.list(root)
            for file in files where !file.isDirectory {
                let raw = try await provider.get(file.path)
                let plain = try plaintextRemoteData(raw)
                let output = toPlaintext ? plain : try encodeRaw(plain)
                try await provider.put(file.path, data: output, contentType: "application/json")
            }
        }

        // 盘点媒体目录中的孤立对象，覆盖没有可用 EntryEnvelope 元数据的历史附件。
        // WebDAV 返回一层目录、S3 返回扁平对象列表，因此统一递归展开；缩略图
        // 没有 `.enc` 后缀，迁移时必须原路径覆写，否则关闭加密会留下密文缩略图。
        let files = try await remoteFilesRecursively(at: "/Wuyan/media/")
        for file in files where !file.path.hasSuffix(".part") {
            let isThumbnail = file.path.contains("/thumbnails/")
            let raw = try await provider.get(file.path)
            let plain = try plaintextRemoteData(raw)
            if toPlaintext {
                guard !isThumbnail, file.path.hasSuffix(".enc") else {
                    // 缩略图目标路径不变；只有密文原件使用 `.enc` 后缀。
                    if isThumbnail, raw != plain {
                        try await provider.put(file.path, data: plain, contentType: "application/octet-stream")
                    }
                    continue
                }
                let plainPath = String(file.path.dropLast(4))
                try await provider.put(plainPath, data: plain, contentType: "application/octet-stream")
                try await provider.delete(file.path)
            } else if isThumbnail {
                // 加密缩略图沿用原路径，下载端按负载格式识别。
                if raw == plain {
                    try await provider.put(file.path, data: try encodeRaw(plain), contentType: "application/octet-stream")
                }
            } else if !file.path.hasSuffix(".enc") {
                try await provider.put(file.path + ".enc", data: try encodeRaw(plain), contentType: "application/octet-stream")
                try await provider.delete(file.path)
            }
        }
    }

    private func remoteFilesRecursively(at path: String) async throws -> [RemoteItem] {
        var files: [RemoteItem] = []
        for item in try await provider.list(path) {
            if item.isDirectory {
                let childPath = item.path.hasSuffix("/") ? item.path : item.path + "/"
                guard childPath != path else { continue }
                files.append(contentsOf: try await remoteFilesRecursively(at: childPath))
            } else {
                files.append(item)
            }
        }
        return files
    }

    private func plaintextRemoteData(_ data: Data) throws -> Data {
        guard crypto != nil else { return data }
        if let payload = try? decoder.decode(EncryptedPayload.self, from: data),
           Data(base64Encoded: payload.ciphertextBase64) != nil {
            return try decodeRaw(data)
        }
        guard plaintextTolerated else {
            throw SyncError.decryptFailed(reason: "远端对象不是加密格式，可能被篡改")
        }
        return data
    }

    private func uploadMedia(for entry: Entry) async throws -> Int {
        let assets = try database.mediaAssetDAO.allAssets(for: entry.mediaIds)
        let cache = try uploadedCache()
        var uploaded = 0
        var newlyUploaded: [String] = []
        for asset in assets {
            guard asset.localPath != nil, let absoluteLocalPath = asset.absoluteLocalPath else { continue }
            // R2-1: 使用模型层计算属性替代 LocalMediaStore.resolvePath
            let remotePath = crypto == nil || writesPlaintext
                ? SyncPaths.mediaPath(sha256: asset.sha256, filename: asset.filename)
                : SyncPaths.encryptedMediaPath(sha256: asset.sha256, filename: asset.filename)
            let forceMediaRewrite = (writesPlaintext || cryptoNeedsReEncrypt) && !remoteMediaMigrated
            // 内容寻址媒体一旦上传就永久存在：命中缓存直接跳过；未命中才探测一次远端，
            // 探测结果（在或刚传）都记进缓存，后续同步不再逐个 PROPFIND。
            let needsMediaUpload: Bool
            if forceMediaRewrite {
                needsMediaUpload = true
            } else if cache.contains(remotePath) {
                needsMediaUpload = false
            } else {
                let remoteExists = try await provider.exists(remotePath)
                needsMediaUpload = !remoteExists
            }
            if needsMediaUpload {
                let parent = (remotePath as NSString).deletingLastPathComponent
                try await provider.mkcolRecursive(parent + "/")
                if crypto == nil || writesPlaintext {
                    try await provider.putResumable(remotePath, fileURL: URL(fileURLWithPath: absoluteLocalPath), chunkSize: 8 * 1024 * 1024)
                } else {
                    let data = try Data(contentsOf: URL(fileURLWithPath: absoluteLocalPath))
                    try await provider.put(remotePath, data: try encodeRaw(data), contentType: "application/octet-stream")
                }
                uploaded += 1
                newlyUploaded.append(remotePath)
                mediaCache?.insert(remotePath)
            }

            if writesPlaintext && !remoteMediaMigrated {
                // 迁移完成后清理同一媒体的旧密文对象，避免关闭加密后仍保留可读密文。
                try await provider.delete(SyncPaths.encryptedMediaPath(sha256: asset.sha256, filename: asset.filename))
            } else if cryptoNeedsReEncrypt && !remoteMediaMigrated {
                // 明文→加密迁移成功写入密文后，删除同一对象的旧明文副本。
                try await provider.delete(SyncPaths.mediaPath(sha256: asset.sha256, filename: asset.filename))
            }

            if asset.thumbnailPath != nil, let absoluteThumbnailPath = asset.absoluteThumbnailPath {
                // R2-1: 使用模型层计算属性替代 LocalMediaStore.resolvePath
                let thumbnailRemotePath = SyncPaths.thumbnailPath(sha256: asset.sha256)
                if (!remoteMediaMigrated && (writesPlaintext || cryptoNeedsReEncrypt)) || !cache.contains(thumbnailRemotePath) {
                    let thumbnailExists = try await provider.exists(thumbnailRemotePath)
                    if (!remoteMediaMigrated && (writesPlaintext || cryptoNeedsReEncrypt)) || !thumbnailExists {
                        try await provider.mkcolRecursive("/Wuyan/media/thumbnails/")
                        if crypto == nil || writesPlaintext {
                            try await provider.putChunked(thumbnailRemotePath, fileURL: URL(fileURLWithPath: absoluteThumbnailPath), chunkSize: 512 * 1024)
                        } else {
                            // S02：加密模式下缩略图与原件同等对待——照片/视频缩略图
                            // 直接暴露内容，明文字节不允许出站。
                            let thumbnailData = try Data(contentsOf: URL(fileURLWithPath: absoluteThumbnailPath))
                            try await provider.put(thumbnailRemotePath, data: try encodeRaw(thumbnailData), contentType: "application/octet-stream")
                        }
                        uploaded += 1
                    }
                    if writesPlaintext {
                        // 缩略图路径不变，写入明文后旧密文会被覆盖。
                    }
                    newlyUploaded.append(thumbnailRemotePath)
                    mediaCache?.insert(thumbnailRemotePath)
                }
            }
        }
        if !newlyUploaded.isEmpty {
            try database.mediaAssetDAO.recordUploaded(paths: newlyUploaded, backend: backendFingerprint)
        }
        return uploaded
    }

    private func saveDeviceState(_ report: SyncReport) async throws {
        let deviceId = deviceId()
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

    /// Hash a plaintext remote object in bounded ranges. This keeps archive
    /// verification and recovery audits from materializing large videos in
    /// memory when the backend supports range reads.
    private func remoteSHA256(_ path: String, expectedSize: Int64?) async throws -> String {
        guard let size = try await provider.contentLength(path) else {
            throw RemoteStorageError.archiveVerificationFailed(path: path)
        }
        if let expectedSize, expectedSize != size {
            throw RemoteStorageError.archiveVerificationFailed(path: path)
        }
        var hasher = SHA256()
        let chunkSize: Int64 = 8 * 1024 * 1024
        var offset: Int64 = 0
        while offset < size {
            let end = min(size, offset + chunkSize)
            let chunk = try await provider.getRange(path, bytes: offset..<end)
            guard !chunk.isEmpty else {
                throw RemoteStorageError.archiveVerificationFailed(path: path)
            }
            hasher.update(data: chunk)
            offset += Int64(chunk.count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
        guard let crypto, !writesPlaintext else { return data }
        // UI-01：对象加密统一走数据密钥（DEK）。远端还没有索引时在此生成新头，
        // 保证首推对象与随后的索引使用同一把数据密钥。
        if crypto.currentHeader == nil {
            _ = try crypto.makeFreshHeaderIfAbsent()
        }
        let dek = try crypto.dekForKeyId(crypto.currentKeyId)
        let ciphertext = try crypto.box.seal(data, key: dek)
        let payload = EncryptedPayload(
            schemaVersion: 3,
            algorithm: "AES-GCM",
            keyId: crypto.currentKeyId,
            ciphertextBase64: ciphertext.base64EncodedString()
        )
        return try encoder.encode(payload)
    }

    private func decodeRaw(_ data: Data) throws -> Data {
        guard let crypto else { return data }
        // 优先解析加密负载（兼容 v1/v2 旧格式与 v3 数据密钥格式）。
        if let payload = try? decoder.decode(EncryptedPayload.self, from: data),
           let ciphertext = Data(base64Encoded: payload.ciphertextBase64) {
            if payload.schemaVersion >= 3 {
                let dek = try crypto.dekForKeyId(payload.keyId)
                do {
                    return try crypto.box.open(ciphertext, key: dek)
                } catch {
                    throw SyncError.decryptFailed(reason: "解密失败：数据密钥不匹配或文件被篡改（\(error.localizedDescription)）")
                }
            }
            // v1/v2 旧格式：逐对象 PBKDF2 口令派生。读取成功后标记升级重传。
            do {
                let key = try crypto.key(forSaltBase64: payload.saltBase64 ?? "", iterations: payload.iterations ?? 0)
                let plaintext = try crypto.box.open(ciphertext, key: key)
                cryptoNeedsReEncrypt = true
                WuyanLog.sync.info("检测到旧版加密对象，将升级为数据密钥格式")
                return plaintext
            } catch let e as SyncError {
                throw e
            } catch {
                throw SyncError.decryptFailed(reason: "解密失败：口令可能不正确（\(error.localizedDescription)）")
            }
        }
        guard plaintextTolerated else {
            throw SyncError.decryptFailed(reason: "远端对象不是加密格式，可能被篡改")
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
        // 节流转发：阶段切换与完成时刻立即透出，其余按固定频率合并，
        // 避免逐条目进度把主线程拖满。
        let now = ContinuousClock.now
        let phaseChanged = progress.phase != lastReportedProgress?.phase
        let finished = progress.totalUnitCount > 0
            && progress.completedUnitCount >= progress.totalUnitCount
        guard phaseChanged || finished || now - lastReportedAt >= Self.reportThrottleInterval else { return }
        lastReportedAt = now
        lastReportedProgress = progress
        await progressHandler?(progress)
    }

    private func deviceId() -> String {
        let key = "sync.deviceId"
        if let existing = try? database.syncStateDAO.value(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        try? database.syncStateDAO.set(created, forKey: key)
        return created
    }
}

/// C01：巡检时间戳在 sync_state 中以 Unix 秒字符串存放。
private extension Date {
    init?(timeIntervalSince1970String: String) {
        guard let interval = Double(timeIntervalSince1970String) else { return nil }
        self = Date(timeIntervalSince1970: interval)
    }

    var timeIntervalSince1970String: String {
        String(timeIntervalSince1970)
    }
}
