import Foundation
import GRDB

public protocol DayNoteRepository {
    func note(on date: Date) throws -> DayNote?
    func note(dayKey: String) throws -> DayNote?
    func upsert(_ note: DayNote) throws
    func all() throws -> [DayNote]
}

public struct DayNoteDAO: DayNoteRepository {
    let writer: DatabaseWriter

    public func note(on date: Date) throws -> DayNote? {
        try note(dayKey: date.dayKey)
    }

    public func note(dayKey: String) throws -> DayNote? {
        try writer.read { db in
            try DayNote.fetchOne(db, key: dayKey)
        }
    }

    public func upsert(_ note: DayNote) throws {
        try writer.write { db in
            try note.save(db)
        }
    }

    public func all() throws -> [DayNote] {
        try writer.read { db in
            try DayNote
                .order(DayNote.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    func delete(dayKey: String) throws {
        try writer.write { db in
            _ = try DayNote.deleteOne(db, key: dayKey)
        }
    }

    // MARK: - A02：日札同步基线

    /// 一次性把全部日札基线读成 [date: hash]，供 SyncEngine 三方合并。
    func allBaselineHashes() throws -> [String: String] {
        try writer.read { db in
            var dict: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT date, hash FROM daynote_baseline")
            for row in rows {
                let date: String = row["date"]
                dict[date] = row["hash"]
            }
            return dict
        }
    }

    /// 记录「已与远端确认一致」的日札版本指纹。拉取落地与推送提交成功后各写一次。
    func setBaseline(date: String, hash: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO daynote_baseline(date, hash, updatedAt) VALUES (?, ?, ?)
                ON CONFLICT(date) DO UPDATE SET hash = excluded.hash, updatedAt = excluded.updatedAt
                """,
                arguments: [date, hash, Date()]
            )
        }
    }

    /// 批量记录基线（推送提交成功后按最终索引内容确认）。
    func setBaselines(_ items: [(date: String, hash: String)]) throws {
        guard !items.isEmpty else { return }
        try writer.write { db in
            for item in items {
                try db.execute(
                    sql: """
                    INSERT INTO daynote_baseline(date, hash, updatedAt) VALUES (?, ?, ?)
                    ON CONFLICT(date) DO UPDATE SET hash = excluded.hash, updatedAt = excluded.updatedAt
                    """,
                    arguments: [item.date, item.hash, Date()]
                )
            }
        }
    }
}
