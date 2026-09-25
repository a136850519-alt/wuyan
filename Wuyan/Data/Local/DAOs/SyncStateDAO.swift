import Foundation
import GRDB

/// A01：同步状态（目前只有 manifest 水位线）的持久化。
/// 必须存在数据库而非 UserDefaults：水位线描述的是「这个数据库已同步到哪个版本」，
/// 与 baseline/条目数据同生共死。空库/恢复的旧库没有（或有自己旧的）水位线，
/// 同步引擎据此决定是否完整拉取，绝不能沿用另一份数据的水位线。
struct SyncStateDAO {
    let writer: DatabaseWriter

    func value(forKey key: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [key])
        }
    }

    func set(_ value: String?, forKey key: String) throws {
        try writer.write { db in
            if let value {
                try db.execute(
                    sql: """
                    INSERT INTO sync_state(key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [key, value]
                )
            } else {
                try db.execute(sql: "DELETE FROM sync_state WHERE key = ?", arguments: [key])
            }
        }
    }

    // MARK: - B01：孤儿版本登记（延迟 GC）

    /// 首次发现「不再被最新索引引用」的版本对象路径（幂等登记，保留最早时间）。
    func recordOrphans(paths: [String], backend: String, now: Date) throws {
        guard !paths.isEmpty else { return }
        try writer.write { db in
            for path in paths {
                try db.execute(
                    sql: """
                    INSERT INTO sync_orphan(backend, path, firstSeenAt) VALUES (?, ?, ?)
                    ON CONFLICT(backend, path) DO NOTHING
                    """,
                    arguments: [backend, path, now]
                )
            }
        }
    }

    /// 已超过宽限期的孤儿路径。
    func dueOrphans(backend: String, before cutoff: Date) throws -> [String] {
        try writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT path FROM sync_orphan WHERE backend = ? AND firstSeenAt <= ?",
                arguments: [backend, cutoff]
            )
        }
    }

    /// 孤儿已删除（或确认仍被引用需继续观察）后移除登记。
    /// 仍被引用的路径调用 dropOrphanPaths 一并出表，下次被取代时重新计时。
    func dropOrphanPaths(_ paths: [String], backend: String) throws {
        guard !paths.isEmpty else { return }
        try writer.write { db in
            for path in paths {
                try db.execute(
                    sql: "DELETE FROM sync_orphan WHERE backend = ? AND path = ?",
                    arguments: [backend, path]
                )
            }
        }
    }
}
