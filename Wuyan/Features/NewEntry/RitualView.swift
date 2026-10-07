import SwiftUI

struct RitualView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = RitualViewModel()
    /// R2-2: 共享云端 AI 授权门控
    @StateObject private var consentGate = CloudAIConsentGateModel()

    var body: some View {
        VStack {
            switch viewModel.step {
            case .summary:
                summaryStep
                    .transition(.opacity)
            case .board:
                boardStep
                    .transition(.opacity)
            }
        }
        .padding(38)
        .frame(width: 600, height: 560)
        .background(Palette.paper)
        .task {
            await viewModel.prepare(appState: appState)
        }
        // R2-2: 使用共享云端 AI 授权门控，替代本视图内重复的 showsCloudConfirm alert
        .cloudAIConsentAlert(gate: consentGate)
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
                    .frame(height: 190)
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

            Spacer()

            HStack {
                Button("跳过") {
                    Task { await viewModel.skip(appState: appState) }
                }
                .buttonStyle(WuyanSecondaryButtonStyle())
                .disabled(viewModel.isGenerating)

                Spacer()

                if viewModel.showsPoeticLine {
                    Button("换一句") {
                        consentGate.gate(appState: appState) {
                            Task { await viewModel.generate(appState: appState) }
                        }
                    }
                    .buttonStyle(WuyanSecondaryButtonStyle())
                    Button("下一步") {
                        withAnimation(WuyanMotion.ease) {
                            viewModel.nextToBoards()
                        }
                    }
                    .buttonStyle(WuyanPrimaryButtonStyle())
                } else {
                    Button {
                        // R2-2: 使用共享门控替代 isCloudAISelected 字符串白名单
                        consentGate.gate(appState: appState) {
                            Task { await viewModel.generate(appState: appState) }
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
