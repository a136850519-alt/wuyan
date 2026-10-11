import AppKit
import Foundation
import GRDB
import Testing
@testable import Wuyan

@Suite("1010 data and interface rules")
struct Interface1010Tests {
    @Test("年度年龄使用目标年份，出生前和未设置生日有明确结果")
    func annualAge() {
        var board = Board.builtIn[2]
        board.babyBirthday = DayKey.date(from: "2018-08-20")
        #expect(board.ageText(in: 2026) == "8 岁")
        #expect(board.ageText(in: 2025) == "7 岁")
        #expect(board.ageText(in: 2018) == "0 岁")
        #expect(board.ageText(in: 2017) == "未出生")
        #expect(board.ageText(on: DayKey.date(from: "2026-01-15")!.addingTimeInterval(43200)) == "8 岁")
        board.babyBirthday = nil
        #expect(board.ageText(in: 2026) == nil)
    }

    @Test("旧库增量升级保留原文与历史心情，关闭后重新打开仍有共享值")
    func migrationAndReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        do {
            let writer = try DatabaseQueue(path: url.path)
            try AppDatabase.migrator.migrate(writer, upTo: "v16-daynote-conflicts")
            try writer.write { db in
                try db.execute(sql: "INSERT INTO daynote(date, rawSummary, poeticLine, createdAt) VALUES (?, ?, ?, ?)", arguments: ["2026-10-10", "旧原文", "旧诗行", Date()])
                try Board.builtIn[0].save(db)
                try Entry(boardId: Board.builtIn[0].id, dayDate: "2026-10-10", body: "旧正文", mood: 2).save(db)
            }
            let database = try AppDatabase(writer: writer)
            #expect(try database.dayNoteDAO.note(dayKey: "2026-10-10")?.mood == nil)
            #expect(try database.dayNoteDAO.effectiveMood(dayKey: "2026-10-10") == 2)
            let snapshot = try database.dayNoteDAO.moodSnapshot(dayKey: "2026-10-10")
            try database.dayNoteDAO.setMood(4, dayKey: "2026-10-10", expectedNoteHash: snapshot.noteHash)
        }
        let reopened = try AppDatabase(writer: DatabaseQueue(path: url.path))
        #expect(try reopened.dayNoteDAO.effectiveMood(dayKey: "2026-10-10") == 4)
        #expect(try reopened.dayNoteDAO.note(dayKey: "2026-10-10")?.rawSummary == "旧原文")
        #expect(try reopened.entryDAO.timeline().first?.mood == 2)
        #expect(try reopened.entryDAO.timeline().first?.body == "旧正文")
    }

    @Test("旧 JSON 缺心情兼容且 nil 哈希不改变旧同步指纹")
    func oldPayloadAndHash() throws {
        let note = DayNote(date: "2026-10-10", rawSummary: "一日", poeticLine: "一日")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.wuyan.encode(note)) as? [String: Any])
        object.removeValue(forKey: "mood")
        let decoded = try JSONDecoder.wuyan.decode(DayNote.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.mood == nil)
        #expect(Hashing.dayNoteHash(decoded) == Hashing.dayNoteHash(note))
        var changed = note; changed.mood = 5
        #expect(Hashing.dayNoteHash(changed) != Hashing.dayNoteHash(note))
        #expect(try JSONDecoder.wuyan.decode(DayNote.self, from: JSONEncoder.wuyan.encode(changed)).mood == 5)
    }

    @Test("旧心情冲突不随机取值，日级确认后筛选一致且原始值保留")
    func legacyConsensusAndFilter() throws {
        let db = try AppDatabase.makeInMemory()
        let a = Entry(boardId: Board.builtIn[0].id, dayDate: "2026-10-10", body: "测试日记", mood: 1)
        let b = Entry(boardId: Board.builtIn[1].id, dayDate: a.dayDate, body: "测试日记", mood: 5)
        try db.entryDAO.save(a); try db.entryDAO.save(b)
        let before = try db.dayNoteDAO.moodSnapshot(dayKey: a.dayDate)
        #expect(before.value == nil && before.hasLegacyConflict)
        try db.dayNoteDAO.setMood(3, dayKey: a.dayDate, expectedNoteHash: before.noteHash)
        #expect(try db.entryDAO.search(EntrySearchQuery(term: "测试", mood: 3)).count == 2)
        #expect(try db.entryDAO.search(EntrySearchQuery(term: "测试", mood: 1)).isEmpty)
        #expect(try db.entryDAO.entry(id: a.id)?.mood == 1)
        #expect(try db.entryDAO.entry(id: b.id)?.mood == 5)
        #expect(throws: (any Error).self) { try db.dayNoteDAO.setMood(4, dayKey: a.dayDate, expectedNoteHash: before.noteHash) }
        let note = try #require(try db.dayNoteDAO.note(dayKey: a.dayDate))
        try db.dayNoteDAO.saveConflictCopy(note)
        #expect(try db.dayNoteDAO.conflictCopyRecords().first?.note.mood == 3)
    }

    @Test("清除当日心情后共享值回到未记录")
    func clearDayMood() throws {
        let db = try AppDatabase.makeInMemory()
        let day = "2026-10-12"
        try db.dayNoteDAO.setMood(4, dayKey: day, expectedNoteHash: nil)
        let snapshot = try db.dayNoteDAO.moodSnapshot(dayKey: day)
        try db.dayNoteDAO.setMood(nil, dayKey: day, expectedNoteHash: snapshot.noteHash)
        #expect(try db.dayNoteDAO.effectiveMood(dayKey: day) == nil)
    }

    @Test("清除只有旧条目心情的日期后不会被兼容投影恢复")
    func clearLegacyProjectedMood() throws {
        let db = try AppDatabase.makeInMemory()
        let day = "2026-10-13"
        try db.entryDAO.save(Entry(boardId: Board.builtIn[0].id, dayDate: day, body: "旧记录", mood: 2))
        let before = try db.dayNoteDAO.moodSnapshot(dayKey: day)
        #expect(before.value == 2)
        try db.dayNoteDAO.setMood(nil, dayKey: day, expectedNoteHash: before.noteHash)
        #expect(try db.dayNoteDAO.effectiveMood(dayKey: day) == nil)
        #expect(try db.entryDAO.search(EntrySearchQuery(term: "旧记录", mood: 2)).isEmpty)
        #expect(try db.dayNoteDAO.note(dayKey: day)?.moodCleared == true)
    }

    @Test("摘要保持每篇板块身份，AI 在 LIMIT 之前过滤板块并排除富文本")
    func summaryAndAIScope() throws {
        let db = try AppDatabase.makeInMemory()
        let target = Entry(boardId: Board.builtIn[2].id, journalDate: .distantPast, body: "要找到的旧记录", bodyRTF: Data([1, 2]), isFavorite: true)
        try db.entryDAO.save(target)
        for i in 0..<35 { try db.entryDAO.save(Entry(boardId: Board.builtIn[0].id, body: "无关新文章 \(i)")) }
        let summaries = try db.entryDAO.timelineSummaries()
        #expect(summaries.first { $0.id == target.id }?.boardId == target.boardId)
        #expect(summaries.first { $0.id == target.id }?.isFavorite == true)
        let scoped = try db.entryDAO.aiEntries(boardId: target.boardId, limit: 5)
        #expect(scoped.map(\.id) == [target.id])
        #expect(scoped[0].bodyRTF == nil)
    }

    @Test("天气覆盖雷雨冰雹冻雨雪雾未知，非法温度不得部分保存")
    func weatherValidation() throws {
        for (condition, expected) in [("雷暴伴冰雹", WeatherKind.thunder), ("雷阵雨", .thunder), ("冻雨", .rain), ("冻毛毛雨", .rain), ("米雪", .snow), ("阵雪", .snow), ("雾", .fog), ("阴", .overcast), ("局部多云", .partlyCloudy), ("大部晴朗", .clear), ("未知", .unknown)] {
            #expect(WeatherKind.classify(condition) == expected)
        }
        let db = try AppDatabase.makeInMemory()
        let original = Entry(boardId: Board.builtIn[0].id, body: "正文", weather: Weather(condition: "冻雨", tempC: -2.5))
        try db.entryDAO.save(original)
        var draft = MetadataDraft(entry: original)
        draft.temperature = "NaN"
        #expect(throws: MetadataError.self) { try draft.validated() }
        #expect(try db.entryDAO.entry(id: original.id)?.weather == original.weather)
        draft.temperature = "-12.5"
        #expect(try draft.validated().0?.tempC == -12.5)
        // Metadata writes preserve a newer body written since editing began.
        var newer = original; newer.body = "新正文"; try db.entryDAO.save(newer)
        let (weather, location) = try draft.validated()
        try db.entryDAO.updateMetadata(id: original.id, weather: weather, location: location, expectedWeather: original.weather, expectedLocation: original.location)
        #expect(try db.entryDAO.entry(id: original.id)?.body == "新正文")
        #expect(throws: EntrySaveError.self) {
            try db.entryDAO.updateMetadata(id: original.id, weather: nil, location: nil, expectedWeather: original.weather, expectedLocation: original.location)
        }
    }

    @Test("情绪趋势每一天只占一次权重，按日级值覆盖旧投影")
    func dailyTrend() async throws {
        let db = try AppDatabase.makeInMemory()
        for board in Board.builtIn { try db.entryDAO.save(Entry(boardId: board.id, dayDate: "2026-10-10", body: "今天", mood: 1)) }
        try db.entryDAO.save(Entry(boardId: Board.builtIn[0].id, dayDate: "2026-10-09", body: "昨天", mood: 1))
        try db.dayNoteDAO.setMood(5, dayKey: "2026-10-10", expectedNoteHash: nil)
        let service = AIService(provider: nil)
        service.moodForDay = { try db.dayNoteDAO.effectiveMood(dayKey: $0) }
        let trend = try await service.analyzeMood(entries: db.entryDAO.timeline())
        #expect(trend.score == 3)
    }

    @Test("旧条目冲突恢复不得回滚当日新心情")
    func entryConflictDoesNotReplaceDayMood() throws {
        let db = try AppDatabase.makeInMemory()
        let oldNote = DayNote(date: "2026-10-10", rawSummary: "旧", poeticLine: "旧", mood: 1)
        var current = oldNote; current.mood = 5
        try db.dayNoteDAO.upsert(current)
        try db.entryDAO.saveResolvedConflict(entry: Entry(boardId: Board.builtIn[0].id, dayDate: oldNote.date, body: "恢复内容"), board: nil, dayNote: oldNote, mediaAssets: [])
        #expect(try db.dayNoteDAO.note(dayKey: oldNote.date)?.mood == 5)
        try db.dayNoteDAO.saveConflictCopy(oldNote)
        let copy = try #require(try db.dayNoteDAO.conflictCopyRecords().first)
        try db.dayNoteDAO.restoreConflictCopy(copy)
        #expect(try db.dayNoteDAO.note(dayKey: oldNote.date)?.mood == 1)
        #expect(try db.dayNoteDAO.conflictCopyRecords().first?.note.mood == 5)
    }
}

@MainActor
@Suite("1010 AI request lifecycle")
struct AIRequestLifecycleTests {
    @Test("旧请求忽略取消并晚返回时，也不能覆盖新结果")
    func lateResultIsIgnored() async throws {
        let state = AIRequestState()
        var oldContinuation: CheckedContinuation<AIRequestOutput, Never>?
        state.run { await withCheckedContinuation { oldContinuation = $0 } }
        while oldContinuation == nil { await Task.yield() }
        state.run { AIRequestOutput(text: "新文章结果") }
        while state.isRunning { await Task.yield() }
        oldContinuation?.resume(returning: AIRequestOutput(text: "旧文章结果"))
        for _ in 0..<5 { await Task.yield() }
        #expect(state.output?.text == "新文章结果")
        #expect(!state.isRunning)
    }
}

extension GlobalStateSuite {
    @MainActor
    struct Interface1010IntegrationTests {
        @Test("两设备同步共享心情，并保留并发日札的心情副本")
        func sharedMoodSync() async throws {
            try await TestIsolation.withIsolatedDefaults { _ in
                let remote = MockRemoteStorageProvider()
                let a = try AppDatabase.makeInMemory(), b = try AppDatabase.makeInMemory()
                let day = "2026-10-10"
                try a.dayNoteDAO.upsert(DayNote(date: day, rawSummary: "今日", poeticLine: "今日", mood: 4))
                for board in Board.builtIn { try a.entryDAO.save(Entry(boardId: board.id, dayDate: day, body: "正文")) }
                _ = try await SyncEngine(provider: remote, database: a, backendFingerprint: "mood-test").syncNow()
                _ = try await SyncEngine(provider: remote, database: b, backendFingerprint: "mood-test").syncNow()
                #expect(try b.dayNoteDAO.effectiveMood(dayKey: day) == 4)
                #expect(try b.dayNoteDAO.conflictCopies().isEmpty)
                for (db, mood) in [(a, 5), (b, 2)] {
                    let snapshot = try db.dayNoteDAO.moodSnapshot(dayKey: day)
                    try db.dayNoteDAO.setMood(mood, dayKey: day, expectedNoteHash: snapshot.noteHash)
                }
                _ = try await SyncEngine(provider: remote, database: a, backendFingerprint: "mood-test").syncNow()
                _ = try await SyncEngine(provider: remote, database: b, backendFingerprint: "mood-test").syncNow()
                let values = try b.dayNoteDAO.conflictCopies().compactMap(\.mood) + [b.dayNoteDAO.effectiveMood(dayKey: day)].compactMap { $0 }
                #expect(Set(values) == Set([2, 5]))
            }
        }

        @Test("一句话无默认心情，跳过与生成保存，旧编辑器不会回写过期心情")
        func ritualAndEditor() async throws {
            try await TestIsolation.withIsolatedDefaults { _ in
                let db = try AppDatabase.makeInMemory(), app = AppState(database: try AppDatabase.makeInMemory())
                let state = AppState(database: db)
                let ritual = RitualViewModel()
                await ritual.prepare(appState: state)
                #expect(ritual.mood == nil)
                ritual.rawSummary = "今天一起散步"; ritual.mood = 4
                #expect(try db.dayNoteDAO.note(dayKey: DayKey.today) == nil)
                await ritual.skip(appState: state)
                #expect(try db.dayNoteDAO.note(dayKey: DayKey.today)?.mood == 4)
                let note = try #require(try db.dayNoteDAO.note(dayKey: DayKey.today))
                let e = try db.entryDAO.create(boardId: Board.builtIn[0].id, dayNote: note)
                let editor = EditorViewModel(); editor.load(id: e.id, appState: state)
                let snapshot = editor.currentMoodSnapshot
                #expect(editor.saveMood(5, expectedSnapshot: snapshot, appState: state))
                editor.body = "继续写"; editor.saveNow(appState: state)
                #expect(try db.dayNoteDAO.effectiveMood(dayKey: note.date) == 5)
                let other = try db.entryDAO.create(boardId: Board.builtIn[1].id, dayNote: note)
                editor.load(id: other.id, appState: state)
                #expect(editor.mood == 5)
                editor.journalDate = DayKey.date(from: "2025-01-01")!.addingTimeInterval(43200)
                #expect(editor.mood == nil)
                editor.saveNow(appState: state)
                #expect(try db.dayNoteDAO.effectiveMood(dayKey: note.date) == 5)
                let closed = RitualViewModel(); await closed.prepare(appState: app)
                closed.rawSummary = "未提交"; closed.mood = 1; closed.close()
                await closed.generate(appState: app)
                #expect(try app.dayNotes.note(dayKey: DayKey.today) == nil)
            }
        }

        @Test("提纲在光标处插入而不替换选中文本，保留富文本并支持撤销")
        func outlineUndo() throws {
            let editor = OutlineTestTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            editor.isRichText = true
            editor.allowsUndo = true
            editor.textStorage?.setAttributedString(NSAttributedString(string: "已有正文", attributes: [.foregroundColor: NSColor.systemBlue]))
            editor.setSelectedRange(NSRange(location: 2, length: 2))
            let controller = RichTextEditorController()
            controller.textView = editor
            editor.localUndo.beginUndoGrouping()
            controller.insertOutline("今天的片段")
            editor.localUndo.endUndoGrouping()
            #expect(editor.string == "已有\n今天的片段\n正文")
            #expect(editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemBlue)
            #expect(editor.localUndo.canUndo)
            editor.localUndo.undo()
            #expect(editor.string == "已有正文")
        }

        @Test("天气保存不会把并发正文变化当成旧草稿可覆盖的基线")
        func metadataDoesNotHideBodyConflict() throws {
            try TestIsolation.withIsolatedDefaults { _ in
                let db = try AppDatabase.makeInMemory()
                let state = AppState(database: db)
                let original = Entry(boardId: Board.builtIn[0].id, body: "旧正文", weather: Weather(condition: "晴", tempC: 20))
                try db.entryDAO.save(original)
                let editor = EditorViewModel()
                editor.load(id: original.id, appState: state)
                editor.body = "我的未保存正文"
                var remote = original; remote.body = "另一端新正文"
                try db.entryDAO.save(remote)
                var weather = MetadataDraft(entry: original); weather.temperature = "22"
                try editor.saveMetadata(weather, baseline: original, appState: state)
                #expect(editor.externalUpdateDetected)
                #expect(editor.body == "我的未保存正文")
                editor.saveNow(appState: state)
                #expect(try db.entryDAO.entry(id: original.id)?.body == "另一端新正文")
                #expect(try db.entryDAO.entry(id: original.id)?.weather?.tempC == 22)
            }
        }
    }
}

@MainActor
private final class OutlineTestTextView: NSTextView {
    let localUndo = UndoManager()
    override var undoManager: UndoManager? { localUndo }
}
