import Foundation

protocol WeatherService {
    func current(lat: Double, lon: Double) async throws -> Weather
}

struct OpenMeteoService: WeatherService {
    var session: URLSession = .shared

    func current(lat: Double, lon: Double) async throws -> Weather {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: "\(lat)"),
            URLQueryItem(name: "longitude", value: "\(lon)"),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RemoteStorageError.requestFailed(method: "GET", path: components.url?.absoluteString ?? "/v1/forecast", statusCode: http.statusCode)
        }
        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        return Weather(
            condition: Self.conditionText(for: decoded.current.weatherCode),
            tempC: decoded.current.temperature
        )
    }

    private static func conditionText(for code: Int) -> String {
        switch code {
        case 0:
            return "晴"
        case 1:
            return "大部晴朗"
        case 2:
            return "局部多云"
        case 3:
            return "阴"
        case 45, 48:
            return "雾"
        case 51, 53, 55:
            return "毛毛雨"
        case 56, 57:
            return "冻毛毛雨"
        case 61, 63, 65:
            return "雨"
        case 66, 67:
            return "冻雨"
        case 71, 73, 75:
            return "雪"
        case 77:
            return "米雪"
        case 80, 81, 82:
            return "阵雨"
        case 85, 86:
            return "阵雪"
        case 95:
            return "雷暴"
        case 96, 99:
            return "雷暴伴冰雹"
        default:
            return "未知"
        }
    }
}

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        var temperature: Double
        var weatherCode: Int

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case weatherCode = "weather_code"
        }
    }

    var current: Current
}
