import Foundation
import GRDB

struct DayNoteConflictCopy: Identifiable, Equatable {
    let id: UUID
    let note: DayNote
    let createdAt: Date
}

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

    /// Conditional remote replacement. `expectedHash == nil` means the date
    /// must not exist yet; an existing or concurrently edited note is rejected.
    func upsert(_ note: DayNote, expectedHash: String?) throws {
        try writer.write { db in
            let current = try DayNote.fetchOne(db, key: note.date)
            if let expectedHash {
                guard let current, Hashing.dayNoteHash(current) == expectedHash else {
                    throw EntrySaveError.concurrentModification(UUID())
                }
            } else if current != nil {
                throw EntrySaveError.concurrentModification(UUID())
            }
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

    /// Preserve the losing side when two devices edit the same day note.
    /// The payload is a JSON encoded DayNote so it can be recovered without
    /// changing the synchronization protocol.
    func saveConflictCopy(_ note: DayNote) throws {
        let payload = try JSONEncoder.wuyan.encode(note)
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO daynote_conflict(id, date, payload, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [UUID().uuidString, note.date, String(data: payload, encoding: .utf8) ?? "{}", Date()]
            )
        }
    }

    func conflictCopies(date: String? = nil) throws -> [DayNote] {
        try writer.read { db in
            let rows: [String]
            if let date {
                rows = try String.fetchAll(db, sql: "SELECT payload FROM daynote_conflict WHERE date = ? ORDER BY createdAt DESC", arguments: [date])
            } else {
                rows = try String.fetchAll(db, sql: "SELECT payload FROM daynote_conflict ORDER BY createdAt DESC")
            }
            return rows.compactMap { payload in
                guard let data = payload.data(using: .utf8) else { return nil }
                return try? JSONDecoder.wuyan.decode(DayNote.self, from: data)
            }
        }
    }

    func conflictCopyRecords() throws -> [DayNoteConflictCopy] {
        try writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, payload, createdAt FROM daynote_conflict ORDER BY createdAt DESC"
            )
            return rows.compactMap { row in
                guard let idString: String = row["id"],
                      let id = UUID(uuidString: idString),
                      let payload: String = row["payload"],
                      let data = payload.data(using: .utf8),
                      let note = try? JSONDecoder.wuyan.decode(DayNote.self, from: data),
                      let createdAt: Date = row["createdAt"]
                else { return nil }
                return DayNoteConflictCopy(id: id, note: note, createdAt: createdAt)
            }
        }
    }

    func dropConflictCopy(id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM daynote_conflict WHERE id = ?", arguments: [id.uuidString])
        }
    }
}
