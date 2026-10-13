import Foundation
import GRDB

public enum BoardKind: String, Codable, CaseIterable, Sendable {
    case fiveYear
    case freeform
    case growth

    // 内置板块的固定身份：用确定性 UUID，保证跨设备 / 跨重装始终是同一个 id。
    // 历史上 builtIn 吃掉了 init 的 id:UUID=UUID() 默认值，每次建库都生成新随机 id，
    // 一旦本地库被清空重建（开发期 eraseDatabaseOnSchemaChange 或重装），新 id 与
    // 同步回来的旧 id 对不上，pullRemoteEntry 便把旧板块当成「新的」再存一份 → 重复。
    // 这里固定下来，从根上消除身份断裂。
    var stableID: UUID {
        switch self {
        case .fiveYear: return UUID(uuidString: "BE04385D-9141-4356-BAF3-4ACA181CF7D5")!
        case .freeform: return UUID(uuidString: "A2022C34-8650-42AB-93D8-DC735D8C3F23")!
        case .growth:   return UUID(uuidString: "19CE2894-EF4E-46CA-A754-A1D5F3F8F7D1")!
        }
    }

    public var displayName: String {
        switch self {
        case .fiveYear:
            return "五年"
        case .freeform:
            return "日常唠叨"
        case .growth:
            return "宝贝成长记录"
        }
    }
}

public struct Board: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "board"

    public var id: UUID
    public var name: String
    public var colorHex: String
    public var iconName: String
    public var kind: BoardKind
    /// 用户对该板块想留下的内容主题。旧数据库和旧同步载荷可缺失。
    public var recordingTheme: String?
    public var babyBirthday: Date?
    public var disallowCloudAI: Bool
    public var sortOrder: Int
    public var createdAt: Date
    /// 板块自身的版本时间。用于跨设备合并重命名、排序和隐私策略变更。
    public var updatedAt: Date
    /// 非 nil 表示板块已删除，但保留为同步墓碑，避免跨设备复活。
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        iconName: String,
        kind: BoardKind = .freeform,
        recordingTheme: String? = nil,
        babyBirthday: Date? = nil,
        disallowCloudAI: Bool = false,
        sortOrder: Int,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.iconName = iconName
        self.kind = kind
        self.recordingTheme = recordingTheme
        self.babyBirthday = babyBirthday
        self.disallowCloudAI = disallowCloudAI
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colorHex, iconName, kind, recordingTheme, babyBirthday, disallowCloudAI,
             sortOrder, createdAt, updatedAt, deletedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        iconName = try c.decode(String.self, forKey: .iconName)
        kind = try c.decode(BoardKind.self, forKey: .kind)
        recordingTheme = try c.decodeIfPresent(String.self, forKey: .recordingTheme)
        babyBirthday = try c.decodeIfPresent(Date.self, forKey: .babyBirthday)
        disallowCloudAI = try c.decodeIfPresent(Bool.self, forKey: .disallowCloudAI) ?? false
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date.distantPast
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(colorHex, forKey: .colorHex)
        try c.encode(iconName, forKey: .iconName)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(recordingTheme, forKey: .recordingTheme)
        try c.encodeIfPresent(babyBirthday, forKey: .babyBirthday)
        try c.encode(disallowCloudAI, forKey: .disallowCloudAI)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }

    public static let builtIn: [Board] = [
        Board(id: BoardKind.fiveYear.stableID, name: "五年", colorHex: "#C98522", iconName: "calendar", kind: .fiveYear, sortOrder: 0),
        Board(id: BoardKind.freeform.stableID, name: "日常唠叨", colorHex: "#D85A30", iconName: "bubble.left.and.bubble.right", kind: .freeform, sortOrder: 1),
        Board(id: BoardKind.growth.stableID, name: "宝贝成长记录", colorHex: "#D66A91", iconName: "figure.and.child.holdinghands", kind: .growth, sortOrder: 2)
    ]

    public func ageText(on date: Date = Date()) -> String? {
        ageText(in: Int(DayKey.string(from: date).prefix(4)) ?? Calendar.current.component(.year, from: date))
    }

    public func ageText(in year: Int) -> String? {
        guard kind == .growth, let babyBirthday else { return nil }
        let birthYear = Calendar.current.component(.year, from: babyBirthday)
        return year < birthYear ? "未出生" : "\(year - birthYear) 岁"
    }
}
