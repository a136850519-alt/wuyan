import Testing
import Foundation
@testable import Wuyan

// 回归：连续天数计算曾对全部条目逐条走 NSDateFormatter 解析，且在 SwiftUI
// body 中逐帧调用（侧边栏「连续 N 天」、日历统计卡），同步进度连发时足以
// 打满主线程。修复后成员判断走 dayKey 字符串集合，视图层只在载入时算一次。
struct StreakTrackerRegressionTests {

    /// 用正午时间生成 dayKey（正午减 3 小时仍是当天，避开凌晨归属规则）。
    private func key(relativeDays offset: Int, from base: Date) -> String {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: offset, to: base) ?? base
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        return DayKey.string(from: noon)
    }

    private func summary(day: String, isDraft: Bool = false) -> EntrySummary {
        EntrySummary(
            id: UUID(), dayDate: day, journalDate: Date(), title: nil,
            bodyPreview: "", bodyLength: 1, isDraft: isDraft
        )
    }

    @Test("连续天数：连续三天计 3")
    func currentStreakCountsConsecutiveDays() {
        let base = Date()
        let tracker = StreakTracker(summaries: [
            summary(day: key(relativeDays: 0, from: base)),
            summary(day: key(relativeDays: -1, from: base)),
            summary(day: key(relativeDays: -2, from: base)),
        ])
        #expect(tracker.currentStreak() == 3)
    }

    @Test("连续天数：断档截断")
    func currentStreakStopsAtGap() {
        let base = Date()
        let tracker = StreakTracker(summaries: [
            summary(day: key(relativeDays: 0, from: base)),
            // 昨天空缺
            summary(day: key(relativeDays: -2, from: base)),
        ])
        #expect(tracker.currentStreak() == 1)
    }

    @Test("连续天数：草稿不计入（UI-09①）")
    func currentStreakIgnoresDrafts() {
        let base = Date()
        let tracker = StreakTracker(summaries: [
            summary(day: key(relativeDays: 0, from: base)),
            summary(day: key(relativeDays: 0, from: base), isDraft: true),
            summary(day: key(relativeDays: -1, from: base)),
        ])
        #expect(tracker.currentStreak() == 2)
    }

    @Test("连续天数：今天未写从昨天起算")
    func currentStreakStartsFromYesterdayWhenTodayMissing() {
        let base = Date()
        let tracker = StreakTracker(summaries: [
            summary(day: key(relativeDays: -1, from: base)),
            summary(day: key(relativeDays: -2, from: base)),
        ])
        #expect(tracker.currentStreak() == 2)
    }

    @Test("最长连续：跨断档取最大段")
    func longestStreakPicksLongestRun() {
        let base = Date()
        let tracker = StreakTracker(summaries: [
            summary(day: key(relativeDays: -5, from: base)),
            summary(day: key(relativeDays: -4, from: base)),
            summary(day: key(relativeDays: -3, from: base)),
            summary(day: key(relativeDays: -1, from: base)),
        ])
        #expect(tracker.longestStreak() == 3)
        #expect(tracker.currentStreak() == 1)
    }

    @Test("空数据返回 0")
    func emptyDayKeysYieldZero() {
        let tracker = StreakTracker(summaries: [])
        #expect(tracker.currentStreak() == 0)
        #expect(tracker.longestStreak() == 0)
    }
}

// 回归：编辑器此前不感知后台对当前条目的改写（同步拉取/天气定位回写），
// 自动保存撞乐观并发后反复弹全局 alert。现在观察流负责感知并分流处理。
//
// 注意：TestIsolation 的 NSLock 不能在 await 期间持有——swift-testing 并行运行
// 套件时，并行的 @MainActor 同步测试会阻塞在 lock 上占住主线程，本测试挂起后
// 的恢复也需要主线程，互相等待即死锁。因此隔离容器内只做同步准备，
// 观察流轮询等异步断言全部放在容器外（只触达内存库，不读全局设置）。
extension GlobalStateSuite {
@MainActor
struct EditorExternalUpdateRegressionTests {

    private struct Fixture {
        let db: AppDatabase
        let appState: AppState
        let entryId: UUID
    }

    private func makeFixture(body: String) throws -> Fixture {
        try TestIsolation.withIsolatedDefaults { _ in
            let db = try AppDatabase.makeInMemory()
            let appState = AppState(database: db)
            let board = try #require(db.boardDAO.all().first)
            let entry = Entry(boardId: board.id, dayDate: "2026-09-26", body: body, isDraft: false)
            try db.entryDAO.save(entry)
            return Fixture(db: db, appState: appState, entryId: entry.id)
        }
    }

    /// 模拟同步/天气定位后台改写：写入新正文并刷新同步指纹。
    private func writeExternalVersion(_ fixture: Fixture, body: String, weather: Weather? = nil) throws {
        guard var external = try fixture.db.entryDAO.entry(id: fixture.entryId) else {
            fatalError("fixture entry missing")
        }
        external.body = body
        external.weather = weather
        external.refreshForSave()
        try fixture.db.entryDAO.save(external)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(3)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("无未保存修改：外部改写静默应用到编辑器")
    func externalChangeAppliesWhenClean() async throws {
        let fixture = try makeFixture(body: "第一版")
        let viewModel = EditorViewModel()
        viewModel.load(id: fixture.entryId, appState: fixture.appState)
        try writeExternalVersion(fixture, body: "后台同步来的第二版")

        let applied = await waitUntil { viewModel.body == "后台同步来的第二版" }
        #expect(applied, "干净状态下编辑器应静默应用外部新版本")
        #expect(viewModel.externalUpdateDetected == false)
    }

    @Test("有未保存修改：暂停自动保存并亮横幅，不弹全局错误")
    func externalChangeWhileDirtyShowsBanner() async throws {
        let fixture = try makeFixture(body: "第一版")
        let viewModel = EditorViewModel()
        viewModel.load(id: fixture.entryId, appState: fixture.appState)

        // 用户开始编辑（自动保存防抖 0.5s 内外部写入到达）
        viewModel.title = "我的未保存标题"
        try writeExternalVersion(fixture, body: "后台同步来的第二版")

        let flagged = await waitUntil { viewModel.externalUpdateDetected }
        #expect(flagged, "脏状态下外部改写应亮出冲突横幅")
        #expect(fixture.appState.errorMessage == nil, "冲突不应再走全局弹窗")
        #expect(viewModel.title == "我的未保存标题", "本地编辑应保留")
    }

    @Test("「以我的编辑为准」：在最新底稿上保存，保留外部天气，清除横幅")
    func keepCurrentEditsMergesOntoFreshBase() async throws {
        let fixture = try makeFixture(body: "第一版")
        let viewModel = EditorViewModel()
        viewModel.load(id: fixture.entryId, appState: fixture.appState)
        viewModel.title = "我的未保存标题"

        // 模拟天气/定位后台回写：外部版本带新天气
        try writeExternalVersion(fixture, body: "后台同步来的第二版", weather: Weather(condition: "晴", tempC: 22))

        _ = await waitUntil { viewModel.externalUpdateDetected }
        viewModel.keepCurrentEdits(appState: fixture.appState)

        #expect(viewModel.externalUpdateDetected == false)
        #expect(viewModel.isDirty == false)
        let final = try #require(try fixture.db.entryDAO.entry(id: fixture.entryId))
        #expect(final.title == "我的未保存标题")
        #expect(final.body == "第一版", "以我的编辑为准：正文取编辑器版本")
        #expect(final.weather?.condition == "晴", "天气等后台字段以数据库版本为准")
    }

    @Test("「重新载入」：放弃未保存修改，以数据库版本为准")
    func reloadDiscardsLocalEdits() async throws {
        let fixture = try makeFixture(body: "第一版")
        let viewModel = EditorViewModel()
        viewModel.load(id: fixture.entryId, appState: fixture.appState)
        viewModel.title = "我的未保存标题"

        try writeExternalVersion(fixture, body: "后台同步来的第二版")

        _ = await waitUntil { viewModel.externalUpdateDetected }
        viewModel.reloadFromDatabase(appState: fixture.appState)

        #expect(viewModel.externalUpdateDetected == false)
        #expect(viewModel.body == "后台同步来的第二版")
        #expect(viewModel.title == "", "外部版本无标题，重新载入后应为空")
        let final = try #require(try fixture.db.entryDAO.entry(id: fixture.entryId))
        #expect(final.body == "后台同步来的第二版")
    }

    @Test("条目被移除后未保存输入另存为独立新日记")
    func removedEntryEditsBecomeNewEntry() async throws {
        let fixture = try makeFixture(body: "原始正文")
        let viewModel = EditorViewModel()
        viewModel.load(id: fixture.entryId, appState: fixture.appState)
        viewModel.body = "移除期间的本地输入"
        try fixture.db.entryDAO.removeArchivedLocal(id: fixture.entryId)
        viewModel.flushIfNeeded(appState: fixture.appState)

        let saved = await waitUntil {
            let entries = (try? fixture.db.entryDAO.timeline(filter: .all)) ?? []
            return entries.contains { $0.id != fixture.entryId && $0.body == "移除期间的本地输入" }
        }
        #expect(saved)
        #expect(try fixture.db.entryDAO.entry(id: fixture.entryId) == nil)
        let copies = try fixture.db.entryDAO.timeline(filter: .all).filter { $0.id != fixture.entryId }
        #expect(copies.contains { $0.title?.hasPrefix("【未保存的编辑】") == true })
    }
}
}
