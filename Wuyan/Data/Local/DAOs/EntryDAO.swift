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
                SELECT id, dayDate, journalDate, title, substr(body, 1, 160) AS bodyPreview, length(body) AS bodyLength
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

    /// 轻量观察：只返回 EntrySummary（不含 body/bodyRTF），用于时间线
    func observeTimelineSummaries(filter: TimelineFilter) -> AsyncStream<[EntrySummary]> {
        let observation = ValueObservation.tracking { db in
            var sql = """
                SELECT id, dayDate, journalDate, title, substr(body, 1, 160) AS bodyPreview, length(body) AS bodyLength,
                       isFavorite, boardId, tags
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

    /// 取最近 N 条摘要（不读 bodyRTF），供 AI 等不需要完整内容的场景
    func recentSummaries(limit: Int = 30) throws -> [EntrySummary] {
        try writer.read { db in
            let sql = """
                SELECT id, dayDate, journalDate, title, substr(body, 1, 160) AS bodyPreview, length(body) AS bodyLength
                FROM entry
                WHERE deleted = 0
                ORDER BY journalDate DESC
                LIMIT ?
                """
            return try EntrySummary.fetchAll(db, sql: sql, arguments: [limit])
        }
    }

    public func entry(id: UUID) throws -> Entry? {
        try writer.read { db in
            try Entry.fetchOne(db, key: id.uuidString)
        }
    }

    public func save(_ entry: Entry) throws {
        var entry = entry
        entry.refreshForSave()
        try writer.write { db in
            try entry.save(db)
        }
    }

    func saveRemote(_ entry: Entry) throws {
        var entry = entry
        entry.dirty = false
        try writer.write { db in
            try entry.save(db)
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
    func markClean(id: UUID, expectedHash: String) throws {
        try writer.write { db in
            // 条件更新：hash 匹配才清 dirty
            try db.execute(
                sql: "UPDATE entry SET dirty = 0 WHERE id = ? AND contentHash = ?",
                arguments: [id.uuidString, expectedHash]
            )
            // baseline 始终写入（代表推送版本的水位线，不依赖 hash 条件）
            if let entry = try Entry.fetchOne(db, key: id.uuidString) {
                try db.execute(
                    sql: """
                    INSERT INTO sync_baseline(entryId, hash, updatedAt)
                    VALUES (?, ?, ?)
                    ON CONFLICT(entryId) DO UPDATE SET hash = excluded.hash, updatedAt = excluded.updatedAt
                    """,
                    arguments: [id.uuidString, entry.contentHash, entry.updatedAt]
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
        }
    }

    func permanentlyDelete(id: UUID) throws {
        try writer.write { db in
            _ = try Entry.deleteOne(db, key: id.uuidString)
        }
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
        try writer.read { db in
            // 把用户输入当作 FTS5 短语处理：转义内部引号并整体加引号，
            // 避免 AND/OR/*/: 等被当成查询语法导致报错。
            let phrase = "\"" + query.term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            var arguments: StatementArguments = [phrase]
            var sql = """
                SELECT entry.*, snippet(entry_fts, 0, '<mark>', '</mark>', '…', 12) AS titleSnippet,
                       snippet(entry_fts, 1, '<mark>', '</mark>', '…', 18) AS bodySnippet
                FROM entry_fts
                JOIN entry ON entry_fts.rowid = entry.rowid
                WHERE entry_fts MATCH ? AND entry.deleted = 0
                """
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
            sql += " ORDER BY rank"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                EntrySearchResult(
                    entry: try Entry(row: row),
                    titleSnippet: row["titleSnippet"],
                    bodySnippet: row["bodySnippet"]
                )
            }
        }
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

    init(row: Row) throws {
        id = UUID(uuidString: row["id"]) ?? UUID()
        dayDate = row["dayDate"]
        journalDate = row["journalDate"]
        title = row["title"]
        bodyPreview = row["bodyPreview"]
        bodyLength = row["bodyLength"]
        // isFavorite/boardId/tags 可能不在某些查询中（如旧版 timelineSummaries）
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
