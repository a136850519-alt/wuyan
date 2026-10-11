import Foundation
import os

final class AIService: PoeticGenerator {
    static let cloudContextMaxEntries = 8
    static let cloudContextMaxCharactersPerEntry = 1_500
    static let cloudContextMaxCharacters = 6_000
    static let summaryContextMaxCharacters = 20_000

    var provider: AIProvider?
    var isEnabled: Bool
    var moodForDay: ((String) throws -> Int?)?
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
        return try await provider.complete(writingMessages(context: context), options: AIOptions(temperature: 0.8, maxTokens: 300))
    }

    func streamWritingPrompt(context: WritingContext) -> AsyncThrowingStream<String, Error> {
        guard isEnabled, let provider else { return AsyncThrowingStream { $0.finish(throwing: AIError.disabled) } }
        do { return provider.stream(try writingMessages(context: context), options: AIOptions(temperature: 0.8, maxTokens: 300)) }
        catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
    }

    /// 普通与流式入口共享同一板块、隐私及长度边界。
    private func writingMessages(context: WritingContext) throws -> [AIMessage] {
        if requiresCloudConsent, let id = context.boardId, cloudBlockedBoardIds.contains(id) {
            throw AIError.blockedBySensitiveBoard
        }
        var source = context.recentEntries.filter { context.boardId == nil || $0.boardId == context.boardId }
        let draft = context.draft.flatMap { item in context.boardId == nil || item.boardId == context.boardId ? item : nil }
        if let draft { source.removeAll { $0.id == draft.id } }
        let safe = filterCloudAllowed(source)
        if requiresCloudConsent, !source.isEmpty, safe.isEmpty { throw AIError.blockedBySensitiveBoard }
        let safeDraft = draft.flatMap { filterCloudAllowed([$0]).first }
        let draftText = safeDraft.map { String($0.body.prefix(Self.cloudContextMaxCharactersPerEntry)) } ?? ""
        let recent = Self.boundedEntries(safe, maxEntries: safeDraft == nil ? 5 : 4,
                                        maxCharactersPerEntry: Self.cloudContextMaxCharactersPerEntry,
                                        maxCharacters: Self.cloudContextMaxCharacters - draftText.count)
        let dayKey = DayKey.string(from: context.date)
        let hasPreviousAnniversary = recent.contains { $0.dayDate < dayKey && $0.dayDate.suffix(5) == dayKey.suffix(5) }
        let direction: String
        switch context.boardKind {
        case .growth:
            direction = "关注孩子原话、尝试与亲子时刻。年度年龄：\(context.annualAge ?? "生日未设置，不猜岁数")。"
        case .fiveYear:
            direction = hasPreviousAnniversary ? "简短留存，可对照提供的往年同日内容。" : "简短留存。没有往年同日记录，只提当日问题，不编造对照。"
        case .freeform:
            direction = "关注具体片段、情绪与自我表达，不强求总结或正能量。"
        case .none:
            direction = "结合板块名称与已有内容提开放式问题，不假定为成长或五年板块。"
        }
        return [
            AIMessage(role: .system, content: "生成恰好两个简短、开放式中文日记引导问题，每行一个。温和、不评判，不虚构经历。\(direction)"),
            AIMessage(role: .user, content: """
                板块：\(String((context.boardName ?? "当前板块").prefix(120)))
                所属日：\(dayKey)
                天气：\(context.weather?.condition ?? "未记录")；心情：\(Mood.from(context.mood)?.label ?? "未记录")
                当前草稿：\(draftText)
                本板块已有内容：
                \(recent.map { "[\($0.dayDate)] \($0.body)" }.joined(separator: "\n"))
                """)
        ]
    }

    func streamSummary(entries: [Entry], period: Period) -> AsyncThrowingStream<String, Error> {
        guard isEnabled, let provider else {
            return AsyncThrowingStream { $0.finish(throwing: AIError.disabled) }
        }
        let safeEntries = filterCloudAllowed(entries)
        guard entries.isEmpty || !requiresCloudConsent || !safeEntries.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: AIError.blockedBySensitiveBoard) }
        }
        let body = Self.boundedSummary(safeEntries)
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
        let body = Self.boundedSummary(safeEntries)
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
        let groups = Dictionary(grouping: entries.filter { !$0.deleted }, by: \.dayDate)
        let moods = try groups.compactMap { day, entries -> Int? in
            if let moodForDay { return try moodForDay(day) }
            let values = Set(entries.compactMap { Mood.from($0.mood)?.rawValue })
            return values.count == 1 ? values.first : nil
        }
        let score = moods.isEmpty ? 0 : Double(moods.reduce(0, +)) / Double(moods.count)
        return MoodTrend(summary: "按天统计 · 平均情绪 \(String(format: "%.1f", score)) / 5", score: score)
    }

    func suggestTitle(_ entry: Entry) async throws -> String {
        guard isEnabled, let provider else { throw AIError.disabled }
        let boundedEntry = Self.entryWithBoundedBody(entry)
        let safeEntries = filterCloudAllowed([boundedEntry])
        guard !safeEntries.isEmpty else { throw AIError.blockedBySensitiveBoard }
        do {
            return try await provider.complete([
                AIMessage(role: .system, content: "为这篇日记起一个克制的中文短标题，只输出标题。"),
                AIMessage(role: .user, content: boundedEntry.body)
            ], options: AIOptions(temperature: 0.5, maxTokens: 40))
        } catch {
            WuyanLog.ai.error("标题建议请求失败：\(error.localizedDescription)")
            throw error
        }
    }

    func suggestTags(_ entry: Entry) async throws -> [String] {
        guard isEnabled, let provider else { throw AIError.disabled }
        let boundedEntry = Self.entryWithBoundedBody(entry)
        let safeEntries = filterCloudAllowed([boundedEntry])
        guard !safeEntries.isEmpty else { throw AIError.blockedBySensitiveBoard }
        do {
            let result = try await provider.complete([
                AIMessage(role: .system, content: "从日记中提取 3 到 6 个中文标签，用逗号分隔，只输出标签。"),
                AIMessage(role: .user, content: boundedEntry.body)
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
        if provider.isLocal && provider.supportsEmbeddings,
           let store = try? RAGIndexStore(provider: provider),
           let topChunks = try? await store.topChunks(for: question, entries: safeEntries) {
            chunks = topChunks
            retrievalWasDegraded = false
        } else {
            WuyanLog.ai.warning("语义索引不可用，问答将明确降级为按时间顺序的条目上下文")
            chunks = Self.boundedContext(safeEntries).map {
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

    /// V3-02: bound every non-RAG context before it can enter a provider
    /// request. Entries are newest-first so a long journal cannot crowd out
    /// the recent context with old content.
    static func boundedContext(_ entries: [Entry]) -> [Entry] {
        boundedEntries(
            entries,
            maxEntries: cloudContextMaxEntries,
            maxCharactersPerEntry: cloudContextMaxCharactersPerEntry,
            maxCharacters: cloudContextMaxCharacters
        )
    }

    private static func entryWithBoundedBody(_ entry: Entry) -> Entry {
        var bounded = entry
        bounded.body = String(entry.body.prefix(cloudContextMaxCharactersPerEntry))
        bounded.bodyRTF = nil
        return bounded
    }

    private static func boundedEntries(
        _ entries: [Entry],
        maxEntries: Int,
        maxCharactersPerEntry: Int,
        maxCharacters: Int
    ) -> [Entry] {
        let sorted = entries.sorted { $0.journalDate > $1.journalDate }
        var remaining = maxCharacters
        var result: [Entry] = []
        for var entry in sorted.prefix(maxEntries) {
            guard remaining > 0 else { break }
            let limit = min(maxCharactersPerEntry, remaining)
            entry.body = String(entry.body.prefix(limit))
            result.append(entry)
            remaining -= entry.body.count
        }
        return result
    }

    private static func boundedSummary(_ entries: [Entry]) -> String {
        let sorted = entries.sorted { $0.journalDate > $1.journalDate }
        var remaining = summaryContextMaxCharacters
        var lines: [String] = []
        var truncated = false
        for entry in sorted {
            guard remaining > 0 else { truncated = true; break }
            let prefix = "- \(entry.title ?? "未命名")："
            let available = max(0, remaining - prefix.count)
            let body = String(entry.body.prefix(available))
            lines.append(prefix + body)
            remaining -= prefix.count + body.count
            if body.count < entry.body.count { truncated = true; break }
        }
        if truncated { lines.append("[内容已截断]") }
        return lines.joined(separator: "\n")
    }
}
