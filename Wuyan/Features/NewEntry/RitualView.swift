import SwiftUI

struct RitualView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = RitualViewModel()
    /// R2-2: 共享云端 AI 授权门控
    @State private var generationTask: Task<Void, Never>?
    @StateObject private var consentGate = CloudAIConsentGateModel()

    var body: some View {
        ScrollView {
          VStack {
            HStack {
                Spacer()
                Button { generationTask?.cancel(); viewModel.close(); dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("关闭新建日记")
            }
            if let error = viewModel.errorMessage {
                Text(error).font(.callout).foregroundStyle(Palette.cinnabarDeep)
            }
            switch viewModel.step {
            case .summary:
                summaryStep
                    .transition(.opacity)
            case .board:
                boardStep
                    .transition(.opacity)
            }
        }
          .padding(32)
        }
        .frame(width: 600, height: 650)
        .background(Palette.paper)
        .task {
            await viewModel.prepare(appState: appState)
        }
        // R2-2: 使用共享云端 AI 授权门控，替代本视图内重复的 showsCloudConfirm alert
        .cloudAIConsentAlert(gate: consentGate)
        .onDisappear { generationTask?.cancel(); consentGate.cancel(); viewModel.close() }
        .onExitCommand { generationTask?.cancel(); viewModel.close(); dismiss() }
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("今天的第一笔")
                    .font(WuyanFont.title(30))
                Text("先用一句话记下今天")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !viewModel.showsPoeticLine {
                TextEditor(text: $viewModel.rawSummary)
                    .font(WuyanFont.body(21))
                    .lineSpacing(8)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.035))
                            .stroke(Palette.hairline)
                    )
                    .frame(height: 155)
                    .disabled(viewModel.isGenerating)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(viewModel.poeticSegments.enumerated()), id: \.offset) { index, segment in
                        Text(segment)
                            .font(WuyanFont.title(26))
                            .foregroundStyle(Palette.cinnabarDeep)
                            .opacity(index < viewModel.visiblePoeticSegmentCount ? 1 : 0)
                            .offset(y: index < viewModel.visiblePoeticSegmentCount ? 0 : 9)
                            .animation(WuyanMotion.ease, value: viewModel.visiblePoeticSegmentCount)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 190, alignment: .center)
                .transition(.opacity)
            }

            if !viewModel.showsPoeticLine {
                InspectorCard(title: "今天的心情", background: Palette.moodSurface, foreground: Palette.moodText) {
                    MoodChoices(selection: $viewModel.mood, emojiSize: 35).disabled(viewModel.isGenerating)
                    Text(Mood.from(viewModel.mood).map { "已选：\($0.label)" } ?? "可以不选，之后在右栏补选")
                        .font(.system(size: 12))
                }
                Text("一句话和心情属于这一天，各个板块会共用。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            } else {
                Text(Mood.from(viewModel.mood).map { "\($0.emoji) \($0.label) · 今日心情" } ?? "今日心情 · 尚未记录")
                    .font(.callout).foregroundStyle(Palette.moodText)
            }

            Spacer()

            HStack {
                Button(viewModel.showsPoeticLine ? "返回修改" : "跳过润色") {
                    if viewModel.showsPoeticLine { viewModel.showsPoeticLine = false }
                    else { generationTask = Task { await viewModel.skip(appState: appState) } }
                }
                .buttonStyle(WuyanSecondaryButtonStyle())
                .disabled(viewModel.isGenerating)

                Spacer()

                if viewModel.showsPoeticLine {
                    Button("换一句") {
                        appState.reloadAISettings()
                        consentGate.gate(appState: appState, scope: "今天的一句话，仅用于润色。") {
                            generationTask = Task { await viewModel.generate(appState: appState) }
                        }
                    }
                    .buttonStyle(WuyanSecondaryButtonStyle())
                    .disabled(viewModel.isGenerating)
                    Button("下一步") {
                        withAnimation(WuyanMotion.ease) {
                            viewModel.nextToBoards()
                        }
                    }
                    .buttonStyle(WuyanPrimaryButtonStyle())
                    .disabled(viewModel.isGenerating)
                } else {
                    Button {
                        // R2-2: 使用共享门控替代 isCloudAISelected 字符串白名单
                        appState.reloadAISettings()
                        consentGate.gate(appState: appState, scope: "今天的一句话，仅用于润色。") {
                            generationTask = Task { await viewModel.generate(appState: appState) }
                        }
                    } label: {
                        Label(viewModel.isGenerating ? "生成中" : "落笔成句", systemImage: "sparkles")
                    }
                    .buttonStyle(WuyanPrimaryButtonStyle())
                    .disabled(viewModel.isGenerating)
                }
            }
        }
    }

    private var boardStep: some View {
        VStack(spacing: 18) {
            if let note = viewModel.dayNote {
                VStack(spacing: 8) {
                    Text(note.poeticLine.isEmpty ? note.rawSummary : note.poeticLine)
                        .font(WuyanFont.body(18))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Text("选一个板块，把这一笔安放进去")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 8)
            }

            Spacer(minLength: 10)

            VStack(spacing: 14) {
                ForEach(Array(viewModel.boards.enumerated()), id: \.element.id) { index, board in
                    BoardChoiceButton(board: board) {
                        viewModel.createEntry(board: board, appState: appState)
                    }
                    .opacity(index < viewModel.visibleBoardCount ? 1 : 0)
                    .offset(y: index < viewModel.visibleBoardCount ? 0 : 16)
                    .animation(.easeOut(duration: 0.65), value: viewModel.visibleBoardCount)
                }
            }

            Spacer()

            HStack {
                Button("上一步") {
                    withAnimation(WuyanMotion.ease) {
                        viewModel.step = .summary
                        viewModel.showsPoeticLine = false
                    }
                }
                .buttonStyle(WuyanSecondaryButtonStyle())
                Button("+ 新建板块") {
                    appState.errorMessage = "请先在左侧边栏的“新建板块”中创建板块。"
                }
                .buttonStyle(WuyanSecondaryButtonStyle())
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(WuyanSecondaryButtonStyle())
            }
        }
    }
}

private struct BoardChoiceButton: View {
    var board: Board
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: board.iconName)
                Text(board.name)
                    .font(WuyanFont.body(21))
                Spacer()
            }
        }
        .buttonStyle(WuyanBoardKeyButtonStyle(hovering: hover))
        .onHover { hover = $0 }
    }
}
