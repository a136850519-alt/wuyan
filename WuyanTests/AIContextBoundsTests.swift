import Foundation
import Testing
@testable import Wuyan

private final class RecordingAIProvider: AIProvider, @unchecked Sendable {
    let isLocal: Bool
    let supportsEmbeddings: Bool
    let destinationDescription = "测试 AI"
    private(set) var completedMessages: [[AIMessage]] = []
    private(set) var streamedMessages: [[AIMessage]] = []
    private(set) var embedCallCount = 0
    private(set) var embeddedTextCount = 0

    init(isLocal: Bool, supportsEmbeddings: Bool) {
        self.isLocal = isLocal
        self.supportsEmbeddings = supportsEmbeddings
    }

    func complete(_ messages: [AIMessage], options: AIOptions) async throws -> String {
        completedMessages.append(messages)
        return "ok"
    }

    func stream(_ messages: [AIMessage], options: AIOptions) -> AsyncThrowingStream<String, Error> {
        streamedMessages.append(messages)
        return AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        embedCallCount += 1
        embeddedTextCount += texts.count
        return texts.map { _ in [0] }
    }
}

@Suite("AI context bounds")
struct AIContextBoundsTests {
    private func entries(count: Int, bodyLength: Int = 3_000) -> [Entry] {
        (0..<count).map { index in
            Entry(
                id: UUID(),
                boardId: UUID(),
                dayDate: String(format: "2026-09-%02d", (index % 28) + 1),
                journalDate: Date(timeIntervalSince1970: Double(index)),
                body: String(repeating: "字", count: bodyLength),
                isDraft: false
            )
        }
    }

    @Test("云端问答只发送有界上下文且不建立嵌入索引")
    func cloudAskIsBounded() async throws {
        let provider = RecordingAIProvider(isLocal: false, supportsEmbeddings: false)
        let service = AIService(provider: provider, isEnabled: true)
        let source = entries(count: 100)
        let answer = try await service.ask("最近如何？", entries: source)

        let userMessage = try #require(provider.completedMessages.last?.first(where: { $0.role == .user }))
        let ids = source.map { $0.id.uuidString }.filter { userMessage.content.contains($0) }
        #expect(Set(ids).count <= 8)
        #expect(userMessage.content.components(separatedBy: "片段：\n").last?.count ?? .max <= 6_000 + 200)
        #expect(answer.retrievalWasDegraded)
        #expect(provider.embedCallCount == 0)
    }

    @Test("非回环 Ollama 不发送正文到嵌入服务")
    func remoteEmbeddingProviderDoesNotBuildRAG() async throws {
        let provider = RecordingAIProvider(isLocal: false, supportsEmbeddings: true)
        let service = AIService(provider: provider, isEnabled: true)
        let answer = try await service.ask("问题", entries: entries(count: 10))
        #expect(answer.retrievalWasDegraded)
        #expect(provider.embedCallCount == 0)
    }

    @Test("本地语义检索接收超过八篇候选")
    func localSemanticSearchUsesFullCorpus() async throws {
        let provider = RecordingAIProvider(isLocal: true, supportsEmbeddings: true)
        let service = AIService(provider: provider, isEnabled: true)
        _ = try await service.ask("问题", entries: entries(count: 12, bodyLength: 40))
        #expect(provider.embeddedTextCount > 8)
    }

    @Test("写作引导最多使用五篇最近条目")
    func writingPromptIsBounded() async throws {
        let provider = RecordingAIProvider(isLocal: false, supportsEmbeddings: false)
        let service = AIService(provider: provider, isEnabled: true)
        let source = entries(count: 30)
        _ = try await service.writingPrompt(
            context: WritingContext(date: Date(), weather: nil, recentEntries: source)
        )
        let message = try #require(provider.completedMessages.last?.first(where: { $0.role == .user }))
        let ids = source.map { $0.id.uuidString }.filter { message.content.contains($0) }
        #expect(ids.count <= 5)
    }

    @Test("普通和流式写作建议使用同一草稿、板块、年度年龄与字符边界")
    func writingDraftAndStreamingScope() async throws {
        let provider = RecordingAIProvider(isLocal: false, supportsEmbeddings: false)
        let service = AIService(provider: provider, isEnabled: true)
        let boardID = Board.builtIn[2].id
        let date = DayKey.date(from: "2026-01-15")!.addingTimeInterval(43200)
        let draft = Entry(boardId: boardID, journalDate: date, body: "尚未保存的原话" + String(repeating: "稿", count: 2000))
        var stored = draft; stored.body = "被草稿取代的旧正文"
        let history = (0..<10).map { i in Entry(boardId: boardID, journalDate: date.addingTimeInterval(Double(-i-1) * 86400), body: "历史\(i)" + String(repeating: "字", count: 2000)) }
        let unrelated = Entry(boardId: Board.builtIn[0].id, body: "绝不发送的其他板块内容")
        let context = WritingContext(date: date, weather: nil, recentEntries: history + [stored, unrelated], boardName: "宝贝成长记录", boardKind: .growth, boardId: boardID, annualAge: "8 岁", draft: draft, mood: 4)
        _ = try await service.writingPrompt(context: context)
        for try await _ in service.streamWritingPrompt(context: context) {}
        let completed = try #require(provider.completedMessages.last)
        let streamed = try #require(provider.streamedMessages.last)
        #expect(completed.map(\.content) == streamed.map(\.content))
        let text = completed.map(\.content).joined(separator: "\n")
        #expect(text.contains("尚未保存的原话") && text.contains("2026-01-15") && text.contains("8 岁") && text.contains("不错"))
        #expect(!text.contains("绝不发送") && !text.contains("被草稿取代"))
        #expect(text.count < 6400)
        #expect((0..<10).filter { text.contains("历史\($0)") }.count <= 4)

        service.cloudBlockedBoardIds = [boardID]
        await #expect(throws: AIError.self) { try await service.writingPrompt(context: context) }
        await #expect(throws: AIError.self) { for try await _ in service.streamWritingPrompt(context: context) {} }
        #expect(provider.completedMessages.count == 1 && provider.streamedMessages.count == 1)
        service.isEnabled = false
        await #expect(throws: AIError.self) { try await service.writingPrompt(context: context) }
    }
}
