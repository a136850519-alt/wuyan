import Foundation
import GRDB

public final class AppDatabase {
    let writer: DatabaseWriter
    public let entryDAO: EntryDAO
    public let boardDAO: BoardDAO
    public let dayNoteDAO: DayNoteDAO
    let mediaAssetDAO: MediaAssetDAO
    let syncStateDAO: SyncStateDAO

    init(writer: DatabaseWriter) throws {
        self.writer = writer
        self.entryDAO = EntryDAO(writer: writer)
        self.boardDAO = BoardDAO(writer: writer)
        self.dayNoteDAO = DayNoteDAO(writer: writer)
        self.mediaAssetDAO = MediaAssetDAO(writer: writer)
        self.syncStateDAO = SyncStateDAO(writer: writer)
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
            // 自愈历史重复：内置板块曾用随机 UUID 重复创建。D10：只有「kind 与内置
            // 显示名同时匹配」的板块才认定为需要去重的历史内置重复项——用户自建的
            // freeform/growth 等同 kind 自定义板块是合法数据，绝不能被合并删除。
            // 保留被条目引用最多的那个（并列取最早创建的），把引用了被删板块的条目
            // 重定向到保留者，再删除多余板块。先重定向再删除，规避 boardId 的 ON DELETE RESTRICT。
            for builtIn in Board.builtIn {
                let ids = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM board WHERE kind = ? AND name = ? ORDER BY createdAt ASC",
                    arguments: [builtIn.kind.rawValue, builtIn.name]
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
        migrator.registerMigration("v5-fts-trigram") { db in
            // 重建 FTS5 索引，改用 trigram 分词器以支持中文子串搜索
            try db.execute(sql: "DROP TABLE IF EXISTS entry_fts")
            try db.execute(sql: "DROP TRIGGER IF EXISTS entry_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS entry_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS entry_au")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE entry_fts USING fts5(
                  title, body, tags, content='entry', content_rowid='rowid',
                  tokenize='trigram'
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
            // 重建全文索引
            try db.execute(sql: "INSERT INTO entry_fts(entry_fts) VALUES('rebuild')")
        }
        migrator.registerMigration("v6-backend-upload-cache") { db in
            // D08：sync_uploaded 记录的是「哪个远端路径已确认上传」，必须按后端身份隔离。
            // 旧表没有 backend 维度，无法归属，也不可跨后端沿用（切到空后端会误判
            // 「已上传」而漏传媒体）。旧缓存直接废弃——升级后首轮同步会对每条媒体
            // 多做一次存在性探测，宁可慢一次也不能沿用不可信的缓存。
            try db.create(table: "sync_upload_cache") { table in
                table.column("backend", .text).notNull()
                table.column("path", .text).notNull()
                table.primaryKey(["backend", "path"])
            }
            try db.drop(table: "sync_uploaded")
        }
        migrator.registerMigration("v7-sync-tombstones") { db in
            // D11：墓碑独立于 entry 生命周期。彻底删除后条目行消失，若没有独立墓碑，
            // 待发删除意图一并丢失，远端旧对象会在下轮同步把条目拉回本地。
            // payload 是 JSON 编码的 ManifestEntry（deleted=true），包含重建索引项所需全部字段。
            try db.create(table: "sync_tombstone") { table in
                table.column("entryId", .text).primaryKey()
                table.column("payload", .text).notNull()
                table.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v8-media-uuid-normalize") { db in
            // D01 收尾：把历史误存为 16 字节 BLOB 的 media_asset.id / entryId 归一为
            // TEXT UUID 字符串；entryId 已无对应条目的孤儿行直接清理，
            // 避免迁移后的外键校验失败阻塞整个数据库打开。
            func uuidText(_ value: DatabaseValue) -> String? {
                if let text: String = String.fromDatabaseValue(value) { return text }
                guard let blob: Data = Data.fromDatabaseValue(value), blob.count == 16 else { return nil }
                let b = Array(blob)
                let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
                return uuid.uuidString
            }
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT rowid, id, entryId FROM media_asset WHERE typeof(id) = 'blob' OR typeof(entryId) = 'blob'"
            )
            for row in rows {
                let rowid: Int64 = row["rowid"]
                if let text = uuidText(row["id"]) {
                    // 同值主键已存在时跳过该行，避免迁移因主键冲突失败而阻塞升级。
                    let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_asset WHERE id = ?", arguments: [text]) ?? 0
                    if exists == 0 {
                        try db.execute(sql: "UPDATE media_asset SET id = ? WHERE rowid = ?", arguments: [text, rowid])
                    }
                }
                if let text = uuidText(row["entryId"]) {
                    try db.execute(sql: "UPDATE media_asset SET entryId = ? WHERE rowid = ?", arguments: [text, rowid])
                }
            }
            try db.execute(sql: "DELETE FROM media_asset WHERE entryId NOT IN (SELECT id FROM entry)")
        }
        migrator.registerMigration("v9-conflict-copies") { db in
            // UI-06：冲突副本同时落地本地。此前冲突副本只存远端 conflicts 目录，
            // 应用内无法查看与恢复；本地留档后可列出、对比、选择保留版本。
            // payload 为 JSON 编码的 EntryEnvelope（本地被替代版本的完整内容）。
            try db.create(table: "conflict_copy") { table in
                table.column("entryId", .text).primaryKey()
                table.column("payload", .text).notNull()
                table.column("remotePath", .text).notNull()
                table.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v10-board-tombstones") { db in
            // 板块删除必须进入同步清单，否则其它设备会把本地缺失板块重新建回。
            try db.alter(table: "board") { table in
                table.add(column: "deletedAt", .datetime)
            }
        }
        migrator.registerMigration("v11-board-versions") { db in
            // D16：板块属性也需要可合并的版本时间。历史行以 createdAt 作为初始版本。
            try db.alter(table: "board") { table in
                table.add(column: "updatedAt", .datetime)
            }
            try db.execute(sql: "UPDATE board SET updatedAt = createdAt WHERE updatedAt IS NULL")
        }
        migrator.registerMigration("v12-sync-state-and-daynote-baseline") { db in
            // A01：manifest 水位线原先存 UserDefaults，只绑定后端指纹，没有绑定数据库
            // 实例。换空库/恢复旧库后沿用旧水位线会跳过拉取，本地静默缺数据。
            // 水位线必须与它所描述的同步状态（baseline、条目）住在同一个库里：
            // 新库没有水位线 → 必然完整拉取；恢复旧库 → 水位线与旧 baseline 一致。
            try db.create(table: "sync_state", ifNotExists: true) { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }
            // A02：日札此前没有同步基线，拉取阶段只要哈希不同就无条件用远端覆盖，
            // 本地未同步的日札编辑会被未变化的远端旧版本冲掉。
            try db.create(table: "daynote_baseline", ifNotExists: true) { table in
                table.column("date", .text).primaryKey()
                table.column("hash", .text).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v13-orphan-registry") { db in
            // B01：版本化对象不再被即时删除。提交后被取代/落败的旧版本路径先登记
            // 在此表（按后端隔离），超过宽限期且确认未被最新索引引用后才由 GC 删除，
            // 避免「另一设备恢复旧内容后，本机延迟执行的清理删掉当前正文」。
            try db.create(table: "sync_orphan", ifNotExists: true) { table in
                table.column("backend", .text).notNull()
                table.column("path", .text).notNull()
                table.column("firstSeenAt", .datetime).notNull()
                table.primaryKey(["backend", "path"])
            }
        }
        migrator.registerMigration("v14-sync-purged") { db in
            // V3-15：永久保留已过期清除记录，防止离线设备把旧日记重新推回远端。
            try db.create(table: "sync_purged", ifNotExists: true) { table in
                table.column("entryId", .text).primaryKey()
                table.column("deletedAt", .datetime).notNull()
            }
        }
        return migrator
    }
}
