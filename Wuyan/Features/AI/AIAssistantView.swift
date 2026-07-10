import SwiftUI

struct AIAssistantView: View {
    @EnvironmentObject private var appState: AppState
    var entry: Entry?
    @State private var output = ""
    @State private var isRunning = false
    @State private var pendingAction: (() -> Void)?
    @State private var showsCloudConfirm = false
    @State private var question = ""
    @State private var sourceEntryIds: [UUID] = []

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
                ProgressView()
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
        }
        .alert("将发送内容到云端 AI", isPresented: $showsCloudConfirm) {
            Button("取消", role: .cancel) { pendingAction = nil }
            Button("信任本会话") {
                appState.trustCloudForSession = true
                pendingAction?()
                pendingAction = nil
            }
            Button("继续") { pendingAction?(); pendingAction = nil }
        } message: {
            Text("将发送当前条目或最近日记摘要用于生成结果。")
        }
    }

    private func runPrompt() {
        runStream {
            let entries = (try? appState.entries.timeline(filter: .all)) ?? []
            let limited = Array(entries.prefix(30))
            return appState.aiService.streamWritingPrompt(context: WritingContext(date: Date(), weather: entry?.weather, recentEntries: limited))
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
            let entries = (try? appState.entries.timeline(filter: .all)) ?? []
            return appState.aiService.streamSummary(entries: Array(entries.prefix(30)), period: .month)
        }
    }

    private func askQuestion() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run {
            let entries = nonSensitiveEntries()
            let answer = try await appState.aiService.ask(trimmed, entries: entries)
            await MainActor.run {
                sourceEntryIds = answer.sourceEntryIds
            }
            return answer.answer
        }
    }

    private func nonSensitiveEntries() -> [Entry] {
        let entries = (try? appState.entries.timeline(filter: .all)) ?? []
        return appState.aiService.filterCloudAllowed(Array(entries.prefix(30)))
    }

    private func run(_ work: @escaping () async throws -> String) {
        appState.reloadAISettings()
        if cloudBlockedBySensitiveBoard() {
            output = "当前板块已标记为禁止云端 AI。"
            return
        }
        if isCloudAISelected, !appState.trustCloudForSession {
            pendingAction = { execute(work) }
            showsCloudConfirm = true
            return
        }
        execute(work)
    }

    private func runStream(_ work: @escaping () async throws -> AsyncThrowingStream<String, Error>) {
        appState.reloadAISettings()
        if cloudBlockedBySensitiveBoard() {
            output = "当前板块已标记为禁止云端 AI。"
            return
        }
        if isCloudAISelected, !appState.trustCloudForSession {
            pendingAction = { executeStream(work) }
            showsCloudConfirm = true
            return
        }
        executeStream(work)
    }

    private func execute(_ work: @escaping () async throws -> String) {
        isRunning = true
        sourceEntryIds = []
        Task {
            do {
                let result = try await work()
                await MainActor.run {
                    output = result
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    output = error.localizedDescription
                    isRunning = false
                }
            }
        }
    }

    private func executeStream(_ work: @escaping () async throws -> AsyncThrowingStream<String, Error>) {
        isRunning = true
        output = ""
        sourceEntryIds = []
        Task {
            do {
                let stream = try await work()
                for try await chunk in stream {
                    await MainActor.run {
                        output += chunk
                    }
                }
                await MainActor.run {
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    output = error.localizedDescription
                    isRunning = false
                }
            }
        }
    }

    private func cloudBlockedBySensitiveBoard() -> Bool {
        guard isCloudAISelected,
              let entry,
              let board = try? appState.boards.board(id: entry.boardId)
        else { return false }
        return board.disallowCloudAI
    }

    private var isCloudAISelected: Bool {
        let provider = UserDefaults.standard.string(forKey: "settings.ai.provider") ?? "zhipu"
        return provider == "zhipu" || provider == "claude"
    }
}
