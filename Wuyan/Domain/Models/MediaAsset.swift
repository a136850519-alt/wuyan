import Foundation
import GRDB

public enum MediaType: String, Codable, Sendable {
    case photo
    case video
    case audio
}

public struct MediaAsset: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "media_asset"

    public var id: UUID
    public var entryId: UUID
    public var type: MediaType
    public var filename: String
    public var mime: String
    public var size: Int64
    public var width: Int?
    public var height: Int?
    public var durationSec: Double?
    public var sha256: String
    public var thumbnailPath: String?
    public var localPath: String?
    public var capturedAt: Date?
    public var exifLat: Double?
    public var exifLon: Double?

    // MARK: - R2-1: 绝对路径计算属性（收口 resolvePath 到模型层）

    /// 本地文件的绝对路径。nil 若 localPath 为空。
    public var absoluteLocalPath: String? {
        guard let localPath else { return nil }
        let resolved = LocalMediaStore.resolvePath(localPath)
        return resolved.isEmpty ? nil : resolved
    }

    /// 缩略图的绝对路径。nil 若 thumbnailPath 为空。
    public var absoluteThumbnailPath: String? {
        guard let thumbnailPath else { return nil }
        let resolved = LocalMediaStore.resolvePath(thumbnailPath)
        return resolved.isEmpty ? nil : resolved
    }

    public init(
        id: UUID = UUID(),
        entryId: UUID,
        type: MediaType,
        filename: String,
        mime: String,
        size: Int64,
        width: Int? = nil,
        height: Int? = nil,
        durationSec: Double? = nil,
        sha256: String,
        thumbnailPath: String? = nil,
        localPath: String? = nil,
        capturedAt: Date? = nil,
        exifLat: Double? = nil,
        exifLon: Double? = nil
    ) {
        self.id = id
        self.entryId = entryId
        self.type = type
        self.filename = filename
        self.mime = mime
        self.size = size
        self.width = width
        self.height = height
        self.durationSec = durationSec
        self.sha256 = sha256
        self.thumbnailPath = thumbnailPath
        self.localPath = localPath
        self.capturedAt = capturedAt
        self.exifLat = exifLat
        self.exifLon = exifLon
    }
}
