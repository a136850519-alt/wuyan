import Foundation

enum Mood: Int, Codable, CaseIterable, Identifiable, Sendable {
    case veryLow = 1
    case low
    case neutral
    case good
    case bright

    var id: Int { rawValue }

    var emoji: String {
        switch self {
        case .veryLow: return "😞"
        case .low: return "😔"
        case .neutral: return "😐"
        case .good: return "🙂"
        case .bright: return "😄"
        }
    }

    var label: String {
        switch self {
        case .veryLow: return "低落"
        case .low: return "有点累"
        case .neutral: return "平静"
        case .good: return "不错"
        case .bright: return "开心"
        }
    }

    static func from(_ value: Int?) -> Mood? {
        value.flatMap(Mood.init(rawValue:))
    }
}
