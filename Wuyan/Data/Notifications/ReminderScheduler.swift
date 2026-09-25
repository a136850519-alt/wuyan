import Foundation
import UserNotifications

final class ReminderScheduler {
    private let skipWrittenDaysKey = SettingKey.reminderSkipWrittenDays
    /// 注册的天数范围——14 天，避免 7 天后提醒静默消失
    private let lookaheadDays = 14

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// 为未来 N 天逐天注册提醒（每天各时间段一条，identifier 带日期），不使用 repeats。
    /// R0-8: 使用 DayKey 的 3am 规则确定"今天"，确保凌晨 0-3 点时日期与日记一致。
    func setDailyReminders(_ times: [DateComponents]) async {
        await cancelAll()
        let center = UNUserNotificationCenter.current()
        let calendar = Calendar.current
        // R0-8: 使用 DayKey.today（3am 规则）确定"今天"
        let todayDayKey = DayKey.today
        let today = Self.dateFromDayKey(todayDayKey)

        for dayOffset in 0..<lookaheadDays {
            guard let targetDate = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            for (timeIndex, components) in times.enumerated() {
                // 构造目标日期的完整 DateComponents
                var fullComponents = DateComponents()
                fullComponents.year = calendar.component(.year, from: targetDate)
                fullComponents.month = calendar.component(.month, from: targetDate)
                fullComponents.day = calendar.component(.day, from: targetDate)
                fullComponents.hour = components.hour
                fullComponents.minute = components.minute

                let content = UNMutableNotificationContent()
                content.title = "晤言"
                content.body = "给今天留下一句话。"
                content.sound = .default

                let trigger = UNCalendarNotificationTrigger(dateMatching: fullComponents, repeats: false)
                // identifier 包含日期和时段序号，便于精确取消
                let dayStr = Self.dayKeyFormatter.string(from: targetDate)
                let identifier = "wuyan.daily.\(dayStr).\(timeIndex)"
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                try? await center.add(request)
            }
        }
    }

    /// 基于前缀过滤删除所有 wuyan.daily.* 通知
    func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix("wuyan.daily.") }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// 刷新提醒状态。
    /// UI-09②：每次调用都先把未来 14 天窗口重新铺满——否则长期不启动应用后
    /// 窗口耗尽，提醒静默消失；启动与每次保存都会走到这里，实现自动续排。
    /// 已写今天的跳过逻辑保留：铺满后仅取消今天剩余时段。
    /// R0-8: 使用 DayKey.today（3am 规则）判断"今天"。
    func refreshForToday(hasWrittenToday: Bool, times: [DateComponents]) async {
        await setDailyReminders(times)
        let skip = UserDefaults.standard.bool(forKey: skipWrittenDaysKey)
        if skip && hasWrittenToday {
            // 仅取消今天剩余的通知，不移除未来天数的
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            let todayStr = DayKey.today
            let todayIds = pending.map(\.identifier).filter { $0.hasPrefix("wuyan.daily.\(todayStr).") }
            if !todayIds.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: todayIds)
            }
        }
    }

    /// R0-8: 将 DayKey（yyyy-MM-dd）转为 Date
    private static func dateFromDayKey(_ dayKey: String) -> Date {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date() }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return Calendar.current.date(from: components) ?? Date()
    }

    /// R0-8: 使用 en_US_POSIX 确保日期格式不受用户区域设置影响
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
