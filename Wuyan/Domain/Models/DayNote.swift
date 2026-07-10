import Foundation
import GRDB

public struct DayNote: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "daynote"

    public var id: String { date }
    public var date: String
    public var rawSummary: String
    public var poeticLine: String
    public var generatedBy: String?
    public var createdAt: Date

    public init(
        date: String = DayKey.today,
        rawSummary: String,
        poeticLine: String,
        generatedBy: String? = nil,
        createdAt: Date = Date()
    ) {
        self.date = date
        self.rawSummary = rawSummary
        self.poeticLine = poeticLine
        self.generatedBy = generatedBy
        self.createdAt = createdAt
    }
}
