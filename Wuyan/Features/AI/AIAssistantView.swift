import SwiftUI

struct AIAssistantView: View {
    @EnvironmentObject private var appState: AppState
    var entry: Entry?
    @State private var output = ""
    @State private var isRunning = false
    @State private var question = ""
    @State private var sourceEntryIds: [UUID] = []
    @State private var retrievalNote: String?
    @State private var requestTask: Task<Void, Never>?

    /// R2-2: 共享门控实例
    @StateObject private var consentGate = CloudAIConsentGateModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI", systemImage: "sparkles")
                    .foregroundStyle(Palette.cinnabar)
                Spacer()
                Button("提示") { runPrompt() }
                Button("标题") { suggestTitle() }
                Button("标签") { suggestTags() }
                Button("回顾") { summarizeRecent() }
            }
            HStack {
                TextField("问问自己的日记", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { askQuestion() }
                Button("问") { askQuestion() }
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if isRunning {
                HStack(spacing: 8) {
                    ProgressView("处理中…")
                    Spacer()
                    Button {
                        requestTask?.cancel()
                        requestTask = nil
                        isRunning = false
                    } label: {
                        Label("停止", systemImage: "stop.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if !output.isEmpty {
                Text(output)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !sourceEntryIds.isEmpty {
                HStack {
                    ForEach(sourceEntryIds, id: \.self) { id in
                        Button(String(id.uuidString.prefix(8))) {
                            appState.selectedEntryId = id
                            appState.sidebarSelection = .all
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            if let retrievalNote {
                Text(retrievalNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // R2-2: 使用共享云端 AI 授权门控，替代本视图内重复的 showsCloudConfirm + pendingAction
        .cloudAIConsentAlert(gate: consentGate)
        .onDisappear { requestTask?.cancel() }
    }

    private func runPrompt() {
        runStream {
            // R1-3: 使用 recentEntries 替代 timeline(filter: .all) 全量加载
            let entries = (try? appState.entries.recentEntries(limit: 30)) ?? []
            return appState.aiService.streamWritingPrompt(context: WritingContext(date: Date(), weather: entry?.weather, recentEntries: entries))
        }
    }

    private func suggestTitle() {
        guard let entry else { return }
        run { try await appState.aiService.suggestTitle(entry) }
    }

    private func suggestTags() {
        guard let entry else { return }
        run { try await appState.aiService.suggestTags(entry).joined(separator: ", ") }
    }

    private func summarizeRecent() {
        runStream {
            // 回顾按月份取数，避免把“最近 30 篇”误称为整月回顾。
            let start = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date.distantPast
            let entries = (try? appState.entries.entries(since: start)) ?? []
            return appState.aiService.streamSummary(entries: entries, period: .month)
        }
    }

    private func askQuestion() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run {
            // RAG and the degraded cloud path only need recent context. Avoid
            // loading every bodyRTF blob on the main actor for each question.
            let entries = (try? appState.entries.recentEntries(limit: AIService.cloudContextMaxEntries)) ?? []
            let answer = try await appState.aiService.ask(trimmed, entries: entries)
            await MainActor.run {
                sourceEntryIds = answer.sourceEntryIds
                retrievalNote = answer.retrievalWasDegraded
                    ? "当前 AI 服务不支持语义检索，以上回答只基于最近 8 篇条目。"
                    : nil
            }
            return answer.answer
        }
    }

    private func run(_ work: @escaping () async throws -> String) {
        appState.reloadAISettings()
        if cloudBlockedBySensitiveBoard() {
            output = "当前板块已标记为禁止云端 AI。"
            return
        }
        // R2-2: 使用共享门控替代 isCloudAISelected 字符串白名单
        consentGate.gate(appState: appState) { execute(work) }
    }

    private func runStream(_ work: @escaping () async throws -> AsyncThrowingStream<String, Error>) {
        appState.reloadAISettings()
        if cloudBlockedBySensitiveBoard() {
            output = "当前板块已标记为禁止云端 AI。"
            return
        }
        // R2-2: 使用共享门控替代 isCloudAISelected 字符串白名单
        consentGate.gate(appState: appState) { executeStream(work) }
    }

    private func execute(_ work: @escaping () async throws -> String) {
        isRunning = true
        sourceEntryIds = []
        retrievalNote = nil
        requestTask = Task {
            do {
                let result = try await work()
                await MainActor.run {
                    output = result
                    isRunning = false
                    requestTask = nil
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    output = error.localizedDescription
                    isRunning = false
                    requestTask = nil
                }
            }
        }
    }

    private func executeStream(_ work: @escaping () async throws -> AsyncThrowingStream<String, Error>) {
        isRunning = true
        output = ""
        sourceEntryIds = []
        retrievalNote = nil
        requestTask = Task {
            do {
                let stream = try await work()
                for try await chunk in stream {
                    await MainActor.run {
                        output += chunk
                    }
                }
                await MainActor.run {
                    isRunning = false
                    requestTask = nil
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    output = error.localizedDescription
                    isRunning = false
                    requestTask = nil
                }
            }
        }
    }

    // R2-2: 使用 AIService.requiresCloudConsent 替代字符串白名单
    private func cloudBlockedBySensitiveBoard() -> Bool {
        guard appState.aiService.requiresCloudConsent,
              let entry,
              let board = try? appState.boards.board(id: entry.boardId)
        else { return false }
        return board.disallowCloudAI
    }
}
