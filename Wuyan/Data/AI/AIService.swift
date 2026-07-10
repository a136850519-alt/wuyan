import Foundation

final class AIService: PoeticGenerator {
    var provider: AIProvider?
    var isEnabled: Bool
    var ritualPolishingEnabled: Bool
    /// 标记为「禁止云端 AI」的板块；云端 provider 下，凡涉及这些板块内容的请求一律拦截。
    var cloudBlockedBoardIds: Set<UUID> = []

    init(provider: AIProvider?, isEnabled: Bool = false, ritualPolishingEnabled: Bool = true) {
        self.provider = provider
        self.isEnabled = isEnabled
        self.ritualPolishingEnabled = ritualPolishingEnabled
    }

    /// 集中隐私门控：本地 provider 放行；云端 provider 下若任一条目属于敏感板块则拒绝。
    private func ensureCloudAllowed(for entries: [Entry]) throws {
        guard let provider, !provider.isLocal else { return }
        if entries.contains(where: { cloudBlockedBoardIds.contains($0.boardId) }) {
            throw AIError.blockedBySensitiveBoard
        }
    }

    func line(from rawSummary: String) async -> String {
        (try? await dayPoeticLine(from: rawSummary)) ?? rawSummary
    }

    func dayPoeticLine(from rawSummary: String) async throws -> String {
        guard isEnabled, ritualPolishingEnabled, let provider else {
            return rawSummary
        }
        let messages = [
            AIMessage(role: .system, content: "你是私人日记助手。把用户的一句日常总结润成一句中文批注：温和、克制、有诗情，不说教、不夸张，只输出一句。"),
            AIMessage(role: .user, content: rawSummary)
        ]
        let result = try await provider.complete(messages, options: AIOptions(temperature: 0.75, maxTokens: 80))
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func writingPrompt(context: WritingContext) async throws -> String {
        guard isEnabled, let provider else { throw AIError.disabled }
        try ensureCloudAllowed(for: context.recentEntries)
        let recent = context.recentEntries.prefix(5).map { $0.body }.joined(separator: "\n")
        return try await provider.complete([
            AIMessage(role: .system, content: "生成 1 到 3 个开放式中文日记引导问题，温和、不评判。"),
            AIMessage(role: .user, content: "最近内容：\n\(recent)")
        ], options: AIOptions(temperature: 0.8, maxTokens: 300))
    }

    func streamWritingPrompt(context: WritingContext) -> AsyncThrowingStream<String, Error> {
        guard isEnabled, let provider else {
            return AsyncThrowingStream { $0.finish(throwing: AIError.disabled) }
        }
        do { try ensureCloudAllowed(for: context.recentEntries) }
        catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
        let recent = context.recentEntries.prefix(5).map { $0.body }.joined(separator: "\n")
        return provider.stream([
            AIMessage(role: .system, content: "生成 1 到 3 个开放式中文日记引导问题，温和、不评判。"),
            AIMessage(role: .user, content: "最近内容：\n\(recent)")
        ], options: AIOptions(temperature: 0.8, maxTokens: 300))
    }

    func streamSummary(entries: [Entry], period: Period) -> AsyncThrowingStream<String, Error> {
        guard isEnabled, let provider else {
            return AsyncThrowingStream { $0.finish(throwing: AIError.disabled) }
        }
        do { try ensureCloudAllowed(for: entries) }
        catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
        let body = entries.map { "- \($0.title ?? "未命名")：\($0.body)" }.joined(separator: "\n")
        return provider.stream([
            AIMessage(role: .system, content: "为私人日记做\(period.rawValue)回顾。输出主题、情绪基调和值得回味的瞬间，中文、温和、不评判。"),
            AIMessage(role: .user, content: body)
        ], options: AIOptions(temperature: 0.55, maxTokens: 900))
    }

    func summarize(entries: [Entry], period: Period) async throws -> String {
        guard isEnabled, let provider else { throw AIError.disabled }
        try ensureCloudAllowed(for: entries)
        let body = entries.map { "- \($0.title ?? "未命名")：\($0.body)" }.joined(separator: "\n")
        return try await provider.complete([
            AIMessage(role: .system, content: "为私人日记做\(period.rawValue)回顾。输出主题、情绪基调和值得回味的瞬间，中文、温和、不评判。"),
            AIMessage(role: .user, content: body)
        ], options: AIOptions(temperature: 0.55, maxTokens: 900))
    }

    func analyzeMood(entries: [Entry]) async throws -> MoodTrend {
        let moods = entries.compactMap(\.mood)
        let score = moods.isEmpty ? 0 : Double(moods.reduce(0, +)) / Double(moods.count)
        return MoodTrend(summary: "平均情绪 \(String(format: "%.1f", score)) / 5", score: score)
    }

    func suggestTitle(_ entry: Entry) async throws -> String {
        guard isEnabled, let provider else { throw AIError.disabled }
        try ensureCloudAllowed(for: [entry])
        return try await provider.complete([
            AIMessage(role: .system, content: "为这篇日记起一个克制的中文短标题，只输出标题。"),
            AIMessage(role: .user, content: entry.body)
        ], options: AIOptions(temperature: 0.5, maxTokens: 40))
    }

    func suggestTags(_ entry: Entry) async throws -> [String] {
        guard isEnabled, let provider else { throw AIError.disabled }
        try ensureCloudAllowed(for: [entry])
        let result = try await provider.complete([
            AIMessage(role: .system, content: "从日记中提取 3 到 6 个中文标签，用逗号分隔，只输出标签。"),
            AIMessage(role: .user, content: entry.body)
        ], options: AIOptions(temperature: 0.3, maxTokens: 80))
        return result.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func ask(_ question: String, entries: [Entry]) async throws -> AnswerWithSources {
        guard isEnabled, let provider else { throw AIError.disabled }
        try ensureCloudAllowed(for: entries)
        let chunks: [RAGChunk]
        if let store = try? RAGIndexStore(provider: provider),
           let topChunks = try? await store.topChunks(for: question, entries: entries) {
            chunks = topChunks
        } else {
            chunks = entries.prefix(5).map {
                RAGChunk(id: $0.id.uuidString, entryId: $0.id, entryHash: $0.contentHash, text: $0.body, embedding: [], updatedAt: Date())
            }
        }
        let context = chunks.map { "[\($0.entryId.uuidString)] \($0.text)" }.joined(separator: "\n")
        let answer = try await provider.complete([
            AIMessage(role: .system, content: "根据提供的私人日记片段回答问题，答案后不编造来源。"),
            AIMessage(role: .user, content: "问题：\(question)\n片段：\n\(context)")
        ], options: AIOptions(temperature: 0.4, maxTokens: 800))
        return AnswerWithSources(answer: answer, sourceEntryIds: Array(Set(chunks.map(\.entryId))))
    }
}
