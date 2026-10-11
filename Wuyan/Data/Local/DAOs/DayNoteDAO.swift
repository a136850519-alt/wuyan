import Foundation
import GRDB

struct DayNoteConflictCopy: Identifiable, Equatable {
    let id: UUID
    let note: DayNote
    let createdAt: Date
}

struct DayMoodSnapshot: Equatable {
    var value: Int?
    var hasLegacyConflict: Bool
    var noteHash: String?
}

enum DayMoodSaveError: LocalizedError {
    case invalidValue
    case changedSinceEditing

    var errorDescription: String? {
        switch self {
        case .invalidValue: return "请选择有效的心情。"
        case .changedSinceEditing: return "当日信息已被更新，请取消后重新选择心情。"
        }
    }
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

    /// 更新当天共享心情；保留旧版日札正文和生成信息。
    func setMood(_ mood: Int?, dayKey: String, expectedNoteHash: String?) throws {
        try writer.write { db in
            if let mood, Mood(rawValue: mood) == nil { throw DayMoodSaveError.invalidValue }
            let current = try DayNote.fetchOne(db, key: dayKey)
            guard current.map(Hashing.dayNoteHash) == expectedNoteHash else {
                throw DayMoodSaveError.changedSinceEditing
            }
            if var note = current {
                note.mood = mood
                note.moodCleared = mood == nil
                try note.save(db)
            } else if let mood {
                try DayNote(date: dayKey, rawSummary: "", poeticLine: "", mood: mood).save(db)
            } else {
                try DayNote(date: dayKey, rawSummary: "", poeticLine: "", mood: nil, moodCleared: true).save(db)
            }
        }
    }

    /// 读取日级权威值；兼容旧库时只有一种有效条目心情才自动继承。
    func effectiveMood(dayKey: String) throws -> Int? {
        try moodSnapshot(dayKey: dayKey).value
    }

    func moodSnapshot(dayKey: String) throws -> DayMoodSnapshot {
        try writer.read { try Self.moodSnapshot(dayKey: dayKey, db: $0) }
    }

    private static func moodSnapshot(dayKey: String, db: Database) throws -> DayMoodSnapshot {
        let note = try DayNote.fetchOne(db, key: dayKey)
        if note?.moodCleared == true {
            return DayMoodSnapshot(value: nil, hasLegacyConflict: false, noteHash: note.map(Hashing.dayNoteHash))
        }
        if let mood = Mood.from(note?.mood) {
            return DayMoodSnapshot(value: mood.rawValue, hasLegacyConflict: false, noteHash: note.map(Hashing.dayNoteHash))
        }
        let moods = try Int.fetchAll(db, sql: "SELECT DISTINCT mood FROM entry WHERE dayDate = ? AND deleted = 0 AND mood BETWEEN 1 AND 5", arguments: [dayKey])
        return DayMoodSnapshot(value: moods.count == 1 ? moods.first : nil, hasLegacyConflict: moods.count > 1, noteHash: note.map(Hashing.dayNoteHash))
    }

    func observeMood(dayKey: String) -> AsyncStream<DayMoodSnapshot> {
        let observation = ValueObservation.tracking { db in
            try Self.moodSnapshot(dayKey: dayKey, db: db)
        }
        return AsyncStream { continuation in
            let cancellable = observation.start(in: writer, scheduling: .immediate, onError: { _ in
                continuation.finish()
            }, onChange: { continuation.yield($0) })
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    /// 与展示共用同样的规则，供旧条目心情筛选使用。
    static let effectiveMoodSQL = """
        COALESCE((SELECT mood FROM daynote WHERE date = entry.dayDate AND moodCleared = 0 AND mood BETWEEN 1 AND 5),
            (SELECT CASE WHEN COUNT(DISTINCT mood) = 1 THEN MIN(mood) END
             FROM entry AS moodEntry WHERE moodEntry.dayDate = entry.dayDate
             AND moodEntry.deleted = 0 AND moodEntry.mood BETWEEN 1 AND 5
             AND NOT EXISTS (SELECT 1 FROM daynote WHERE date = entry.dayDate AND moodCleared = 1)))
        """

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

    func restoreConflictCopy(_ copy: DayNoteConflictCopy) throws {
        try writer.write { db in
            if let current = try DayNote.fetchOne(db, key: copy.note.date), current != copy.note {
                let payload = try JSONEncoder.wuyan.encode(current)
                try db.execute(sql: "INSERT INTO daynote_conflict(id, date, payload, createdAt) VALUES (?, ?, ?, ?)",
                               arguments: [UUID().uuidString, current.date, String(decoding: payload, as: UTF8.self), Date()])
            }
            try copy.note.save(db)
            try db.execute(sql: "DELETE FROM daynote_conflict WHERE id = ?", arguments: [copy.id.uuidString])
        }
    }

    func dropConflictCopy(id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM daynote_conflict WHERE id = ?", arguments: [id.uuidString])
        }
    }
}
