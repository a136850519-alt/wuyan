import SwiftUI

struct AIAssistantView: View {
    @EnvironmentObject private var appState: AppState
    var entry: Entry?
    var insertPrompt: (String) -> Void = { _ in }
    var applyTitle: (String) -> Void = { _ in }
    var applyTags: (String) -> Void = { _ in }
    @StateObject private var request = AIRequestState()
    @StateObject private var consentGate = CloudAIConsentGateModel()
    @State private var board: Board?
    @State private var alternate = false
    @State private var expandedPrompt: String?
    @State private var question = ""
    @State private var action: Action = .prompts
    @State private var hasAnniversary = false
    @State private var isExpanded = false

    private enum Action { case prompts, title, tags, review, ask }
    private var isBuiltIn: Bool { board.map { b in Board.builtIn.contains { $0.id == b.id || ($0.name == b.name && $0.kind == b.kind) } } ?? false }
    private var identity: String { "\(entry?.id.uuidString ?? "")-\(entry?.boardId.uuidString ?? "")-\(entry?.dayDate ?? "")" }

    var body: some View {
        InspectorCard(title: "AI 辅助写作", background: Palette.aiSurface, foreground: Palette.aiText) {
            HStack(alignment: .top) {
                Label("写作建议（\(displayedPrompts.count)）", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if isExpanded {
                    Button("换一组") { request.reset(); action = .prompts; alternate.toggle(); expandedPrompt = nil }
                        .font(.system(size: 11)).buttonStyle(.plain)
                }
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "收起写作建议" : "展开写作建议")
            }
            if isExpanded {
                Text("为「\(board?.name ?? "当前板块")」准备").font(.system(size: 11))
                Text(introduction).font(.system(size: 15, weight: .semibold))
                ForEach(displayedPrompts, id: \.self) { prompt in
                    Button { expandedPrompt = expandedPrompt == prompt ? nil : prompt } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 12))
                            Text(prompt).font(.system(size: 12)).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }.padding(.vertical, 5)
                    }.buttonStyle(.plain)
                    if expandedPrompt == prompt {
                        Text("先记下当时的场景、一句原话，再写自己的感受。也可以只留一个片段。")
                            .font(.system(size: 12))
                        Button("插入问题作为提纲") { insertPrompt(prompt) }.font(.system(size: 12))
                    }
                }
                Text(usingGeneratedPrompts ? "AI 生成建议" : "本地写作问题 · 无需启用 AI")
                    .font(.system(size: 11))
                HStack(spacing: 12) {
                    Button("拟标题") { run(.title) }
                    Button("提取标签") { run(.tags) }
                    Button("回顾本板块") { run(.review) }
                }.font(.system(size: 11)).buttonStyle(.plain).disabled(request.isRunning)
                HStack {
                    TextField("问问本板块的日记", text: $question)
                        .textFieldStyle(.roundedBorder).foregroundStyle(Palette.ink).onSubmit { run(.ask) }
                    Button("提问") { run(.ask) }.disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || request.isRunning)
                }.font(.system(size: 11))
                HStack {
                    Button("生成写作建议") { run(.prompts) }.disabled(request.isRunning)
                    Spacer()
                    Button("AI 设置") { appState.sidebarSelection = .settings }
                }.font(.system(size: 11)).buttonStyle(.plain)
                if request.isRunning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在生成…").font(.system(size: 12))
                        Spacer()
                        Button("停止") { request.cancel() }
                    }
                }
                if let error = request.error {
                    Text(error).font(.system(size: 12))
                    Button("重试") { run(action) }.disabled(request.isRunning)
                }
                if let output = request.output, action != .prompts {
                    Text(output.text).font(.system(size: 13)).textSelection(.enabled)
                    if action == .title || action == .tags {
                        Button(action == .title ? "使用这个标题" : "使用这些标签") {
                            if action == .title { applyTitle(output.text) } else { applyTags(output.text) }
                            request.reset()
                        }.disabled(request.isRunning || request.error != nil)
                    }
                    if let note = output.retrievalNote { Text(note).font(.system(size: 11)) }
                    ForEach(output.sources, id: \.self) { id in
                        Button("查看来源 · \(id.uuidString.prefix(8))") { appState.selectedEntryId = id }
                            .buttonStyle(.plain).font(.system(size: 11))
                    }
                }
            }
        }
        .cloudAIConsentAlert(gate: consentGate)
        .task(id: identity) {
            request.reset()
            consentGate.cancel()
            isExpanded = false
            board = entry.flatMap { try? appState.boards.board(id: $0.boardId) }
            if let entry { hasAnniversary = ((try? appState.entries.anniversaryEntries(boardId: entry.boardId, dayKey: entry.dayDate)) ?? []).isEmpty == false }
        }
        .onDisappear { request.cancel(); consentGate.cancel() }
    }

    private var introduction: String {
        guard isBuiltIn else { return "从你想留在这个板块的事情写起。" }
        switch board?.kind {
        case .fiveYear: return "给今天留下一笔，日后慢慢回看。"
        case .growth: return "把孩子的小小变化，认真留下。"
        default: return "从一个小片段，慢慢写起。"
        }
    }

    private var displayedPrompts: [String] {
        if action == .prompts, let text = request.output?.text {
            let generated = text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if generated.count >= 2 { return Array(generated.prefix(2)) }
        }
        guard isBuiltIn else {
            return alternate ? ["最近在这里记录的事情，有什么新进展？", "有没有一个细节想留给以后的自己？"] : ["今天有什么值得记在「\(board?.name ?? "这个板块")」？", "你想从哪个具体片段写起？"]
        }
        switch board?.kind {
        case .fiveYear:
            return alternate ? ["如果五年后再读这篇，你希望记住什么？", "今天哪个细节最能代表这一年？"] : ["今天最值得记住的一件事是什么？", hasAnniversary ? "和往年的今天比，你有什么变化？" : "今天有什么小事值得留给未来的自己？"]
        case .growth:
            return alternate ? ["今天孩子尝试了什么新事情？", "你们之间有什么亲子时刻值得留下？"] : ["今天孩子独立完成了哪件小事？", "孩子说了什么，让你想把原话记下来？"]
        default:
            return alternate ? ["今天身体和情绪分别是什么状态？", "哪一个小片段让你想慢下来？"] : ["今天哪个瞬间，让你松了一口气？", "有什么话还想说给自己听？"]
        }
    }

    private var usingGeneratedPrompts: Bool {
        guard action == .prompts, let text = request.output?.text else { return false }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.count >= 2
    }

    private func run(_ requested: Action) {
        guard let snapshot = entry else { return }
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if requested == .ask && trimmedQuestion.isEmpty { return }
        appState.reloadAISettings()
        if requested != action { request.reset() }
        action = requested
        expandedPrompt = nil
        let scope: String
        switch requested {
        case .prompts: scope = "「\(board?.name ?? "当前板块")」当前草稿及最多 4 篇该板块记录（总计最多 6000 字）、日期、天气、心情与年度年龄，用于写作建议。"
        case .title, .tags: scope = "当前草稿最多 1500 字，用于建议标题或提取标签。"
        case .review: scope = "当前文章日期向前一个月内、仅本板块的记录（合计最多 20000 字），用于回顾。"
        case .ask: scope = "你的问题及本板块最多 8 篇近期记录（合计最多 6000 字），用于回答。"
        }
        let boardSnapshot = board
        let builtIn = isBuiltIn
        let start: () -> Void = {
            guard appState.selectedEntryId == snapshot.id else { return }
            request.run {
                if appState.aiService.requiresCloudConsent, boardSnapshot?.disallowCloudAI == true { throw AIError.blockedBySensitiveBoard }
                switch requested {
                case .title: return AIRequestOutput(text: try await appState.aiService.suggestTitle(snapshot))
                case .tags: return AIRequestOutput(text: try await appState.aiService.suggestTags(snapshot).joined(separator: ", "))
                case .prompts:
                    var recent = try appState.entries.aiEntries(boardId: snapshot.boardId, limit: 30, through: snapshot.journalDate)
                    if boardSnapshot?.kind == .fiveYear {
                        let anniversaries = try appState.entries.anniversaryEntries(boardId: snapshot.boardId, dayKey: snapshot.dayDate)
                        if !anniversaries.isEmpty { recent = anniversaries + recent.prefix(2) }
                    }
                    let context = WritingContext(date: snapshot.journalDate, weather: snapshot.weather, recentEntries: recent,
                                                 boardName: boardSnapshot?.name, boardKind: builtIn ? boardSnapshot?.kind : nil,
                                                 boardId: snapshot.boardId, annualAge: boardSnapshot?.ageText(in: AppState.year(fromDayKey: snapshot.dayDate)),
                                                 draft: snapshot, mood: snapshot.mood)
                    var text = ""
                    for try await chunk in appState.aiService.streamWritingPrompt(context: context) {
                        try Task.checkCancellation(); text += chunk
                    }
                    return AIRequestOutput(text: text)
                case .review:
                    let start = DayKey.calendar.date(byAdding: .month, value: -1, to: snapshot.journalDate) ?? snapshot.journalDate
                    let entries = try appState.entries.aiEntries(boardId: snapshot.boardId, since: start, through: snapshot.journalDate)
                    return AIRequestOutput(text: try await appState.aiService.summarize(entries: entries, period: .month),
                                           retrievalNote: "仅回顾本板块，截止当前文章日期的近一个月记录。")
                case .ask:
                    let entries = try appState.entries.aiEntries(boardId: snapshot.boardId, limit: appState.aiService.requiresCloudConsent ? 30 : nil)
                    let answer = try await appState.aiService.ask(trimmedQuestion, entries: entries)
                    return AIRequestOutput(text: answer.answer, sources: answer.sourceEntryIds,
                                           retrievalNote: answer.retrievalWasDegraded ? "检索已降级：仅依据本板块最近最多 8 篇记录，未检索全库。" : "仅检索本板块记录。")
                }
            }
        }
        // 禁用/未配置时直接呈现本地错误，不打开无意义的云端授权。
        if !appState.aiService.isEnabled || appState.aiService.provider == nil || (appState.aiService.requiresCloudConsent && board?.disallowCloudAI == true) { start() }
        else { consentGate.gate(appState: appState, scope: scope, action: start) }
    }
}
