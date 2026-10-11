import Foundation
import GRDB

public struct DayNote: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "daynote"

    public var id: String { date }
    public var date: String
    public var rawSummary: String
    public var poeticLine: String
    public var generatedBy: String?
    /// 日级心情是当天所有板块共用的权威值。nil 表示用户尚未记录。
    public var mood: Int?
    /// 用户明确清除当日心情时保留的标记，用于压过旧条目的兼容投影。
    public var moodCleared: Bool
    public var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case date, rawSummary, poeticLine, generatedBy, mood, moodCleared, createdAt
    }

    public init(
        date: String = DayKey.today,
        rawSummary: String,
        poeticLine: String,
        generatedBy: String? = nil,
        mood: Int? = nil,
        moodCleared: Bool = false,
        createdAt: Date = Date()
    ) {
        self.date = date
        self.rawSummary = rawSummary
        self.poeticLine = poeticLine
        self.generatedBy = generatedBy
        self.mood = mood
        self.moodCleared = moodCleared
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        rawSummary = try container.decodeIfPresent(String.self, forKey: .rawSummary) ?? ""
        poeticLine = try container.decodeIfPresent(String.self, forKey: .poeticLine) ?? rawSummary
        generatedBy = try container.decodeIfPresent(String.self, forKey: .generatedBy)
        mood = try container.decodeIfPresent(Int.self, forKey: .mood)
        moodCleared = try container.decodeIfPresent(Bool.self, forKey: .moodCleared) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date.distantPast
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(rawSummary, forKey: .rawSummary)
        try container.encode(poeticLine, forKey: .poeticLine)
        try container.encodeIfPresent(generatedBy, forKey: .generatedBy)
        try container.encodeIfPresent(mood, forKey: .mood)
        if moodCleared { try container.encode(true, forKey: .moodCleared) }
        try container.encode(createdAt, forKey: .createdAt)
    }
}
