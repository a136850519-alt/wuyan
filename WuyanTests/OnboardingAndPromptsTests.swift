import Foundation
import GRDB
import Testing
@testable import Wuyan

private final class PromptSequenceProvider: AIProvider, @unchecked Sendable {
    let isLocal = true
    let supportsEmbeddings = false
    let destinationDescription = "测试本地模型"
    var responses: [String]
    private(set) var messages: [[AIMessage]] = []

    init(_ responses: [String]) { self.responses = responses }

    func complete(_ messages: [AIMessage], options: AIOptions) async throws -> String {
        self.messages.append(messages)
        return responses.isEmpty ? "" : responses.removeFirst()
    }

    func stream(_ messages: [AIMessage], options: AIOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { _ in [0] } }
}

@Suite("Onboarding and writing prompts")
struct OnboardingAndPromptsTests {
    @Test("换名保留用户手改名称")
    func manualBoardNameSurvivesRotation() {
        var item = BoardSuggestion.recommendations(preferences: [.daily], description: "")[0]
        item.name = "我自己的日记"
        item.rotateName()
        #expect(item.name == "我自己的日记")
    }

    @Test("问题解析必须恰好两条并拦截近似角度")
    func promptValidationIsStrict() {
        let valid = AIService.validatedWritingPrompts("1. 记下今天让你停下来多看一眼的具体场景\n2. 哪个决定改变了你接下来的安排？")
        #expect(valid.count == 2)
        #expect(AIService.validatedWritingPrompts("第一条足够具体的问题内容\n第二条也足够具体的问题内容\n第三条同样具体的问题内容").isEmpty)
        #expect(AIService.validatedWritingPrompts("你当时有什么感受和想法？\n那一刻你的感受是什么？").isEmpty)
    }

    @Test("问题历史按板块和日期保存且拒绝非法数量")
    func promptHistoryPersistsAndValidates() throws {
        let db = try AppDatabase.makeInMemory()
        let board = try #require(db.boardDAO.all().first)
        #expect(throws: AIPromptHistoryError.self) {
            try db.aiPromptHistoryDAO.save(boardId: board.id, dayDate: "2026-10-12", prompts: ["只有一条"])
        }
        try db.aiPromptHistoryDAO.save(boardId: board.id, dayDate: "2026-10-12", prompts: ["今天看见了什么具体变化？", "哪一个声音让你记住了这段时间？"])
        try db.aiPromptHistoryDAO.save(boardId: board.id, dayDate: "2026-10-13", prompts: ["明天想如何安排这件小事？", "身体在哪个瞬间放松下来？"])
        let prompts = try db.aiPromptHistoryDAO.recentPrompts(boardId: board.id, since: "2026-10-12", through: "2026-10-12")
        #expect(prompts.count == 2)
        #expect(prompts.contains("今天看见了什么具体变化？"))
    }

    @Test("板块主题经过数据库与 Codable 往返仍保留")
    func boardThemeRoundTrip() throws {
        let db = try AppDatabase.makeInMemory()
        var board = try #require(db.boardDAO.all().first)
        board.recordingTheme = "周末散步时的小店、街道与见闻"
        try db.boardDAO.save(board)
        #expect(try db.boardDAO.board(id: board.id)?.recordingTheme == board.recordingTheme)
        let restored = try JSONDecoder.wuyan.decode(Board.self, from: JSONEncoder.wuyan.encode(board))
        #expect(restored.recordingTheme == board.recordingTheme)
    }

    @Test("问题缓存重启后仍按板块和所属日期恢复")
    func promptHistorySurvivesReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wuyan-prompts-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let boardID: UUID
        do {
            let first = try AppDatabase(writer: DatabaseQueue(path: url.path))
            boardID = try #require(first.boardDAO.all().first?.id)
            try first.aiPromptHistoryDAO.save(boardId: boardID, dayDate: "2026-10-12", prompts: ["记录今天的一句原话和场景细节", "写下你准备如何回应这件小事"])
        }
        let reopened = try AppDatabase(writer: DatabaseQueue(path: url.path))
        #expect(try reopened.aiPromptHistoryDAO.current(boardId: boardID, dayDate: "2026-10-12")?.prompts.count == 2)
        #expect(try reopened.aiPromptHistoryDAO.current(boardId: boardID, dayDate: "2026-10-13") == nil)
    }

    @Test("引导批量创建遇到重名时保持原子性")
    func batchBoardSaveIsAtomic() throws {
        let db = try AppDatabase.makeInMemory()
        let base = try #require(db.boardDAO.all().first)
        let a = Board(name: "批量 A", colorHex: "#D85A30", iconName: "book", sortOrder: 20)
        let duplicate = Board(name: base.name, colorHex: "#D85A30", iconName: "book", sortOrder: 21)
        #expect(throws: BoardError.self) { try db.boardDAO.saveMany([a, duplicate]) }
        #expect(try db.boardDAO.all().contains(where: { $0.name == "批量 A" }) == false)
    }

    @Test("问题生成会把校验失败原因带入下一次请求并复核语义")
    func promptGenerationRetriesWithFeedback() async throws {
        let provider = PromptSequenceProvider([
            "只有一条问题",
            "记下今天让你停下来多看一眼的具体场景\n写下你准备如何回应这件小事的下一步计划",
            "{\"distinct\":true,\"reason\":\"\"}"
        ])
        let service = AIService(provider: provider, isEnabled: true)
        let prompts = try await service.generateWritingPrompts(context: WritingContext(date: Date(), weather: nil, recentEntries: []))
        #expect(prompts.count == 2)
        #expect(provider.messages.count == 3)
        #expect(provider.messages[1].first?.content.contains("数量不对") == true)
        #expect(provider.messages[2].first?.role == .system)
    }

    @Test("写作上下文按所属日期限制在当前板块近七天")
    func writingContextUsesDayRange() async throws {
        let provider = PromptSequenceProvider(["ok"])
        let service = AIService(provider: provider, isEnabled: true)
        let boardID = UUID()
        let date = DayKey.date(from: "2026-10-12")!
        let inside = Entry(boardId: boardID, dayDate: "2026-10-08", journalDate: date, body: "应发送的近七天内容")
        let future = Entry(boardId: boardID, dayDate: "2026-10-13", journalDate: date, body: "不得发送的未来内容")
        let other = Entry(boardId: UUID(), dayDate: "2026-10-08", journalDate: date, body: "不得发送的其他板块")
        _ = try await service.writingPrompt(context: WritingContext(date: date, weather: nil, recentEntries: [inside, future, other], boardId: boardID))
        let user = try #require(provider.messages.last?.last)
        #expect(user.content.contains("应发送的近七天内容"))
        #expect(!user.content.contains("不得发送的未来内容"))
        #expect(!user.content.contains("不得发送的其他板块"))
    }

    @Test("首篇入口复用当天同板块的空草稿")
    @MainActor
    func firstEntryReusesBlankDraft() throws {
        try TestIsolation.withIsolatedDefaults { _ in
            let db = try AppDatabase.makeInMemory()
            let state = AppState(database: db)
            let board = try #require(db.boardDAO.all().first)
            let note = DayNote(date: DayKey.today, rawSummary: "", poeticLine: "")
            try db.dayNoteDAO.upsert(note)
            let blank = try db.entryDAO.create(boardId: board.id, dayNote: note)
            #expect(state.startFirstEntry(board: board))
            #expect(state.selectedEntryId == blank.id)
            #expect(try db.entryDAO.entries(on: DayKey.today).filter { $0.boardId == board.id }.count == 1)
        }
    }
}
