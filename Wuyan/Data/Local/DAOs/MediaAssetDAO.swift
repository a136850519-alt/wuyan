import Foundation
import GRDB

struct MediaAssetDAO {
    let writer: DatabaseWriter

    func assets(for entryId: UUID) throws -> [MediaAsset] {
        try writer.read { db in
            try MediaAsset
                .filter(MediaAsset.Columns.entryId == entryId.uuidString)
                .order(MediaAsset.Columns.capturedAt.desc)
                .fetchAll(db)
        }
    }

    func asset(id: UUID) throws -> MediaAsset? {
        try writer.read { db in
            try MediaAsset.fetchOne(db, key: id.uuidString)
        }
    }

    func save(_ asset: MediaAsset) throws {
        try writer.write { db in
            try asset.save(db)
        }
    }

    func clearLocalFiles(id: UUID) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE media_asset SET localPath = NULL, thumbnailPath = NULL WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    func allAssets(for ids: [UUID]) throws -> [MediaAsset] {
        guard !ids.isEmpty else { return [] }
        return try writer.read { db in
            try MediaAsset
                .filter(ids.map(\.uuidString).contains(MediaAsset.Columns.id))
                .fetchAll(db)
        }
    }

    /// 还有多少条目（媒体行）引用这个内容寻址的 sha256。用于判断本地文件是否可安全清理。
    func referenceCount(sha256: String) throws -> Int {
        try writer.read { db in
            try MediaAsset.filter(MediaAsset.Columns.sha256 == sha256).fetchCount(db)
        }
    }

    /// 本机已确认上传到远端的媒体路径集合（sync_uploaded 表）。命中即跳过 exists 探测。
    func uploadedPaths() throws -> Set<String> {
        try writer.read { db in
            let rows = try String.fetchAll(db, sql: "SELECT path FROM sync_uploaded")
            return Set(rows)
        }
    }

    /// 批量记录本次同步新上传的路径；INSERT OR IGNORE 保证幂等。
    func recordUploaded(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try writer.write { db in
            for path in paths {
                try db.execute(sql: "INSERT OR IGNORE INTO sync_uploaded(path) VALUES (?)", arguments: [path])
            }
        }
    }
}
