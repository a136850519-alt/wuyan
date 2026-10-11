import Foundation

public enum DayKey {
    public static let dayStartHour = 3

    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    public static func string(from date: Date) -> String {
        withFormatter { $0.string(from: recordingDate(for: date)) }
    }

    public static func date(from string: String) -> Date? {
        withFormatter { $0.date(from: string) }
    }

    public static var today: String {
        string(from: Date())
    }

    public static func recordingDate(for date: Date) -> Date {
        calendar.date(byAdding: .hour, value: -dayStartHour, to: date) ?? date
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let formatterLock = NSLock()

    private static func withFormatter<T>(_ body: (DateFormatter) -> T) -> T {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return body(formatter)
    }
}

extension JSONEncoder {
    static var wuyan: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var wuyan: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Date {
    var dayKey: String {
        DayKey.string(from: self)
    }
}
