import Foundation
import GRDB

enum V1Migration {
    static func migrate(_ db: Database) throws {
        try db.create(table: "board") { table in
            table.column("id", .text).primaryKey()
            table.column("name", .text).notNull()
            table.column("colorHex", .text).notNull()
            table.column("iconName", .text).notNull()
            table.column("kind", .text).notNull()
            table.column("babyBirthday", .datetime)
            table.column("disallowCloudAI", .boolean).notNull().defaults(to: false)
            table.column("sortOrder", .integer).notNull()
            table.column("createdAt", .datetime).notNull()
        }

        try db.create(table: "daynote") { table in
            table.column("date", .text).primaryKey()
            table.column("rawSummary", .text).notNull()
            table.column("poeticLine", .text).notNull()
            table.column("generatedBy", .text)
            table.column("createdAt", .datetime).notNull()
        }

        try db.create(table: "entry") { table in
            table.column("id", .text).primaryKey()
            table.column("boardId", .text).notNull().references("board", onDelete: .restrict)
            table.column("dayDate", .text).notNull()
            table.column("journalDate", .datetime).notNull()
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull()
            table.column("title", .text)
            table.column("body", .text).notNull()
            table.column("tags", .text).notNull()
            table.column("mood", .integer)
            table.column("weatherJson", .text)
            table.column("locationJson", .text)
            table.column("mediaIds", .text).notNull().defaults(to: "[]")
            table.column("isFavorite", .boolean).notNull().defaults(to: false)
            table.column("isDraft", .boolean).notNull().defaults(to: false)
            table.column("contentHash", .text).notNull()
            table.column("dirty", .boolean).notNull().defaults(to: true)
            table.column("deleted", .boolean).notNull().defaults(to: false)
        }
        try db.create(index: "idx_entry_journalDate", on: "entry", columns: ["journalDate"], options: [.ifNotExists])
        try db.create(index: "idx_entry_board", on: "entry", columns: ["boardId"], options: [.ifNotExists])
        try db.create(index: "idx_entry_day", on: "entry", columns: ["dayDate"], options: [.ifNotExists])
        try db.create(index: "idx_entry_dirty", on: "entry", columns: ["dirty"], options: [.ifNotExists])

        try db.create(table: "media_asset") { table in
            table.column("id", .text).primaryKey()
            table.column("entryId", .text).notNull().references("entry", onDelete: .cascade)
            table.column("type", .text).notNull()
            table.column("filename", .text).notNull()
            table.column("mime", .text).notNull()
            table.column("size", .integer).notNull()
            table.column("width", .integer)
            table.column("height", .integer)
            table.column("durationSec", .double)
            table.column("sha256", .text).notNull()
            table.column("thumbnailPath", .text)
            table.column("localPath", .text)
            table.column("capturedAt", .datetime)
            table.column("exifLat", .double)
            table.column("exifLon", .double)
        }

        try db.create(table: "sync_baseline") { table in
            table.column("entryId", .text).primaryKey()
            table.column("hash", .text).notNull()
            table.column("updatedAt", .datetime).notNull()
        }

        try db.execute(sql: """
            CREATE VIRTUAL TABLE entry_fts USING fts5(
              title, body, tags, content='entry', content_rowid='rowid'
            )
            """)
        try db.execute(sql: """
            CREATE TRIGGER entry_ai AFTER INSERT ON entry BEGIN
              INSERT INTO entry_fts(rowid, title, body, tags)
              VALUES (new.rowid, new.title, new.body, new.tags);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER entry_ad AFTER DELETE ON entry BEGIN
              INSERT INTO entry_fts(entry_fts, rowid, title, body, tags)
              VALUES('delete', old.rowid, old.title, old.body, old.tags);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER entry_au AFTER UPDATE ON entry BEGIN
              INSERT INTO entry_fts(entry_fts, rowid, title, body, tags)
              VALUES('delete', old.rowid, old.title, old.body, old.tags);
              INSERT INTO entry_fts(rowid, title, body, tags)
              VALUES (new.rowid, new.title, new.body, new.tags);
            END
            """)
    }
}
