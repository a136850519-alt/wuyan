import Foundation
import Testing
@testable import Wuyan

private final class RecordingAIProvider: AIProvider, @unchecked Sendable {
    let isLocal: Bool
    let supportsEmbeddings: Bool
    let destinationDescription = "测试 AI"
    private(set) var completedMessages: [[AIMessage]] = []
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
        AsyncThrowingStream { continuation in
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
}
