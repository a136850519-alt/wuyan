import Foundation
import GRDB

public struct Entry: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "entry"

    public var id: UUID
    public var boardId: UUID
    public var dayDate: String
    public var journalDate: Date
    public var createdAt: Date
    public var updatedAt: Date
    public var title: String?
    public var body: String
    public var bodyRTF: Data?
    public var tags: [String]
    public var mood: Int?
    public var weather: Weather?
    public var location: GeoPlace?
    public var mediaIds: [UUID]
    public var isFavorite: Bool
    public var isDraft: Bool
    public var contentHash: String
    public var dirty: Bool
    public var deleted: Bool

    public init(
        id: UUID = UUID(),
        boardId: UUID,
        dayDate: String = DayKey.today,
        journalDate: Date = Date(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        title: String? = nil,
        body: String = "",
        bodyRTF: Data? = nil,
        tags: [String] = [],
        mood: Int? = nil,
        weather: Weather? = nil,
        location: GeoPlace? = nil,
        mediaIds: [UUID] = [],
        isFavorite: Bool = false,
        isDraft: Bool = true,
        contentHash: String = "",
        dirty: Bool = true,
        deleted: Bool = false
    ) {
        self.id = id
        self.boardId = boardId
        self.dayDate = dayDate
        self.journalDate = journalDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.body = body
        self.bodyRTF = bodyRTF
        self.tags = tags
        self.mood = mood
        self.weather = weather
        self.location = location
        self.mediaIds = mediaIds
        self.isFavorite = isFavorite
        self.isDraft = isDraft
        self.contentHash = contentHash.isEmpty ? Self.hash(
            title: title,
            body: body,
            bodyRTF: bodyRTF,
            tags: tags,
            mood: mood,
            weather: weather,
            location: location,
            mediaIds: mediaIds
        ) : contentHash
        self.dirty = dirty
        self.deleted = deleted
    }

    public static func hash(
        title: String?,
        body: String,
        bodyRTF: Data?,
        tags: [String],
        mood: Int?,
        weather: Weather?,
        location: GeoPlace?,
        mediaIds: [UUID]
    ) -> String {
        Hashing.entryContentHash(
            title: title,
            body: body,
            bodyRTF: bodyRTF,
            tags: tags,
            mood: mood,
            weather: weather,
            location: location,
            mediaIds: mediaIds
        )
    }

    public mutating func refreshForSave(now: Date = Date()) {
        updatedAt = now
        dirty = true
        isDraft = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
            body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        contentHash = Self.hash(
            title: title,
            body: body,
            bodyRTF: bodyRTF,
            tags: tags,
            mood: mood,
            weather: weather,
            location: location,
            mediaIds: mediaIds
        )
    }
}
