import Foundation
import GRDB

public protocol EntryRepository {
    func observeTimeline(boardId: UUID?) -> AsyncStream<[Entry]>
    func entry(id: UUID) throws -> Entry?
    func save(_ entry: Entry) throws
    func softDelete(id: UUID) throws
}

public enum TimelineFilter: Equatable {
    case all
    case favorites
    case drafts
    case todayInHistory
    case board(UUID)
    case year(Int)
    case yearBoard(Int, UUID)
    case day(String)
}

public enum EntrySaveError: LocalizedError {
    case concurrentModification(UUID)

    public var errorDescription: String? {
        switch self {
        case let .concurrentModification(id):
            return "条目在保存前已被其它操作更新（\(id.uuidString.prefix(8))）。已保留当前编辑内容，请重新载入后再保存。"
        }
    }
}

public struct EntryDAO: EntryRepository {
    let writer: DatabaseWriter

    public func observeTimeline(boardId: UUID?) -> AsyncStream<[Entry]> {
        observeTimeline(filter: boardId.map(TimelineFilter.board) ?? .all)
    }

    public func observeTimeline(filter: TimelineFilter) -> AsyncStream<[Entry]> {
        let observation = ValueObservation.tracking { db in
            try fetchTimeline(db: db, filter: filter)
        }

        return AsyncStream { continuation in
            let cancellable = observation.start(
                in: writer,
                scheduling: .immediate,
                onError: { _ in continuation.finish() },
                onChange: { entries in continuation.yield(entries) }
            )
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }

    public func timeline(filter: TimelineFilter = .all) throws -> [Entry] {
        try writer.read { db in
            try fetchTimeline(db: db, filter: filter)
        }
    }

    func entries(on day: String) throws -> [Entry] {
        try writer.read { db in
            try Entry
                .filter(Entry.Columns.deleted == false)
                .filter(Entry.Columns.dayDate == day)
                .order(Entry.Columns.journalDate.asc, Entry.Columns.updatedAt.asc)
                .fetchAll(db)
        }
    }

    func timelineSummaries(filter: TimelineFilter = .all) throws -> [EntrySummary] {
        try writer.read { db in
            var sql = """
                SELECT id, dayDate, journalDate, title, substr(body, 1, 160) AS bodyPreview, length(body) AS bodyLength, isDraft
                FROM entry
                WHERE deleted = 0
                """
            var arguments = StatementArguments()

            switch filter {
            case .all:
                break
            case .favorites:
                sql += " AND isFavorite = 1"
            case .drafts:
                sql += " AND isDraft = 1"
            case .todayInHistory:
                let today = DayKey.today
                sql += " AND substr(dayDate, 6, 5) = ? AND substr(dayDate, 1, 4) != ?"
                arguments += [String(today.dropFirst(5)), String(today.prefix(4))]
            case let .board(id):
                sql += " AND boardId = ?"
                arguments += [id.uuidString]
            case let .year(year):
                sql += " AND substr(dayDate, 1, 4) = ?"
                arguments += [String(year)]
            case let .yearBoard(year, id):
                sql += " AND boardId = ? AND substr(dayDate, 1, 4) = ?"
                arguments += [id.uuidString, String(year)]
            case let .day(day):
                sql += " AND dayDate = ?"
                arguments += [day]
            }

            sql += " ORDER BY journalDate DESC, id DESC"
            return try EntrySummary.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    /// 观察单条条目（含正文）。供编辑器感知同步拉取、天气/定位回写等
    /// 对当前打开条目的外部改写，及时刷新版本基线而不是等保存时报冲突。
    func observeEntry(id: UUID) -> AsyncStream<Entry?> {
        let observation = ValueObservation.tracking { db in
            try Entry.fetchOne(db, key: id.uuidString)
        }

        return AsyncStream { continuation in
            let cancellable = observation.start(
                in: writer,
                scheduling: .immediate,
                onError: { _ in continuation.finish() },
                onChange: { entry in continuation.yield(entry) }
            )
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }

    /// 轻量观察：只返回 EntrySummary（不含 body/bodyRTF），用于时间线
    func observeTimelineSummaries(filter: TimelineFilter) -> AsyncStream<[EntrySummary]> {        let observation = ValueObservation.tracking { db in
            var sql = """
                SELECT id, dayDate, journalDate, title, substr(body, 1, 160) AS bodyPreview, length(body) AS bodyLength,
                       isFavorite, boardId, tags, isDraft
                FROM entry
                WHERE deleted = 0
                """
            var arguments = StatementArguments()

            switch filter {
            case .all:
                break
            case .favorites:
                sql += " AND isFavorite = 1"
            case .drafts:
                sql += " AND isDraft = 1"
            case .todayInHistory:
                let today = DayKey.today
                sql += " AND substr(dayDate, 6, 5) = ? AND substr(dayDate, 1, 4) != ?"
                arguments += [String(today.dropFirst(5)), String(today.prefix(4))]
            case let .board(id):
                sql += " AND boardId = ?"
                arguments += [id.uuidString]
            case let .year(year):
                sql += " AND substr(dayDate, 1, 4) = ?"
                arguments += [String(year)]
            case let .yearBoard(year, id):
                sql += " AND boardId = ? AND substr(dayDate, 1, 4) = ?"
                arguments += [id.uuidString, String(year)]
            case let .day(day):
                sql += " AND dayDate = ?"
                arguments += [day]
            }

            sql += " ORDER BY journalDate DESC, id DESC"
            return try EntrySummary.fetchAll(db, sql: sql, arguments: arguments)
        }

        return AsyncStream { continuation in
            let cancellable = observation.start(
                in: writer,
                scheduling: .immediate,
                onError: { _ in continuation.finish() },
                onChange: { summaries in continuation.yield(summaries) }
            )
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }

    /// 按 ID 批量查摘要（用于冲突列表等场景，不读 bodyRTF）
    func summaries(for ids: [UUID]) throws -> [UUID: EntrySummary] {
        guard !ids.isEmpty else { return [:] }
        return try writer.read { db in
            let idStrings = ids.map { $0.uuidString }
            let placeholders = idStrings.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT id, dayDate, journalDate, title, substr(body, 1, 160) AS bodyPreview, length(body) AS bodyLength, isDraft
                FROM entry
                WHERE id IN (\(placeholders))
                """
            let summaries: [EntrySummary] = try EntrySummary.fetchAll(db, sql: sql, arguments: StatementArguments(idStrings))
            return Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        }
    }

    /// 取最近 N 条摘要（不读 bodyRTF），供 AI 等不需要完整内容的场景
    func recentSummaries(limit: Int = 30) throws -> [EntrySummary] {
        try writer.read { db in
            let sql = """
                SELECT id, dayDate, journalDate, title, substr(body, 1, 160) AS bodyPreview, length(body) AS bodyLength, isDraft
                FROM entry
                WHERE deleted = 0
                ORDER BY journalDate DESC
                LIMIT ?
                """
            return try EntrySummary.fetchAll(db, sql: sql, arguments: [limit])
        }
    }

    /// R1-3: 取最近 N 条完整条目（含 body），供 AI 等需要内容的场景。
    /// 替代 timeline(filter: .all) 全量加载 + prefix(30) 的模式。
    func recentEntries(limit: Int = 30) throws -> [Entry] {
        try writer.read { db in
            try Entry
                .filter(Entry.Columns.deleted == false)
                .order(Entry.Columns.journalDate.desc, Entry.Columns.updatedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// 按业务时间范围读取完整条目，供回顾等明确范围的 AI 功能使用。
    /// 查询在数据库侧过滤，避免把多年正文全部加载到主线程后再截取。
    func entries(since date: Date) throws -> [Entry] {
        try writer.read { db in
            try Entry
                .filter(Entry.Columns.deleted == false)
                .filter(Entry.Columns.journalDate >= date)
                .order(Entry.Columns.journalDate.asc, Entry.Columns.updatedAt.asc)
                .fetchAll(db)
        }
    }

    public func entry(id: UUID) throws -> Entry? {
        try writer.read { db in
            try Entry.fetchOne(db, key: id.uuidString)
        }
    }

    public func save(_ entry: Entry) throws {
        try save(entry, expectedContentHash: nil)
    }

    /// 乐观并发保存：expectedContentHash 非 nil 时，只有数据库仍是加载时版本才写入。
    /// 编辑器、天气和定位等异步任务使用此入口，避免旧快照覆盖同步或用户的新编辑。
    public func save(_ entry: Entry, expectedContentHash: String?) throws {
        var entry = entry
        entry.refreshForSave()
        try writer.write { db in
            if let expectedContentHash,
               let current = try Entry.fetchOne(db, key: entry.id.uuidString),
               current.contentHash != expectedContentHash {
                throw EntrySaveError.concurrentModification(entry.id)
            }
            try entry.save(db)
        }
    }

    /// 只填充后台元数据中的空字段，并在同一写事务内重算同步指纹。
    /// 用户手工填写的天气/地点不会被后台结果覆盖；返回 false 表示没有可填字段。
    @discardableResult
    func fillMissingMetadata(id: UUID, weather: Weather?, location: GeoPlace?) throws -> Bool {
        try writer.write { db in
            guard var current = try Entry.fetchOne(db, key: id.uuidString),
                  !current.deleted
            else { return false }
            var changed = false
            if current.weather == nil, let weather {
                current.weather = weather
                changed = true
            }
            if current.location == nil, let location {
                current.location = location
                changed = true
            }
            guard changed else { return false }
            current.refreshForSave()
            try current.update(db)
            return true
        }
    }

    /// D02：在单一事务内落地远端条目（板块/日札/正文/附件元数据/基线），
    /// 避免中途失败留下「正文在、附件记录缺」的半成品状态。
    /// 已存在的本地附件记录优先保留——其 localPath 指向已下载的文件，不能被远端的 nil 覆盖。
    func saveRemoteFull(entry: Entry, board: Board?, dayNote: DayNote?, mediaAssets: [MediaAsset]) throws {
        try writer.write { db in
            if let board, try Board.fetchOne(db, key: board.id.uuidString) == nil {
                try board.save(db)
            }
            try dayNote?.save(db)
            var entry = entry
            entry.dirty = false
            try entry.save(db)
            for var asset in mediaAssets {
                guard try MediaAsset.fetchOne(db, key: asset.id.uuidString) == nil else { continue }
                asset.localPath = nil
                asset.thumbnailPath = nil
                try asset.insert(db)
            }
            try db.execute(
                sql: """
                INSERT INTO sync_baseline(entryId, hash, updatedAt)
                VALUES (?, ?, ?)
                ON CONFLICT(entryId) DO UPDATE SET hash = excluded.hash, updatedAt = excluded.updatedAt
                """,
                arguments: [entry.id.uuidString, entry.contentHash, entry.updatedAt]
            )
        }
    }

    /// V3-15：远端永久清除的条目移入本地回收站并标记为 clean，基线对齐新指纹。
    /// 在一个写事务内完成，避免清除后下一轮三方合并误判为本地改动。
    func applyRemotePurge(id: UUID) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE entry SET deleted = 1, dirty = 0, updatedAt = ? WHERE id = ?",
                arguments: [Date(), id.uuidString]
            )
            try Self.refreshSyncHash(id: id, db: db)
            if let hash = try String.fetchOne(db, sql: "SELECT contentHash FROM entry WHERE id = ?", arguments: [id.uuidString]) {
                try db.execute(
                    sql: """
                    INSERT INTO sync_baseline(entryId, hash, updatedAt) VALUES (?, ?, ?)
                    ON CONFLICT(entryId) DO UPDATE SET hash = excluded.hash, updatedAt = excluded.updatedAt
                    """,
                    arguments: [id.uuidString, hash, Date()]
                )
            }
            try db.execute(sql: "DELETE FROM sync_tombstone WHERE entryId = ?", arguments: [id.uuidString])
        }
    }

    /// UI-06：冲突解决——把留档副本写回为主版本或以新 ID 存为新条目。
    /// 重算同步指纹并置 dirty=true，等待下一次推送覆盖远端；
    /// 已存在的本地附件记录优先保留（保护已下载文件路径）。
    func saveResolvedConflict(entry: Entry, board: Board?, dayNote: DayNote?, mediaAssets: [MediaAsset]) throws {
        try writer.write { db in
            if let board, try Board.fetchOne(db, key: board.id.uuidString) == nil {
                try board.save(db)
            }
            try dayNote?.save(db)
            var entry = entry
            entry.refreshForSave()
            var remappedMediaIDs: [UUID: UUID] = [:]
            var normalizedAssets: [MediaAsset] = []
            for var asset in mediaAssets {
                // A conflict copy may be restored under a new entry ID. Enforce
                // ownership here as well as in the UI so a caller cannot make
                // two entries share the same media row and trigger cascade loss.
                if asset.entryId != entry.id {
                    let originalID = asset.id
                    asset.id = UUID()
                    asset.entryId = entry.id
                    remappedMediaIDs[originalID] = asset.id
                }
                asset.localPath = nil
                asset.thumbnailPath = nil
                normalizedAssets.append(asset)
            }
            if !remappedMediaIDs.isEmpty {
                entry.mediaIds = entry.mediaIds.map { remappedMediaIDs[$0] ?? $0 }
            }
            // UI 的“都保留”会先把资产复制成新 UUID；此时资产的 entryId
            // 已经是新条目，无法通过 entryId 判断是否需要重映射，必须把条目
            // 的媒体列表同步到本次实际写入的资产集合，避免继续引用旧行。
            let suppliedMediaIDs = normalizedAssets.map(\.id)
            if !normalizedAssets.isEmpty,
               Set(entry.mediaIds) != Set(suppliedMediaIDs) {
                entry.mediaIds = suppliedMediaIDs
            }
            try entry.save(db)
            for asset in normalizedAssets {
                guard try MediaAsset.fetchOne(db, key: asset.id.uuidString) == nil else { continue }
                try asset.insert(db)
            }
        }
    }

    func dirtyEntries() throws -> [Entry] {
        try writer.read { db in
            try Entry
                .filter(Entry.Columns.dirty == true)
                .order(Entry.Columns.updatedAt.asc)
                .fetchAll(db)
        }
    }

    /// 条件更新：只有条目的 contentHash 与推送快照时一致，才清除 dirty 标记。
    /// 防止推送期间用户又编辑了同一条目，新编辑被误清 dirty 导致永远不再推送。
    /// R0-3: baseline 写入 expectedHash（推送时的 hash），而非 entry.contentHash（当前可能已变更），
    /// 避免三方合并时 baseline 与实际推送版本不一致导致静默数据丢失。
    func markClean(id: UUID, expectedHash: String) throws {
        try writer.write { db in
            // 条件更新：hash 匹配才清 dirty
            try db.execute(
                sql: "UPDATE entry SET dirty = 0 WHERE id = ? AND contentHash = ?",
                arguments: [id.uuidString, expectedHash]
            )
            // baseline 写入推送时的 expectedHash（代表推送版本的水位线）
            if let entry = try Entry.fetchOne(db, key: id.uuidString) {
                try db.execute(
                    sql: """
                    INSERT INTO sync_baseline(entryId, hash, updatedAt)
                    VALUES (?, ?, ?)
                    ON CONFLICT(entryId) DO UPDATE SET hash = excluded.hash, updatedAt = excluded.updatedAt
                    """,
                    arguments: [id.uuidString, expectedHash, entry.updatedAt]
                )
            }
        }
    }

    func baselineHash(id: UUID) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT hash FROM sync_baseline WHERE entryId = ?", arguments: [id.uuidString])
        }
    }

    func upsertBaseline(for entry: Entry) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_baseline(entryId, hash, updatedAt)
                VALUES (?, ?, ?)
                ON CONFLICT(entryId) DO UPDATE SET hash = excluded.hash, updatedAt = excluded.updatedAt
                """,
                arguments: [entry.id.uuidString, entry.contentHash, entry.updatedAt]
            )
        }
    }

    /// 一次性把全部条目的同步比对所需字段（contentHash + deleted）读成字典，
    /// 供 SyncEngine 在内存里做三方合并，避免对每条远端记录都各查一次库。
    func allSyncSnapshots() throws -> [String: EntrySyncSnapshot] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, contentHash, deleted FROM entry")
            var dict: [String: EntrySyncSnapshot] = [:]
            dict.reserveCapacity(rows.count)
            for row in rows {
                dict[row["id"]] = EntrySyncSnapshot(contentHash: row["contentHash"], deleted: row["deleted"])
            }
            return dict
        }
    }

    /// 一次性把 sync_baseline 全部读成 [entryId: hash]，供内存比对。
    func allBaselineHashes() throws -> [String: String] {
        try writer.read { db in
            var dict: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT entryId, hash FROM sync_baseline")
            for row in rows {
                dict[row["entryId"]] = row["hash"]
            }
            return dict
        }
    }

    func restore(id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE entry SET deleted = 0, dirty = 1, updatedAt = ? WHERE id = ?", arguments: [Date(), id.uuidString])
            try Self.refreshSyncHash(id: id, db: db)
        }
    }

    func permanentlyDelete(id: UUID) throws {
        try writer.write { db in
            // D11：彻底删除前先落一条独立于 entry 生命周期的墓碑。
            // 否则条目行消失后 dirtyEntries 不再包含它，删除意图无法推送到远端，
            // 下一轮同步会被远端索引原样拉回（复活）。
            if let entry = try Entry.fetchOne(db, key: id.uuidString) {
                // UI-04：记录该条目引用的媒体 sha，供保留期到期后判定远端媒体是否可清。
                let shas = try String.fetchAll(db, sql: "SELECT sha256 FROM media_asset WHERE entryId = ?", arguments: [id.uuidString])
                let tombstone = ManifestEntry(
                    id: entry.id,
                    boardId: entry.boardId,
                    dayDate: entry.dayDate,
                    path: SyncPaths.entryPath(entry),
                    updatedAt: entry.updatedAt,
                    hash: entry.contentHash,
                    deleted: true,
                    mediaShas: shas.isEmpty ? nil : shas,
                    deletedAt: Date()
                )
                let payload = try JSONEncoder.wuyan.encode(tombstone)
                try db.execute(
                    sql: "INSERT INTO sync_tombstone(entryId, payload, createdAt) VALUES (?, ?, ?) ON CONFLICT(entryId) DO UPDATE SET payload = excluded.payload, createdAt = excluded.createdAt",
                    arguments: [id.uuidString, String(data: payload, encoding: .utf8), Date()]
                )
            }
            _ = try Entry.deleteOne(db, key: id.uuidString)
        }
    }

    /// 归档后的本地清理只移除本地副本，不代表向其它设备传播删除。
    /// 与 permanentlyDelete 分开，避免归档把远端条目标记为 deleted。
    func removeArchivedLocal(id: UUID) throws {
        try writer.write { db in
            _ = try Entry.deleteOne(db, key: id.uuidString)
        }
    }

    // MARK: - D11：同步墓碑（独立于 entry 行的生命周期）

    /// 待推送的删除墓碑（按写入顺序）。
    func pendingTombstones() throws -> [ManifestEntry] {
        try writer.read { db in
            let payloads = try String.fetchAll(db, sql: "SELECT payload FROM sync_tombstone ORDER BY createdAt ASC")
            return payloads.compactMap { payload in
                guard let data = payload.data(using: .utf8) else { return nil }
                return try? JSONDecoder.wuyan.decode(ManifestEntry.self, from: data)
            }
        }
    }

    func hasTombstone(id: UUID) throws -> Bool {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_tombstone WHERE entryId = ?", arguments: [id.uuidString]) ?? 0 > 0
        }
    }

    /// 墓碑已传播到远端索引（remote.deleted=true）后调用；传播使命完成。
    func dropTombstone(id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM sync_tombstone WHERE entryId = ?", arguments: [id.uuidString])
        }
    }

    /// 超过保留期的墓碑一并丢弃，与 manifest 的墓碑裁剪保持同一水位线。
    func pruneTombstones(olderThan cutoff: Date) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM sync_tombstone WHERE createdAt < ?", arguments: [cutoff])
        }
    }

    // MARK: - UI-06：本地冲突副本（与远端 conflicts 目录同源的本地留档）

    /// 保存冲突副本（本地被替代版本的完整 envelope）。
    func saveConflictCopy(entry: Entry, envelope: Data, remotePath: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO conflict_copy(entryId, payload, remotePath, createdAt) VALUES (?, ?, ?, ?) ON CONFLICT(entryId) DO UPDATE SET payload = excluded.payload, remotePath = excluded.remotePath, createdAt = excluded.createdAt",
                arguments: [entry.id.uuidString, String(data: envelope, encoding: .utf8), remotePath, Date()]
            )
        }
    }

    /// 全部待处理的冲突副本（按时间升序）。
    func conflictCopies() throws -> [(entryId: UUID, envelope: EntryEnvelope, createdAt: Date)] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT entryId, payload, createdAt FROM conflict_copy ORDER BY createdAt ASC")
            return rows.compactMap { row in
                guard let idString: String = row["entryId"],
                      let id = UUID(uuidString: idString),
                      let payloadString: String = row["payload"],
                      let data = payloadString.data(using: .utf8),
                      let envelope = try? JSONDecoder.wuyan.decode(EntryEnvelope.self, from: data),
                      let createdAt: Date = row["createdAt"]
                else { return nil }
                return (entryId: id, envelope: envelope, createdAt: createdAt)
            }
        }
    }

    func hasConflictCopy(id: UUID) throws -> Bool {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conflict_copy WHERE entryId = ?", arguments: [id.uuidString]) ?? 0 > 0
        }
    }

    /// 冲突已处理（选择任一版本/都保留）后移除副本。
    func dropConflictCopy(id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM conflict_copy WHERE entryId = ?", arguments: [id.uuidString])
        }
    }

    /// D06：直接 SQL 更新（软删/恢复）后重算同步指纹，
    /// 保证 contentHash 覆盖 deleted 等全部同步语义字段，供条件确认与三方合并使用。
    private static func refreshSyncHash(id: UUID, db: Database) throws {
        guard let entry = try Entry.fetchOne(db, key: id.uuidString) else { return }
        let hash = Entry.hash(
            title: entry.title,
            body: entry.body,
            bodyRTF: entry.bodyRTF,
            tags: entry.tags,
            mood: entry.mood,
            weather: entry.weather,
            location: entry.location,
            mediaIds: entry.mediaIds,
            boardId: entry.boardId,
            dayDate: entry.dayDate,
            journalDate: entry.journalDate,
            isFavorite: entry.isFavorite,
            isDraft: entry.isDraft,
            deleted: entry.deleted
        )
        guard hash != entry.contentHash else { return }
        try db.execute(sql: "UPDATE entry SET contentHash = ? WHERE id = ?", arguments: [hash, id.uuidString])
    }

    func trashedEntries() throws -> [Entry] {
        try writer.read { db in
            try Entry
                .filter(Entry.Columns.deleted == true)
                .order(Entry.Columns.updatedAt.desc)
                .fetchAll(db)
        }
    }

    public func create(boardId: UUID, dayNote: DayNote, journalDate: Date = Date()) throws -> Entry {
        let entry = Entry(boardId: boardId, dayDate: dayNote.date, journalDate: journalDate)
        try save(entry)
        return try self.entry(id: entry.id) ?? entry
    }

    public func softDelete(id: UUID) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE entry SET deleted = 1, dirty = 1, updatedAt = ? WHERE id = ?",
                arguments: [Date(), id.uuidString]
            )
            try Self.refreshSyncHash(id: id, db: db)
        }
    }

    private func fetchTimeline(db: Database, filter: TimelineFilter) throws -> [Entry] {
        var request = Entry
            .filter(Entry.Columns.deleted == false)
            .order(Entry.Columns.journalDate.desc, Entry.Columns.updatedAt.desc)

        switch filter {
        case .all:
            break
        case .favorites:
            request = request.filter(Entry.Columns.isFavorite == true)
        case .drafts:
            request = request.filter(Entry.Columns.isDraft == true)
        case .todayInHistory:
            let today = DayKey.today
            request = request.filter(sql: "substr(dayDate, 6, 5) = ? AND substr(dayDate, 1, 4) != ?", arguments: [String(today.dropFirst(5)), String(today.prefix(4))])
        case let .board(id):
            request = request.filter(Entry.Columns.boardId == id.uuidString)
        case let .year(year):
            request = request.filter(sql: "substr(dayDate, 1, 4) = ?", arguments: [String(year)])
        case let .yearBoard(year, id):
            request = request
                .filter(Entry.Columns.boardId == id.uuidString)
                .filter(sql: "substr(dayDate, 1, 4) = ?", arguments: [String(year)])
        case let .day(day):
            request = request.filter(Entry.Columns.dayDate == day)
        }

        return try request.fetchAll(db)
    }

    func search(_ query: EntrySearchQuery) throws -> [EntrySearchResult] {
        // D15：trigram 分词器天然无法匹配少于 3 个 Unicode 字符的查询（SQLite FTS5
        // 已说明的限制），1～2 字中文查询改走转义后的 LIKE 备选检索；
        // ≥3 字仍用 FTS5 MATCH（用户输入按短语转义，避免 AND/OR/*/: 被当语法）。
        let rawTerm = query.term
        let useFallback = rawTerm.count < 3

        return try writer.read { db in
            var arguments = StatementArguments()
            var sql: String
            if useFallback {
                let escaped = rawTerm
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                let pattern = "%\(escaped)%"
                sql = """
                    SELECT entry.* FROM entry
                    WHERE entry.deleted = 0
                      AND (entry.title LIKE ? ESCAPE '\\' OR entry.body LIKE ? ESCAPE '\\' OR entry.tags LIKE ? ESCAPE '\\')
                    """
                arguments += [pattern, pattern, pattern]
            } else {
                let phrase = "\"" + rawTerm.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                arguments += [phrase]
                sql = """
                    SELECT entry.*, snippet(entry_fts, 0, '<mark>', '</mark>', '…', 12) AS titleSnippet,
                           snippet(entry_fts, 1, '<mark>', '</mark>', '…', 18) AS bodySnippet
                    FROM entry_fts
                    JOIN entry ON entry_fts.rowid = entry.rowid
                    WHERE entry_fts MATCH ? AND entry.deleted = 0
                    """
            }
            if let boardId = query.boardId {
                sql += " AND entry.boardId = ?"
                arguments += [boardId.uuidString]
            }
            if let mood = query.mood {
                sql += " AND entry.mood = ?"
                arguments += [mood]
            }
            if let tag = query.tag, !tag.isEmpty {
                sql += " AND entry.tags LIKE ?"
                let escaped = tag.replacingOccurrences(of: "\"", with: "\\\"")
                arguments += ["%\"\(escaped)\"%"]
            }
            if let start = query.startDate {
                sql += " AND entry.journalDate >= ?"
                arguments += [start]
            }
            if let end = query.endDate {
                sql += " AND entry.journalDate <= ?"
                arguments += [end]
            }
            sql += useFallback ? " ORDER BY entry.journalDate DESC" : " ORDER BY rank"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                let entry = try Entry(row: row)
                if useFallback {
                    return EntrySearchResult(
                        entry: entry,
                        titleSnippet: Self.fallbackSnippet(entry.title, term: rawTerm),
                        bodySnippet: Self.fallbackSnippet(entry.body, term: rawTerm)
                    )
                }
                // D15：标题允许 NULL，snippet(...) 相应为 NULL；必须按可空读取，
                // 否则 GRDB 解码非可选 String 直接 fatal error（进程 signal 5），
                // 外层 try? 捕捉不到。
                return EntrySearchResult(
                    entry: entry,
                    titleSnippet: row["titleSnippet"] ?? "",
                    bodySnippet: row["bodySnippet"] ?? ""
                )
            }
        }
    }

    /// D15：LIKE 备选检索没有 FTS snippet 可用，手工生成与 FTS snippet 兼容的高亮片段。
    private static func fallbackSnippet(_ text: String?, term: String, window: Int = 18) -> String {
        guard let text, !text.isEmpty else { return "" }
        guard let range = text.range(of: term, options: .caseInsensitive) else {
            return String(text.prefix(window))
        }
        let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let matchEnd = text.distance(from: text.startIndex, to: range.upperBound)
        let lower = max(0, matchStart - window / 2)
        let upper = min(text.count, matchEnd + window / 2)
        func slice(_ start: Int, _ end: Int) -> String {
            String(text[text.index(text.startIndex, offsetBy: start)..<text.index(text.startIndex, offsetBy: end)])
        }
        return (lower > 0 ? "…" : "")
            + slice(lower, matchStart)
            + "<mark>" + slice(matchStart, matchEnd) + "</mark>"
            + slice(matchEnd, upper)
            + (upper < text.count ? "…" : "")
    }
}

/// 条目的同步快照：只含三方合并需要比对的字段，不带正文/富文本，避免全量读库时把正文也拖进内存。
struct EntrySyncSnapshot: Equatable, Sendable {
    let contentHash: String
    let deleted: Bool
}

struct EntrySummary: Identifiable, Equatable, FetchableRecord, Sendable {
    var id: UUID
    var dayDate: String
    var journalDate: Date
    var title: String?
    var bodyPreview: String
    var bodyLength: Int
    var isFavorite: Bool
    var boardId: UUID
    var tags: [String]
    var isDraft: Bool

    init(id: UUID, dayDate: String, journalDate: Date, title: String?, bodyPreview: String, bodyLength: Int, isFavorite: Bool = false, boardId: UUID = UUID(), tags: [String] = [], isDraft: Bool = false) {
        self.id = id
        self.dayDate = dayDate
        self.journalDate = journalDate
        self.title = title
        self.bodyPreview = bodyPreview
        self.bodyLength = bodyLength
        self.isFavorite = isFavorite
        self.boardId = boardId
        self.tags = tags
        self.isDraft = isDraft
    }

    init(row: Row) throws {
        id = UUID(uuidString: row["id"]) ?? UUID()
        dayDate = row["dayDate"]
        journalDate = row["journalDate"]
        title = row["title"]
        bodyPreview = row["bodyPreview"]
        bodyLength = row["bodyLength"]
        // isFavorite/boardId/tags/isDraft 可能不在某些查询中（如旧版 timelineSummaries）
        if row.hasColumn("isFavorite") {
            let fav: Int = row["isFavorite"]
            isFavorite = fav == 1
        } else {
            isFavorite = false
        }
        if row.hasColumn("boardId") {
            let str: String = row["boardId"]
            boardId = UUID(uuidString: str) ?? UUID()
        } else {
            boardId = UUID()
        }
        if row.hasColumn("tags") {
            let tagsStr: String = row["tags"]
            let data = tagsStr.data(using: .utf8) ?? Data()
            tags = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            tags = []
        }
        if row.hasColumn("isDraft") {
            let draft: Int = row["isDraft"]
            isDraft = draft == 1
        } else {
            isDraft = false
        }
    }
}

struct EntrySearchQuery {
    var term: String
    var boardId: UUID?
    var tag: String?
    var mood: Int?
    var startDate: Date?
    var endDate: Date?
}

struct EntrySearchResult: Identifiable {
    var id: UUID { entry.id }
    var entry: Entry
    var titleSnippet: String
    var bodySnippet: String
}
