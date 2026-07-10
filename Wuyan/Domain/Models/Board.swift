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
    public var babyBirthday: Date?
    public var disallowCloudAI: Bool
    public var sortOrder: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        iconName: String,
        kind: BoardKind = .freeform,
        babyBirthday: Date? = nil,
        disallowCloudAI: Bool = false,
        sortOrder: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.iconName = iconName
        self.kind = kind
        self.babyBirthday = babyBirthday
        self.disallowCloudAI = disallowCloudAI
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    public static let builtIn: [Board] = [
        Board(id: BoardKind.fiveYear.stableID, name: "五年", colorHex: "#C98522", iconName: "calendar", kind: .fiveYear, sortOrder: 0),
        Board(id: BoardKind.freeform.stableID, name: "日常唠叨", colorHex: "#D85A30", iconName: "bubble.left.and.bubble.right", kind: .freeform, sortOrder: 1),
        Board(id: BoardKind.growth.stableID, name: "宝贝成长记录", colorHex: "#D66A91", iconName: "figure.and.child.holdinghands", kind: .growth, sortOrder: 2)
    ]

    public func ageText(on date: Date = Date()) -> String? {
        guard kind == .growth, let babyBirthday else { return nil }
        let components = Calendar.current.dateComponents([.year, .month], from: babyBirthday, to: date)
        let years = max(0, components.year ?? 0)
        let months = max(0, components.month ?? 0)
        if years > 0 {
            return "\(years) 岁 \(months) 个月"
        }
        return "\(months) 个月"
    }
}
