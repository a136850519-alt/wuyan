import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var isPresented: Bool
    @State private var step = 0
    @State private var selectedPreferences: Set<RecordingPreference> = []
    @State private var freeDescription = ""
    @State private var recommendations: [BoardSuggestion] = []
    @State private var boards: [Board] = []
    @State private var selectedBoardID: UUID?
    @State private var validationMessage: String?
    @State private var showsManualBoard = false

    var body: some View {
        VStack(spacing: 0) {
            progressHeader
            Group {
                if step == 0 { preferenceStep }
                else if step == 1 { boardStep }
                else { writingStep }
            }
            .frame(width: 620, height: 435)

            HStack(spacing: 12) {
                Button("稍后") { finishWithoutWriting() }
                    .buttonStyle(WuyanSecondaryButtonStyle())
                Spacer()
                if step > 0 {
                    Button("上一步") { withAnimation(WuyanMotion.ease) { step -= 1 } }
                        .buttonStyle(WuyanSecondaryButtonStyle())
                }
                if step == 0 {
                    Button("推荐板块") { moveToRecommendations() }
                        .buttonStyle(WuyanPrimaryButtonStyle())
                } else if step == 1 {
                    Button("创建并继续") { createAndContinue() }
                        .buttonStyle(WuyanPrimaryButtonStyle())
                } else {
                    Button("开始写第一篇") { startWriting() }
                        .buttonStyle(WuyanPrimaryButtonStyle())
                        .disabled(selectedBoardID == nil)
                }
            }
            .padding(24)
        }
        .background(Palette.paper)
        .task { reloadBoards() }
        .sheet(isPresented: $showsManualBoard, onDismiss: reloadBoards) {
            BoardEditorSheet(board: nil) { board in
                reloadBoards()
                selectedBoardID = board.id
                step = 2
            }
            .environmentObject(appState)
        }
    }

    private var progressHeader: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Palette.cinnabar : Palette.cinnabar.opacity(0.18))
                    .frame(height: 4)
            }
            Text("第 \(step + 1) 步，共 3 步")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 44)
        .padding(.top, 22)
    }

    private var preferenceStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("你想把什么留下来？").font(WuyanFont.title(30))
            Text("选几个你愿意常常记录的方向，晤言会先给出本地推荐。之后仍可在设置和侧栏里修改。")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(RecordingPreference.allCases) { preference in
                    let selected = selectedPreferences.contains(preference)
                    Button {
                        if selected { selectedPreferences.remove(preference) }
                        else { selectedPreferences.insert(preference) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: preference.icon)
                            Text(preference.rawValue)
                            Spacer()
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        }
                        .padding(11)
                        .foregroundStyle(selected ? Palette.cinnabarDeep : Palette.ink)
                        .background(selected ? Palette.cinnabar.opacity(0.12) : Palette.inspectorSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            TextField("还想记录什么？（选填）", text: $freeDescription, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Text("自动采集位置与天气默认开启时，会把约 3 公里精度的位置发送给 Apple 地理编码和 Open-Meteo。可在设置关闭。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("自己创建板块") { showsManualBoard = true }
                    .buttonStyle(WuyanSecondaryButtonStyle())
                Button("跳过偏好") { skipPreferences() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(44)
    }

    private var boardStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("先从这几个板块开始").font(WuyanFont.title(30))
            Text("名称可以直接修改；记录主题会保留下来，帮助日后的写作建议更贴近你的意图。最多选择 3 个。")
                .foregroundStyle(.secondary)
            if recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ContentUnavailableView("还没有推荐板块", systemImage: "square.stack", description: Text("可以返回上一步选择偏好，或直接使用已有板块。"))
                    Button("使用已有板块") { reloadBoards(); step = 2 }
                        .buttonStyle(WuyanSecondaryButtonStyle())
                }
            } else {
                ForEach($recommendations) { $item in
                    HStack(alignment: .top, spacing: 10) {
                        Button { item.selected.toggle() } label: {
                            Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.selected ? Palette.cinnabar : .secondary)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 5) {
                            TextField("板块名称", text: $item.name)
                                .textFieldStyle(.roundedBorder)
                            Text(item.theme)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Image(systemName: item.preference.icon)
                            .foregroundStyle(Color(hex: item.preference.color))
                            .padding(.top, 6)
                    }
                }
                HStack {
                    Button("换些名字") { rotateRecommendationNames() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.cinnabar)
                    Spacer()
                    Button("使用已有板块") { reloadBoards(); step = 2 }
                        .buttonStyle(.plain)
                }
            }
            if let validationMessage {
                Text(validationMessage).font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(44)
    }

    private var writingStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("从哪一本开始？").font(WuyanFont.title(30))
            Text("选择第一篇日记所属板块。只有一个板块时会自动选中。")
                .foregroundStyle(.secondary)
            if boards.isEmpty {
                Text("还没有板块。可以返回上一步推荐，或自己创建一个。")
                    .foregroundStyle(.secondary)
                Button("自己创建板块") { showsManualBoard = true }
                    .buttonStyle(WuyanSecondaryButtonStyle())
            } else {
                ForEach(boards) { board in
                    Button { selectedBoardID = board.id } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedBoardID == board.id ? "largecircle.fill.circle" : "circle")
                            Circle().fill(Color(hex: board.colorHex)).frame(width: 9, height: 9)
                            Text(board.name)
                            Spacer()
                            if let theme = board.recordingTheme, !theme.isEmpty {
                                Text(theme).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 5)
                }
            }
            Text("日记会先保存在本机；NAS 同步可以稍后在设置中配置。位置、天气等权限仍可在设置中按需关闭。")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(44)
        .onAppear { selectOnlyBoardIfNeeded() }
    }

    private func reloadBoards() {
        boards = (try? appState.boards.all()) ?? []
        selectOnlyBoardIfNeeded()
    }

    private func selectOnlyBoardIfNeeded() {
        if selectedBoardID == nil, boards.count == 1 { selectedBoardID = boards[0].id }
    }

    private func moveToRecommendations() {
        validationMessage = nil
        recommendations = BoardSuggestion.recommendations(preferences: selectedPreferences, description: freeDescription)
        withAnimation(WuyanMotion.ease) { step = 1 }
    }

    private func skipPreferences() {
        validationMessage = nil
        reloadBoards()
        withAnimation(WuyanMotion.ease) { step = 2 }
    }

    private func rotateRecommendationNames() {
        for index in recommendations.indices { recommendations[index].rotateName() }
    }

    private func createAndContinue() {
        validationMessage = nil
        let chosen = recommendations.filter(\.selected)
        guard !chosen.isEmpty else {
            validationMessage = "至少选择一个板块，或返回使用已有板块。"
            return
        }
        guard chosen.count <= 3 else { validationMessage = "最多选择 3 个板块。"; return }
        let names = chosen.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard names.allSatisfy({ !$0.isEmpty }) else { validationMessage = "板块名称不能为空。"; return }
        guard Set(names.map(\.localizedLowercased)).count == names.count else {
            validationMessage = "推荐板块不能重名。"
            return
        }
        do {
            let existing = try appState.boards.all()
            var toCreate: [Board] = []
            for (offset, item) in chosen.enumerated() {
                let name = names[offset]
                if let found = existing.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                    if Board.builtIn.contains(where: { $0.id == found.id }) { continue }
                    throw BoardError.duplicateName
                }
                toCreate.append(Board(name: name, colorHex: item.preference.color, iconName: item.preference.icon,
                                      kind: item.preference.kind, recordingTheme: item.theme,
                                      sortOrder: existing.count + offset))
            }
            try appState.boards.saveMany(toCreate)
            appState.syncCoordinator.notifyEditCompleted()
            reloadBoards()
            selectedBoardID = boards.first(where: { names.contains($0.name.trimmingCharacters(in: .whitespacesAndNewlines)) })?.id ?? boards.first?.id
            withAnimation(WuyanMotion.ease) { step = 2 }
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func startWriting() {
        guard let id = selectedBoardID, let board = boards.first(where: { $0.id == id }) else { return }
        guard appState.startFirstEntry(board: board) else { return }
        AppSettings.setOnboardingCompleted(true)
        isPresented = false
    }

    private func finishWithoutWriting() {
        AppSettings.setOnboardingCompleted(true)
        isPresented = false
    }
}

private extension String {
    var localizedLowercased: String { localizedLowercase }
}
