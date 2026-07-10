import Foundation

enum Mood: Int, Codable, CaseIterable, Identifiable, Sendable {
    case veryLow = 1
    case low
    case neutral
    case good
    case bright

    var id: Int { rawValue }
}
