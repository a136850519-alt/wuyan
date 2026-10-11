import Foundation

public struct Weather: Codable, Equatable, Sendable {
    public var condition: String
    public var tempC: Double

    public init(condition: String, tempC: Double) {
        self.condition = condition
        self.tempC = tempC
    }
}


enum WeatherKind: String, CaseIterable, Identifiable {
    case clear = "晴", partlyCloudy = "多云", overcast = "阴", rain = "雨", snow = "雪", thunder = "雷暴", fog = "雾", unknown = "未记录"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .clear: return "sun.max.fill"
        case .partlyCloudy: return "cloud.sun.fill"
        case .overcast: return "cloud.fill"
        case .rain: return "cloud.rain.fill"
        case .snow: return "cloud.snow.fill"
        case .thunder: return "cloud.bolt.rain.fill"
        case .fog: return "cloud.fog.fill"
        case .unknown: return "cloud"
        }
    }
    static func classify(_ condition: String?) -> WeatherKind {
        guard let condition, !condition.isEmpty else { return .unknown }
        if condition.contains("雷") { return .thunder }
        if condition.contains("雪") { return .snow }
        if condition.contains("雨") { return .rain }
        if condition.contains("雾") { return .fog }
        if condition.contains("阴") { return .overcast }
        if condition.contains("云") { return .partlyCloudy }
        if condition.contains("晴") { return .clear }
        return .unknown
    }
}

struct MetadataDraft {
    var condition: String
    var temperature: String
    var place: String
    var latitude: String
    var longitude: String

    init(entry: Entry) {
        condition = entry.weather?.condition ?? ""
        temperature = entry.weather.map { String($0.tempC) } ?? ""
        place = entry.location?.placeName ?? ""
        latitude = entry.location.map { String($0.lat) } ?? ""
        longitude = entry.location.map { String($0.lon) } ?? ""
    }

    func validated() throws -> (Weather?, GeoPlace?) {
        let condition = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = place.trimmingCharacters(in: .whitespacesAndNewlines)
        var weather: Weather?
        var location: GeoPlace?
        if !condition.isEmpty {
            guard let temp = Double(temperature.trimmingCharacters(in: .whitespacesAndNewlines)), temp.isFinite else {
                throw MetadataError.invalidTemperature
            }
            weather = Weather(condition: condition, tempC: temp)
        } else if !temperature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MetadataError.missingCondition
        }
        if !place.isEmpty {
            guard let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (-90...90).contains(lat), (-180...180).contains(lon) else {
                throw MetadataError.invalidCoordinates
            }
            location = GeoPlace(lat: lat, lon: lon, placeName: place)
        }
        return (weather, location)
    }
}

enum MetadataError: LocalizedError {
    case invalidTemperature, missingCondition, invalidCoordinates, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidTemperature: return "请输入有效温度，可使用负数或小数。修改尚未保存。"
        case .missingCondition: return "请填写天气状况，或同时清空天气和温度。"
        case .invalidCoordinates: return "请在详细位置中填写有效坐标：纬度 −90～90，经度 −180～180。"
        case .unavailable: return "当前日记暂不能修改，请稍后重试。"
        }
    }
}
