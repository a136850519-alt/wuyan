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

    /// 连续记录的游标推进在 Date 空间进行（跨月/跨年/DST 由 Calendar 处理），
    /// 但「某天是否写过」的判断用 dayKey 字符串集合完成——dayKey 是定宽零填充的
    /// yyyy-MM-dd，可直接哈希比较，避免对全部条目逐条走 NSDateFormatter 解析。
    /// 该函数会被 SwiftUI 在刷新时反复调用，O(条目数) 次日期解析足以打满主线程。
    func currentStreak(asOf date: Date = Date()) -> Int {
        let days = Set(dayKeys)
        guard var cursor = DayKey.date(from: DayKey.string(from: date)) else { return 0 }
        if !days.contains(Self.key(forMidnight: cursor)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while days.contains(Self.key(forMidnight: cursor)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    func longestStreak() -> Int {
        // dayKey 定宽零填充，字典序即时间序；每个不同日期只解析一次算相邻间隔。
        let days = Array(Set(dayKeys)).sorted()
        var best = 0
        var current = 0
        var previous: Date?
        for day in days {
            guard let date = DayKey.date(from: day) else { continue }
            if let previous, calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                current += 1
            } else {
                current = 1
            }
            best = max(best, current)
            previous = date
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

    /// 午夜游标所属的 dayKey。DayKey.string 会先把时间减去 dayStartHour（凌晨 3 点
    /// 前算前一天），因此午夜时刻必须先加回该偏移再取字符串，否则整天错位一天。
    private static func key(forMidnight date: Date) -> String {
        DayKey.string(from: date.addingTimeInterval(Double(DayKey.dayStartHour) * 3600))
    }
}
