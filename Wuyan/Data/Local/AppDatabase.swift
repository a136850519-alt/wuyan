import Foundation
import GRDB

public final class AppDatabase {
    let writer: DatabaseWriter
    public let entryDAO: EntryDAO
    public let boardDAO: BoardDAO
    public let dayNoteDAO: DayNoteDAO
    let mediaAssetDAO: MediaAssetDAO

    init(writer: DatabaseWriter) throws {
        self.writer = writer
        self.entryDAO = EntryDAO(writer: writer)
        self.boardDAO = BoardDAO(writer: writer)
        self.dayNoteDAO = DayNoteDAO(writer: writer)
        self.mediaAssetDAO = MediaAssetDAO(writer: writer)
        try Self.migrator.migrate(writer)
        try boardDAO.ensureBuiltInBoards()
    }

    public static func makeDefault() throws -> AppDatabase {
        let supportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = supportURL.appendingPathComponent("Wuyan", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("Wuyan.sqlite")
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return try AppDatabase(writer: DatabaseQueue(path: databaseURL.path, configuration: configuration))
    }

    public static func makeInMemory() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return try AppDatabase(writer: DatabaseQueue(configuration: configuration))
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        migrator.registerMigration("v1") { db in
            try V1Migration.migrate(db)
        }
        migrator.registerMigration("v2-body-rtf") { db in
            try db.alter(table: "entry") { table in
                table.add(column: "bodyRTF", .blob)
            }
        }
        migrator.registerMigration("v3-sync-cache") { db in
            // 内容寻址媒体一旦上传就永久存在：缓存「已确认在远端」的路径，
            // 同步时直接命中、跳过逐个 PROPFIND 探测。
            try db.create(table: "sync_uploaded", ifNotExists: true) { table in
                table.column("path", .text).primaryKey()
            }
        }
        migrator.registerMigration("v4-dedup-boards") { db in
            // 自愈历史重复：内置板块曾用随机 UUID 重复创建。按 kind 去重——
            // 保留被条目引用最多的那个（并列取最早创建的），把引用了被删板块的条目
            // 重定向到保留者，再删除多余板块。先重定向再删除，规避 boardId 的 ON DELETE RESTRICT。
            for kind in ["fiveYear", "freeform", "growth"] {
                let ids = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM board WHERE kind = ? ORDER BY createdAt ASC",
                    arguments: [kind]
                )
                guard ids.count > 1 else { continue }
                var winner: String?
                var maxRefs = -1
                for id in ids {
                    let refs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE boardId = ?", arguments: [id]) ?? 0
                    if refs > maxRefs { maxRefs = refs; winner = id }
                }
                guard let winner else { continue }
                for id in ids where id != winner {
                    try db.execute(sql: "UPDATE entry SET boardId = ? WHERE boardId = ?", arguments: [winner, id])
                    try db.execute(sql: "DELETE FROM board WHERE id = ?", arguments: [id])
                }
            }
        }
        return migrator
    }
}
