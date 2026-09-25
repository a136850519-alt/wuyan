import Foundation

struct StreakTracker {
    let dayKeys: [String]
    var calendar = Calendar.current

    /// UI-09①：空草稿不算「已写」——只有保存了实质内容（非草稿）的日记才计入连续记录。
    init(entries: [Entry]) {
        dayKeys = entries.filter { !$0.deleted && !$0.isDraft }.map(\.dayDate)
    }

    init(summaries: [EntrySummary]) {
        dayKeys = summaries.filter { !$0.isDraft }.map(\.dayDate)
    }

    func currentStreak(asOf date: Date = Date()) -> Int {
        let days = Set(dayKeys.compactMap(DayKey.date(from:)))
        guard var cursor = DayKey.date(from: DayKey.string(from: date)) else { return 0 }
        if !days.contains(cursor), let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    func longestStreak() -> Int {
        let days = Array(Set(dayKeys.compactMap(DayKey.date(from:)))).sorted()
        var best = 0
        var current = 0
        var previous: Date?
        for day in days {
            if let previous, calendar.dateComponents([.day], from: previous, to: day).day == 1 {
                current += 1
            } else {
                current = 1
            }
            best = max(best, current)
            previous = day
        }
        return best
    }

    func dailyCounts(in range: DateInterval) -> [Date: Int] {
        var result: [Date: Int] = [:]
        for day in dayKeys.compactMap(DayKey.date(from:)) where range.contains(day) {
            result[day, default: 0] += 1
        }
        return result
    }
}
