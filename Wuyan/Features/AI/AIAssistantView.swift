import SwiftUI

/// Compact writing support shown beside the editor. It deliberately exposes
/// only two prompts and one refresh action so the editor remains the primary
/// surface for writing.
struct AIAssistantView: View {
    @EnvironmentObject private var appState: AppState
    var entry: Entry?
    // Kept source-compatible with EditorView's existing injection points. The
    // new design does not insert prompts or apply metadata from this card.
    var insertPrompt: (String) -> Void = { _ in }
    var applyTitle: (String) -> Void = { _ in }
    var applyTags: (String) -> Void = { _ in }

    @StateObject private var request = AIRequestState()
    @StateObject private var consentGate = CloudAIConsentGateModel()
    @State private var board: Board?
    @State private var prompts: [String] = []

    private var identity: String {
        "\(entry?.id.uuidString ?? "")-\(entry?.boardId.uuidString ?? "")-\(entry?.dayDate ?? "")"
    }
    private var isConfigured: Bool {
        appState.aiService.isEnabled && appState.aiService.provider != nil
    }

    var body: some View {
        InspectorCard(title: "", background: Palette.aiSurface, foreground: Palette.aiText) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Label("AI 辅助写作", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if request.isRunning { ProgressView().controlSize(.small) }
                    Button {
                        loadPrompts(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("换一组")
                    .accessibilityLabel("换一组")
                    .disabled(request.isRunning || entry == nil)
                }

                if prompts.count == 2 {
                    ForEach(Array(prompts.enumerated()), id: \.offset) { _, prompt in
                        Text(prompt)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.aiText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 9)
                            .padding(.horizontal, 10)
                            .background(Palette.paper.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if let error = request.error {
                        Text(error.contains("禁止云端 AI") ? error : "换一组失败，保留当前问题")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if request.isRunning {
                    HStack(spacing: 8) {
                        Text("正在准备…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if !isConfigured {
                    Text("连接 AI，获取参考问题")
                        .font(.system(size: 13, weight: .medium))
                    Button("打开 AI 设置") { appState.sidebarSelection = .settings }
                        .font(.system(size: 12))
                        .buttonStyle(.plain)
                } else if appState.aiService.requiresCloudConsent && appState.trustCloudDestination == nil {
                    Text("需要确认云端 AI")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if let error = request.error {
                    Text(error.contains("禁止云端 AI") ? error : "暂时没能生成，稍后再试")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("重试") { loadPrompts(force: true) }
                        .font(.system(size: 12))
                        .buttonStyle(.plain)
                } else {
                    Text("还没有参考问题")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cloudAIConsentAlert(gate: consentGate)
        .task(id: identity) {
            request.reset()
            consentGate.cancel()
            prompts = []
            board = entry.flatMap { try? appState.boards.board(id: $0.boardId) }
            loadPrompts(force: false)
        }
        .onChange(of: appState.selectedEntryId) { _, _ in
            request.reset()
            consentGate.cancel()
        }
        .onDisappear {
            request.cancel()
            consentGate.cancel()
        }
    }

    private func loadPrompts(force: Bool) {
        guard let snapshot = entry else { return }
        appState.reloadAISettings()
        if !force, let cached = try? appState.aiPromptHistory.current(boardId: snapshot.boardId, dayDate: snapshot.dayDate),
           cached.prompts.count == 2 {
            prompts = cached.prompts
            return
        }
        guard isConfigured else {
            request.reset()
            return
        }
        let boardSnapshot = board ?? (try? appState.boards.board(id: snapshot.boardId))
        let action = { [weak appState] in
            guard let appState else { return }
            guard appState.selectedEntryId == snapshot.id else { return }
            request.run(onSuccess: { output in
                guard appState.selectedEntryId == snapshot.id else { throw CancellationError() }
                let generated = output.text.components(separatedBy: "\n")
                _ = try appState.aiPromptHistory.save(boardId: snapshot.boardId, dayDate: snapshot.dayDate, prompts: generated)
                prompts = generated
            }) { @MainActor in
                guard appState.selectedEntryId == snapshot.id else { throw CancellationError() }
                let day = DayKey.date(from: snapshot.dayDate) ?? snapshot.journalDate
                let since = DayKey.calendar.date(byAdding: .day, value: -6, to: day) ?? day
                let recent = try appState.entries.aiEntries(boardId: snapshot.boardId, sinceDay: DayKey.string(from: since), throughDay: snapshot.dayDate)
                let cutoff = DayKey.calendar.date(byAdding: .day, value: -29, to: day) ?? day
                let cutoffKey = DayKey.string(from: cutoff)
                let exactPrevious = try appState.aiPromptHistory.allPrompts(boardId: snapshot.boardId)
                let semanticPrevious = try appState.aiPromptHistory.recentPrompts(boardId: snapshot.boardId, since: cutoffKey, through: snapshot.dayDate)
                let context = WritingContext(
                    date: day,
                    weather: snapshot.weather,
                    recentEntries: recent,
                    boardName: boardSnapshot?.name,
                    boardKind: boardSnapshot?.kind,
                    boardId: snapshot.boardId,
                    boardTheme: boardSnapshot?.recordingTheme,
                    annualAge: boardSnapshot?.ageText(in: AppState.year(fromDayKey: snapshot.dayDate)),
                    draft: snapshot,
                    mood: snapshot.mood
                )
                let generated = try await appState.aiService.generateWritingPrompts(context: context, excluding: exactPrevious, semanticExcluding: semanticPrevious)
                guard generated.count == 2 else { throw AIError.providerError("暂时没能生成两条合适的问题，请稍后再试。") }
                guard appState.selectedEntryId == snapshot.id else { throw CancellationError() }
                return AIRequestOutput(text: generated.joined(separator: "\n"))
            }
        }
        if appState.aiService.requiresCloudConsent, boardSnapshot?.disallowCloudAI == true {
            action()
        } else {
            consentGate.gate(
                appState: appState,
                scope: "当前板块近 7 天的记录、当前草稿、板块主题及已展示的参考问题。",
                action: action
            )
        }
    }
}
