import Foundation
import UserNotifications

final class ReminderScheduler {
    private let skipWrittenDaysKey = "settings.reminder.skipWrittenDays"

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func setDailyReminders(_ times: [DateComponents]) async {
        await cancelAll()
        for (index, components) in times.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "晤言"
            content.body = "给今天留下一句话。"
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let request = UNNotificationRequest(identifier: "wuyan.daily.\(index)", content: content, trigger: trigger)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func cancelAll() async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: (0..<12).map { "wuyan.daily.\($0)" })
    }

    func refreshForToday(hasWrittenToday: Bool, times: [DateComponents]) async {
        let skip = UserDefaults.standard.bool(forKey: skipWrittenDaysKey)
        if skip && hasWrittenToday {
            await cancelAll()
        } else {
            await setDailyReminders(times)
        }
    }
}
