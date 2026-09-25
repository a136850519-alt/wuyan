import Foundation
import os

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

    /// R2-2: 云端 AI 是否需要用户确认授权。
    /// 基于 provider.isLocal 判定，替代旧的字符串白名单（"zhipu" || "claude"），
    /// 新增云 Provider 时自动纳入，无需在此处追加。
    /// S04/UI-05：Ollama 的 isLocal 由实际目的地址（仅回环算本地）决定。
    var requiresCloudConsent: Bool {
        provider?.isLocal == false
    }

    /// S04/UI-05：授权弹窗展示的目的地描述，同时作为会话信任的绑定标识。
    var consentDestinationIdentifier: String {
        provider?.destinationDescription ?? "未配置 AI 服务"
    }

    /// 过滤掉敏感板块的条目，只保留可云端发送的条目。
    /// 替代旧的 ensureCloudAllowed（全拒绝策略），改为只过滤不拒绝。
    func filterCloudAllowed(_ entries: [Entry]) -> [Entry] {
        guard let provider, !provider.isLocal else { return entries }
        return entries.filter { !cloudBlockedBoardIds.contains($0.boardId) }
    }

    func line(from rawSummary: String) async -> String {
        do {
            return try await dayPoeticLine(from: rawSummary)
        } catch {
            WuyanLog.ai.warning("诗行润色失败：\(error.localizedDescription)")
            return rawSummary
        }
    }

    func dayPoeticLine(from rawSummary: String) async throws -> String {
        guard isEnabled, ritualPolishingEnabled, let provider else {
            return rawSummary
        }
        let messages = [
            AIMessage(role: .system, content: "你是私人日记助手。把用户的一句日常总结润成一句中文批注：温和、克制、有诗情，不说教、不夸张，只输出一句。"),
            AIMessage(role: .user, content: rawSummary)
        ]
        do {
            let result = try await provider.complete(messages, options: AIOptions(temperature: 0.75, maxTokens: 80))
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            WuyanLog.ai.error("诗行生成请求失败：\(error.localizedDescription)")
            throw error
        }
    }

    func writingPrompt(context: WritingContext) async throws -> String {
        guard isEnabled, let provider else { throw AIError.disabled }
        let safeEntries = filterCloudAllowed(context.recentEntries)
        guard context.recentEntries.isEmpty || !requiresCloudConsent || !safeEntries.isEmpty else {
            throw AIError.blockedBySensitiveBoard
        }
        let recent = safeEntries.map { $0.body }.joined(separator: "\n")
        do {
            return try await provider.complete([
                AIMessage(role: .system, content: "生成 1 到 3 个开放式中文日记引导问题，温和、不评判。"),
                AIMessage(role: .user, content: "最近内容：\n\(recent)")
            ], options: AIOptions(temperature: 0.8, maxTokens: 300))
        } catch {
            WuyanLog.ai.error("写作引导请求失败：\(error.localizedDescription)")
            throw error
        }
    }

    func streamWritingPrompt(context: WritingContext) -> AsyncThrowingStream<String, Error> {
        guard isEnabled, let provider else {
            return AsyncThrowingStream { $0.finish(throwing: AIError.disabled) }
        }
        let safeEntries = filterCloudAllowed(context.recentEntries)
        guard context.recentEntries.isEmpty || !requiresCloudConsent || !safeEntries.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: AIError.blockedBySensitiveBoard) }
        }
        let recent = safeEntries.map { $0.body }.joined(separator: "\n")
        return provider.stream([
            AIMessage(role: .system, content: "生成 1 到 3 个开放式中文日记引导问题，温和、不评判。"),
            AIMessage(role: .user, content: "最近内容：\n\(recent)")
        ], options: AIOptions(temperature: 0.8, maxTokens: 300))
    }

    func streamSummary(entries: [Entry], period: Period) -> AsyncThrowingStream<String, Error> {
        guard isEnabled, let provider else {
            return AsyncThrowingStream { $0.finish(throwing: AIError.disabled) }
        }
        let safeEntries = filterCloudAllowed(entries)
        guard entries.isEmpty || !requiresCloudConsent || !safeEntries.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: AIError.blockedBySensitiveBoard) }
        }
        let body = safeEntries.map { "- \($0.title ?? "未命名")：\($0.body)" }.joined(separator: "\n")
        return provider.stream([
            AIMessage(role: .system, content: "为私人日记做\(period.rawValue)回顾。输出主题、情绪基调和值得回味的瞬间，中文、温和、不评判。"),
            AIMessage(role: .user, content: body)
        ], options: AIOptions(temperature: 0.55, maxTokens: 900))
    }

    func summarize(entries: [Entry], period: Period) async throws -> String {
        guard isEnabled, let provider else { throw AIError.disabled }
        let safeEntries = filterCloudAllowed(entries)
        guard entries.isEmpty || !requiresCloudConsent || !safeEntries.isEmpty else {
            throw AIError.blockedBySensitiveBoard
        }
        let body = safeEntries.map { "- \($0.title ?? "未命名")：\($0.body)" }.joined(separator: "\n")
        do {
            return try await provider.complete([
                AIMessage(role: .system, content: "为私人日记做\(period.rawValue)回顾。输出主题、情绪基调和值得回味的瞬间，中文、温和、不评判。"),
                AIMessage(role: .user, content: body)
            ], options: AIOptions(temperature: 0.55, maxTokens: 900))
        } catch {
            WuyanLog.ai.error("\(period.rawValue)回顾请求失败：\(error.localizedDescription)")
            throw error
        }
    }

    func analyzeMood(entries: [Entry]) async throws -> MoodTrend {
        let moods = entries.compactMap(\.mood)
        let score = moods.isEmpty ? 0 : Double(moods.reduce(0, +)) / Double(moods.count)
        return MoodTrend(summary: "平均情绪 \(String(format: "%.1f", score)) / 5", score: score)
    }

    func suggestTitle(_ entry: Entry) async throws -> String {
        guard isEnabled, let provider else { throw AIError.disabled }
        let safeEntries = filterCloudAllowed([entry])
        guard !safeEntries.isEmpty else { throw AIError.blockedBySensitiveBoard }
        do {
            return try await provider.complete([
                AIMessage(role: .system, content: "为这篇日记起一个克制的中文短标题，只输出标题。"),
                AIMessage(role: .user, content: entry.body)
            ], options: AIOptions(temperature: 0.5, maxTokens: 40))
        } catch {
            WuyanLog.ai.error("标题建议请求失败：\(error.localizedDescription)")
            throw error
        }
    }

    func suggestTags(_ entry: Entry) async throws -> [String] {
        guard isEnabled, let provider else { throw AIError.disabled }
        let safeEntries = filterCloudAllowed([entry])
        guard !safeEntries.isEmpty else { throw AIError.blockedBySensitiveBoard }
        do {
            let result = try await provider.complete([
                AIMessage(role: .system, content: "从日记中提取 3 到 6 个中文标签，用逗号分隔，只输出标签。"),
                AIMessage(role: .user, content: entry.body)
            ], options: AIOptions(temperature: 0.3, maxTokens: 80))
            return result.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } catch {
            WuyanLog.ai.error("标签建议请求失败：\(error.localizedDescription)")
            throw error
        }
    }

    func ask(_ question: String, entries: [Entry]) async throws -> AnswerWithSources {
        guard isEnabled, let provider else { throw AIError.disabled }
        let safeEntries = filterCloudAllowed(entries)
        guard entries.isEmpty || !requiresCloudConsent || !safeEntries.isEmpty else {
            throw AIError.blockedBySensitiveBoard
        }
        let chunks: [RAGChunk]
        let retrievalWasDegraded: Bool
        if let store = try? RAGIndexStore(provider: provider),
           let topChunks = try? await store.topChunks(for: question, entries: safeEntries) {
            chunks = topChunks
            retrievalWasDegraded = false
        } else {
            WuyanLog.ai.warning("语义索引不可用，问答将明确降级为按时间顺序的条目上下文")
            chunks = safeEntries.map {
                RAGChunk(id: $0.id.uuidString, entryId: $0.id, entryHash: $0.contentHash, text: $0.body, embedding: [], updatedAt: Date())
            }
            retrievalWasDegraded = true
        }
        let context = chunks.map { "[\($0.entryId.uuidString)] \($0.text)" }.joined(separator: "\n")
        do {
            let answer = try await provider.complete([
                AIMessage(role: .system, content: "根据提供的私人日记片段回答问题，答案后不编造来源。"),
                AIMessage(role: .user, content: "问题：\(question)\n片段：\n\(context)")
            ], options: AIOptions(temperature: 0.4, maxTokens: 800))
            return AnswerWithSources(
                answer: answer,
                sourceEntryIds: Array(Set(chunks.map(\.entryId))),
                retrievalWasDegraded: retrievalWasDegraded
            )
        } catch {
            WuyanLog.ai.error("AI 问答请求失败：\(error.localizedDescription)")
            throw error
        }
    }
}
