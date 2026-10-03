import Foundation
import Testing
@testable import Wuyan

extension GlobalStateSuite {
@Suite("Reminder scheduler")
struct ReminderSchedulerTests {
    private func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("expected reminder IDs handle month rollover")
    func monthRollover() throws {
        try TestIsolation.withIsolatedDefaults { defaults in
            defaults.set(false, forKey: SettingKey.reminderSkipWrittenDays)
            let now = localDate(2026, 1, 31, 20, 0)
            let ids = ReminderScheduler.expectedReminderIdentifiers(
                now: now,
                times: [DateComponents(hour: 21, minute: 30)],
                hasWrittenToday: false,
                lookaheadDays: 3
            )
            #expect(ids.contains("wuyan.daily.2026-02-01.0"))
            #expect(ids.contains("wuyan.daily.2026-02-02.0"))
        }
    }

    @Test("expected reminder IDs exclude passed times")
    func passedTime() throws {
        try TestIsolation.withIsolatedDefaults { defaults in
            defaults.set(false, forKey: SettingKey.reminderSkipWrittenDays)
            let now = localDate(2026, 1, 31, 22, 0)
            let ids = ReminderScheduler.expectedReminderIdentifiers(
                now: now,
                times: [DateComponents(hour: 21, minute: 30), DateComponents(hour: 23, minute: 0)],
                hasWrittenToday: false,
                lookaheadDays: 1
            )
            #expect(!ids.contains("wuyan.daily.2026-01-31.0"))
            #expect(ids.contains("wuyan.daily.2026-01-31.1"))
        }
    }

    @Test("expected reminder IDs exclude today after writing")
    func skipWrittenToday() throws {
        try TestIsolation.withIsolatedDefaults { defaults in
            defaults.set(true, forKey: SettingKey.reminderSkipWrittenDays)
            let now = localDate(2026, 1, 31, 20, 0)
            let ids = ReminderScheduler.expectedReminderIdentifiers(
                now: now,
                times: [DateComponents(hour: 21, minute: 30)],
                hasWrittenToday: true,
                lookaheadDays: 2
            )
            #expect(!ids.contains("wuyan.daily.2026-01-31.0"))
            #expect(ids.contains("wuyan.daily.2026-02-01.0"))
        }
    }
}
}
