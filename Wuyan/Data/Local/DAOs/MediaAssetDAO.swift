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

    /// 获取所有媒体资产元数据
    func allAssets() throws -> [MediaAsset] {
        try writer.read { db in
            try MediaAsset.fetchAll(db)
        }
    }

    /// 还有多少条目（媒体行）引用这个内容寻址的 sha256。用于判断本地文件是否可安全清理。
    func referenceCount(sha256: String) throws -> Int {
        try writer.read { db in
            try MediaAsset.filter(MediaAsset.Columns.sha256 == sha256).fetchCount(db)
        }
    }

    /// 本机已确认上传到远端的媒体路径集合（sync_upload_cache 表），按后端身份隔离。
    /// D08：命中即跳过 exists 探测；缓存绝不能跨后端/账号/数据集沿用，
    /// 否则切到空后端会误判「已上传」而漏传媒体。
    func uploadedPaths(backend: String) throws -> Set<String> {
        try writer.read { db in
            let rows = try String.fetchAll(
                db,
                sql: "SELECT path FROM sync_upload_cache WHERE backend = ?",
                arguments: [backend]
            )
            return Set(rows)
        }
    }

    /// 批量记录本次同步新上传的路径（限定后端身份）；INSERT OR IGNORE 保证幂等。
    func recordUploaded(paths: [String], backend: String) throws {
        guard !paths.isEmpty else { return }
        try writer.write { db in
            for path in paths {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO sync_upload_cache(backend, path) VALUES (?, ?)",
                    arguments: [backend, path]
                )
            }
        }
    }

    /// 迁移：将 localPath / thumbnailPath 从绝对路径转换为相对路径。
    /// converter 闭包接收绝对路径，返回转换后的相对路径；无法安全转换时返回 nil，
    /// 让数据库清空该本地副本引用，避免继续访问越界路径。
    func migratePathsToRelative(converter: (String) -> String?) throws {
        try writer.write { db in
            // 逐行读取并转换，只更新有值的行
            let rows = try Row.fetchAll(db, sql: "SELECT id, localPath, thumbnailPath FROM media_asset WHERE localPath IS NOT NULL OR thumbnailPath IS NOT NULL")
            for row in rows {
                let id: String = row["id"]
                var updates: [String] = []
                var args: [String] = []

                if let localPath: String = row["localPath"] {
                    let converted = converter(localPath)
                    if let converted, converted != localPath {
                        updates.append("localPath = ?")
                        args.append(converted)
                    } else if converted == nil {
                        updates.append("localPath = NULL")
                    }
                }
                if let thumbnailPath: String = row["thumbnailPath"] {
                    let converted = converter(thumbnailPath)
                    if let converted, converted != thumbnailPath {
                        updates.append("thumbnailPath = ?")
                        args.append(converted)
                    } else if converted == nil {
                        updates.append("thumbnailPath = NULL")
                    }
                }
                if !updates.isEmpty {
                    args.append(id)
                    try db.execute(sql: "UPDATE media_asset SET \(updates.joined(separator: ", ")) WHERE id = ?", arguments: StatementArguments(args))
                }
            }
        }
    }
}
