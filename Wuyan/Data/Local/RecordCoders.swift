import Foundation
import GRDB

enum RecordCoding {
    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder.wuyan.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: String?) -> T? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder.wuyan.decode(type, from: data)
    }

    static func decodeArray<T: Decodable>(_ type: [T].Type, from value: String?) -> [T] {
        guard let decoded: [T] = decode(type, from: value) else { return [] }
        return decoded
    }
}

extension Board {
    public enum Columns: String, ColumnExpression {
        case id, name, colorHex, iconName, kind, babyBirthday, disallowCloudAI, sortOrder, createdAt, updatedAt, deletedAt
    }

    public init(row: Row) throws {
        let idString: String? = row[Columns.id]
        let idValue: UUID? = row[Columns.id]
        id = idString.flatMap(UUID.init(uuidString:)) ?? idValue ?? UUID()
        name = row[Columns.name]
        colorHex = row[Columns.colorHex]
        iconName = row[Columns.iconName]
        kind = BoardKind(rawValue: row[Columns.kind]) ?? .freeform
        babyBirthday = row[Columns.babyBirthday]
        disallowCloudAI = row[Columns.disallowCloudAI]
        sortOrder = row[Columns.sortOrder]
        createdAt = row[Columns.createdAt]
        updatedAt = row[Columns.updatedAt]
        deletedAt = row[Columns.deletedAt]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id.uuidString
        container[Columns.name] = name
        container[Columns.colorHex] = colorHex
        container[Columns.iconName] = iconName
        container[Columns.kind] = kind.rawValue
        container[Columns.babyBirthday] = babyBirthday
        container[Columns.disallowCloudAI] = disallowCloudAI
        container[Columns.sortOrder] = sortOrder
        container[Columns.createdAt] = createdAt
        container[Columns.updatedAt] = updatedAt
        container[Columns.deletedAt] = deletedAt
    }
}

extension DayNote {
    public enum Columns: String, ColumnExpression {
        case date, rawSummary, poeticLine, generatedBy, createdAt
    }
}

extension Entry {
    public enum Columns: String, ColumnExpression {
        case id, boardId, dayDate, journalDate, createdAt, updatedAt, title, body, tags, mood
        case bodyRTF, weatherJson, locationJson, mediaIds, isFavorite, isDraft, contentHash, dirty, deleted
    }

    public init(row: Row) throws {
        id = UUID(uuidString: row[Columns.id]) ?? UUID()
        boardId = UUID(uuidString: row[Columns.boardId]) ?? UUID()
        dayDate = row[Columns.dayDate]
        journalDate = row[Columns.journalDate]
        createdAt = row[Columns.createdAt]
        updatedAt = row[Columns.updatedAt]
        title = row[Columns.title]
        body = row[Columns.body]
        bodyRTF = row[Columns.bodyRTF]
        tags = RecordCoding.decodeArray([String].self, from: row[Columns.tags])
        mood = row[Columns.mood]
        weather = RecordCoding.decode(Weather.self, from: row[Columns.weatherJson])
        location = RecordCoding.decode(GeoPlace.self, from: row[Columns.locationJson])
        let mediaStrings = RecordCoding.decodeArray([String].self, from: row[Columns.mediaIds])
        mediaIds = mediaStrings.compactMap(UUID.init(uuidString:))
        isFavorite = row[Columns.isFavorite]
        isDraft = row[Columns.isDraft]
        contentHash = row[Columns.contentHash]
        dirty = row[Columns.dirty]
        deleted = row[Columns.deleted]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id.uuidString
        container[Columns.boardId] = boardId.uuidString
        container[Columns.dayDate] = dayDate
        container[Columns.journalDate] = journalDate
        container[Columns.createdAt] = createdAt
        container[Columns.updatedAt] = updatedAt
        container[Columns.title] = title
        container[Columns.body] = body
        container[Columns.bodyRTF] = bodyRTF
        container[Columns.tags] = RecordCoding.encode(tags)
        container[Columns.mood] = mood
        container[Columns.weatherJson] = weather.map(RecordCoding.encode)
        container[Columns.locationJson] = location.map(RecordCoding.encode)
        container[Columns.mediaIds] = RecordCoding.encode(mediaIds.map(\.uuidString))
        container[Columns.isFavorite] = isFavorite
        container[Columns.isDraft] = isDraft
        container[Columns.contentHash] = contentHash
        container[Columns.dirty] = dirty
        container[Columns.deleted] = deleted
    }
}

extension MediaAsset {
    public enum Columns: String, ColumnExpression {
        case id, entryId, type, filename, mime, size, width, height, durationSec, sha256
        case thumbnailPath, localPath, capturedAt, exifLat, exifLon
    }

    /// D01：显式持久化编码。GRDB 默认 Codable 会把 UUID 编成 16 字节 BLOB，
    /// 而 entry.id / board.id 全部是 TEXT 字符串，media_asset.entryId 的外键因此
    /// 永远无法匹配（保存即抛 FOREIGN KEY constraint failed）。这里统一把
    /// id / entryId 写成 TEXT，与 Entry / Board 的编码方式保持一致。
    public init(row: Row) throws {
        id = UUID(uuidString: row[Columns.id]) ?? UUID()
        entryId = UUID(uuidString: row[Columns.entryId]) ?? UUID()
        type = MediaType(rawValue: row[Columns.type]) ?? .photo
        filename = row[Columns.filename]
        mime = row[Columns.mime]
        size = row[Columns.size]
        width = row[Columns.width]
        height = row[Columns.height]
        durationSec = row[Columns.durationSec]
        sha256 = row[Columns.sha256]
        thumbnailPath = row[Columns.thumbnailPath]
        localPath = row[Columns.localPath]
        capturedAt = row[Columns.capturedAt]
        exifLat = row[Columns.exifLat]
        exifLon = row[Columns.exifLon]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id.uuidString
        container[Columns.entryId] = entryId.uuidString
        container[Columns.type] = type.rawValue
        container[Columns.filename] = filename
        container[Columns.mime] = mime
        container[Columns.size] = size
        container[Columns.width] = width
        container[Columns.height] = height
        container[Columns.durationSec] = durationSec
        container[Columns.sha256] = sha256
        container[Columns.thumbnailPath] = thumbnailPath
        container[Columns.localPath] = localPath
        container[Columns.capturedAt] = capturedAt
        container[Columns.exifLat] = exifLat
        container[Columns.exifLon] = exifLon
    }
}
