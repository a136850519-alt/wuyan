import Foundation

public struct GeoPlace: Codable, Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public var placeName: String

    public init(lat: Double, lon: Double, placeName: String) {
        self.lat = lat
        self.lon = lon
        self.placeName = placeName
    }
}
