import Foundation

public struct Weather: Codable, Equatable, Sendable {
    public var condition: String
    public var tempC: Double

    public init(condition: String, tempC: Double) {
        self.condition = condition
        self.tempC = tempC
    }
}
