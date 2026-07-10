import Foundation

struct Tag: Identifiable, Codable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var colorHex: String
}
