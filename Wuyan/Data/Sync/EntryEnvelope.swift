import Foundation

struct EntryEnvelope: Codable {
    var entry: Entry
    var board: Board?
    var dayNote: DayNote?
    // D02：附件元数据。entry.mediaIds 只是 UUID 引用，没有文件名/类型/哈希/大小，
    // 另一台设备同步后无法重建 media_asset 行，归档下载也无法定位附件。
    // 设备私有路径（localPath/thumbnailPath）不参与传输，推送前置 nil；
    // 文件本体按 sha256 内容寻址存放，接收端可按需下载。
    var mediaAssets: [MediaAsset]?
    var schemaVersion: Int = 3
}

enum SyncPaths {
    static let root = "/Wuyan/"
    static let manifest = "/Wuyan/manifest.json"

    /// A03：条目对象使用「内容版本化」的不可变路径。并发提交各自写入自己的版本
    /// 对象，索引（manifest）最终选择哪个版本，读取端就能取到哪个版本的正文，
    /// 杜绝「旧正文覆盖新版本对象、索引与正文不一致」的竞态。
    /// C01：路径同时包含 updatedAt（毫秒）——每次保存都会刷新该时间戳，因此
    /// 「恢复旧内容」必然产生一个从未用过的新路径，被取代的版本对象不会被任何
    /// 后续写入复用，延迟 GC 在「复核最新索引→删除」之间不再可能删掉重新被
    /// 引用的正文（身份不复用协议）。旧版（无哈希/无时间戳后缀）路径仍可作为
    /// manifest 中记录的历史路径被读取。
    static func entryPath(_ entry: Entry) -> String {
        let parts = entry.dayDate.split(separator: "-")
        let year = parts.indices.contains(0) ? String(parts[0]) : "unknown"
        let month = parts.indices.contains(1) ? String(parts[1]) : "unknown"
        let stamp = Int(entry.updatedAt.timeIntervalSince1970 * 1000)
        return "/Wuyan/entries/\(year)/\(month)/\(entry.id.uuidString)-\(entry.contentHash.prefix(8))-\(stamp).json"
    }

    /// B05：日札对象同样使用「内容版本化」的不可变路径（与条目一致）。
    /// 并发提交各自写入自己的版本对象，索引最终选择哪个版本就能取到哪个版本，
    /// 消除「索引选 B、日期固定路径上的字节已被 A 覆盖」的不一致。
    /// C01：推送一律走 `dayNotePath(_:pushedAt:)` —— 日札没有编辑时间戳字段
    /// （createdAt 不随编辑刷新），必须由推送时刻提供不复用的身份令牌。
    /// 旧版（无哈希后缀）路径仍可作为 manifest 中记录的历史路径被读取。
    static func dayNotePath(_ note: DayNote) -> String {
        let parts = note.date.split(separator: "-")
        let year = parts.indices.contains(0) ? String(parts[0]) : "unknown"
        let month = parts.indices.contains(1) ? String(parts[1]) : "unknown"
        return "/Wuyan/daynotes/\(year)/\(month)/\(note.date)-\(Hashing.dayNoteHash(note).prefix(8)).json"
    }

    /// C01：推送用日札路径。`pushedAt` 由每次推送调用提供（同一次推送内共享同一
    /// 令牌）：即使内容恢复为历史版本，也会写到一个全新的路径，被 GC 登记的孤儿
    /// 路径永远不会被再次写入或被新索引引用。
    static func dayNotePath(_ note: DayNote, pushedAt: Date) -> String {
        let parts = note.date.split(separator: "-")
        let year = parts.indices.contains(0) ? String(parts[0]) : "unknown"
        let month = parts.indices.contains(1) ? String(parts[1]) : "unknown"
        let stamp = Int(pushedAt.timeIntervalSince1970 * 1000)
        return "/Wuyan/daynotes/\(year)/\(month)/\(note.date)-\(Hashing.dayNoteHash(note).prefix(8))-\(stamp).json"
    }

    static func deviceStatePath(deviceId: String) -> String {
        "/Wuyan/.sync/\(deviceId).state"
    }

    static func mediaPath(sha256: String, filename: String) -> String {
        let prefix = String(sha256.prefix(2))
        let ext = URL(fileURLWithPath: filename).pathExtension
        let final = ext.isEmpty ? sha256 : "\(sha256).\(ext)"
        return "/Wuyan/media/\(prefix)/\(final)"
    }

    static func encryptedMediaPath(sha256: String, filename: String) -> String {
        mediaPath(sha256: sha256, filename: filename) + ".enc"
    }

    static func thumbnailPath(sha256: String) -> String {
        "/Wuyan/media/thumbnails/\(sha256).jpg"
    }
}
