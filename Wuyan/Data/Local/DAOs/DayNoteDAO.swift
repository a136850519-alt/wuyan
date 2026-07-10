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
}
