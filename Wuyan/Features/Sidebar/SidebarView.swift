import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var boards: [Board] = []
    @State private var entries: [EntrySummary] = []
    @State private var isAddingBoard = false
    @State private var editingBoard: Board?
    @State private var pendingArchiveYear: Int?
    @State private var isArchivedExpanded = true
    @State private var expandedYears: Set<Int> = []
    @State private var yearThemeSheetYear: Int?
    // 连续天数在 reloadEntries 时算好缓存：body 每帧都算会对全部条目
    // 逐条解析日期，同步进度连发时足以打满主线程（与 TimelineView 同款问题）。
    @State private var streakCount = 0

    var body: some View {
        List(selection: $appState.sidebarSelection) {
            Section {
                Self.navigationRow("全部", systemImage: "tray.full", color: Self.navigationColor(.all))
                    .tag(SidebarSelection.all)
                Self.navigationRow("收藏", systemImage: "heart", color: Self.navigationColor(.favorites))
                    .tag(SidebarSelection.favorites)
                Self.navigationRow("草稿", systemImage: "doc.text", color: Self.navigationColor(.drafts))
                    .tag(SidebarSelection.drafts)
                Self.navigationRow("历史上的今天", systemImage: "clock.arrow.circlepath", color: Self.navigationColor(.todayInHistory))
                    .tag(SidebarSelection.todayInHistory)
                Self.navigationRow("日历", systemImage: "calendar", color: Self.navigationColor(.calendar))
                    .tag(SidebarSelection.calendar)
                Self.navigationRow("回收站", systemImage: "trash", color: Self.navigationColor(.trash))
                    .tag(SidebarSelection.trash)
            }

            Section("年份") {
                ForEach(years, id: \.self) { year in
                    HStack {
                        Label(String(year), systemImage: "calendar")
                            .foregroundStyle(AppSettings.yearTheme(year).theme.color)
                        Spacer()
                        Button {
                            yearThemeSheetYear = year
                        } label: {
                            Circle()
                                .fill(AppSettings.yearTheme(year).theme.color)
                                .frame(width: 10, height: 10)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("设置 \(year) 年主题色")
                        Button {
                            toggleYear(year)
                        } label: {
                            Image(systemName: expandedYears.contains(year) ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .tag(SidebarSelection.year(year))
                    .listRowBackground(
                        appState.sidebarSelection == .year(year)
                            ? AppSettings.yearTheme(year).theme.softColor
                            : Color.clear
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingArchiveYear = year
                        } label: {
                            Label("归档到 NAS（删除本地）", systemImage: "archivebox")
                        }
                        .disabled(year == AppState.year(fromDayKey: DayKey.today))
                    }

                    if expandedYears.contains(year) {
                        ForEach(boards) { board in
                            BoardRow(board: board, year: year) { editingBoard = board }
                                .padding(.leading, 18)
                                .tag(SidebarSelection.yearBoard(year, board.id))
                                .contextMenu {
                                    Button("重命名与设置") {
                                        editingBoard = board
                                    }
                                    Button("删除板块") {
                                        delete(board)
                                    }
                                    .disabled(Board.builtIn.contains { $0.id == board.id })
                                }
                        }
                    }
                }
                Button {
                    isAddingBoard = true
                } label: {
                    Label("新建板块", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }

            Section {
                DisclosureGroup(isExpanded: $isArchivedExpanded) {
                    if appState.archivedYears.isEmpty {
                        Text("暂无归档。在年份上右键「归档到 NAS」可把整年移到 NAS 并腾出本地空间。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.archivedYears, id: \.self) { year in
                            HStack(spacing: 8) {
                                Label("\(String(year)) 年", systemImage: "archivebox.fill")
                                    .labelStyle(.titleAndIcon)
                                Spacer()
                                Button {
                                    appState.downloadYearFromRemote(year)
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                }
                                .buttonStyle(.plain)
                                .help("下载回本地")
                            }
                            .contextMenu {
                                Button {
                                    appState.downloadYearFromRemote(year)
                                } label: {
                                    Label("下载回本地", systemImage: "arrow.down.circle")
                                }
                            }
                        }
                    }
                } label: {
                    Label("已归档", systemImage: "archivebox")
                }
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(Palette.cinnabar)
                    Text("连续 \(streakCount) 天")
                    Spacer()
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .tag(SidebarSelection.settings)
                if !appState.archivedYears.isEmpty {
                    Text("不含已归档年份")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .foregroundStyle(Palette.ink)
        .tint(Palette.cinnabar)
        .scrollContentBackground(.hidden)
        .background(Palette.sidebarPaper)
        .navigationTitle("晤言")
        .toolbar {
            ToolbarItem {
                Button {
                    appState.showNewEntryRitual()
                } label: {
                    Label("新建日记", systemImage: "square.and.pencil")
                }
            }
        }
        .task {
            reloadBoards()
            reloadEntries()
        }
        .task {
            for await summaries in appState.entries.observeTimelineSummaries(filter: .all) {
                entries = summaries
                streakCount = StreakTracker(summaries: summaries).currentStreak()
            }
        }
        .sheet(isPresented: $isAddingBoard, onDismiss: reloadBoards) {
            BoardEditorSheet(board: nil) { board in
                appState.selectedBoardId = board.id
            }
                .environmentObject(appState)
        }
        .sheet(item: $editingBoard, onDismiss: reloadBoards) { board in
            BoardEditorSheet(board: board)
                .environmentObject(appState)
        }
        .sheet(isPresented: Binding(
            get: { yearThemeSheetYear != nil },
            set: { if !$0 { yearThemeSheetYear = nil } }
        )) {
            if let year = yearThemeSheetYear {
                YearThemePicker(year: year) {
                    yearThemeSheetYear = nil
                }
            }
        }
        .confirmationDialog(
            pendingArchiveYear.map { "归档 \($0) 年到 NAS？" } ?? "归档到 NAS？",
            isPresented: Binding(
                get: { pendingArchiveYear != nil },
                set: { if !$0 { pendingArchiveYear = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("归档并删除本地内容", role: .destructive) {
                if let year = pendingArchiveYear {
                    appState.archiveYearToRemote(year)
                }
                pendingArchiveYear = nil
            }
            Button("取消", role: .cancel) { pendingArchiveYear = nil }
        } message: {
            Text("会先把该年的日记、日札和附件全部上传到 NAS，确认无误后删除本地正文与附件以腾出空间。之后可在「已归档」里随时下载回本地。")
        }
        .onChange(of: appState.archivedYears) {
            reloadEntries()
        }
    }

    private func reloadBoards() {
        do {
            boards = try appState.boards.all()
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func reloadEntries() {
        entries = (try? appState.entries.timelineSummaries(filter: .all)) ?? []
        streakCount = StreakTracker(summaries: entries).currentStreak()
        if expandedYears.isEmpty, let first = years.first {
            expandedYears.insert(first)
        }
    }

    private var years: [Int] {
        let entryYears = Set(entries.map { AppState.year(fromDayKey: $0.dayDate) })
        if entryYears.isEmpty {
            return [AppState.year(fromDayKey: DayKey.today)]
        }
        return entryYears.sorted(by: >)
    }

    private func toggleYear(_ year: Int) {
        if expandedYears.contains(year) {
            expandedYears.remove(year)
        } else {
            expandedYears.insert(year)
        }
    }

    private func delete(_ board: Board) {
        guard !appState.isRescueMode else {
            appState.errorMessage = "救援模式：板块修改已禁用。"
            return
        }
        appState.deleteBoard(boardId: board.id)
        if appState.sidebarSelection.boardId == board.id {
            appState.sidebarSelection = .all
        }
        reloadBoards()
    }

    private static func navigationColor(_ selection: SidebarSelection) -> Color {
        switch selection {
        case .all: return Palette.adaptive(light: "#6288A4", dark: "#9DBBD0")
        case .favorites: return Palette.adaptive(light: "#B96E83", dark: "#E5A3B7")
        case .drafts: return Palette.adaptive(light: "#A17B3C", dark: "#DFBF7D")
        case .todayInHistory: return Palette.adaptive(light: "#8C75A6", dark: "#BEA9DA")
        case .calendar: return Palette.adaptive(light: "#508D82", dark: "#92C6BB")
        case .trash: return Palette.adaptive(light: "#9A7564", dark: "#D5B09A")
        default: return Palette.ink
        }
    }

    private static func navigationRow(_ title: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(title).foregroundStyle(Palette.ink)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
    }
}

private extension String {
    var theme: YearTheme { YearTheme(rawValue: self) ?? .default }
}

private struct YearThemePicker: View {
    let year: Int
    let onClose: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: YearTheme

    init(year: Int, onClose: @escaping () -> Void) {
        self.year = year
        self.onClose = onClose
        _draft = State(initialValue: AppSettings.yearTheme(year).theme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设置 \(year) 年主题色")
                .font(.title3.weight(.semibold))
            Text("只影响该年份的侧栏强调色与选中状态。")
                .font(.callout)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10)], spacing: 10) {
                ForEach(YearTheme.allCases) { theme in
                    Button {
                        draft = theme
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(theme.color).frame(width: 20, height: 20)
                            Text(theme.displayName)
                            Spacer()
                            if draft == theme { Image(systemName: "checkmark") }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.softColor)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(draft == theme ? theme.color : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.displayName)
                }
            }

            HStack {
                Circle().fill(draft.color).frame(width: 10, height: 10)
                Text("\(year) 年预览")
                    .foregroundStyle(draft.color)
                Spacer()
            }
            .padding(12)
            .background(Palette.sidebarPaper)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("恢复默认") { draft = .default }
                Spacer()
                Button("取消") {
                    onClose(); dismiss()
                }
                Button("应用") {
                    AppSettings.setYearTheme(draft.rawValue, for: year)
                    onClose(); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(draft.color)
            }
        }
        .padding(28)
        .frame(width: 496)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand {
            onClose(); dismiss()
        }
    }
}

private struct BoardRow: View {
    var board: Board
    var year: Int
    var editBirthday: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: board.colorHex))
                .frame(width: 8, height: 8)
            Text(board.name)
                .font(.system(size: 12))
                .lineLimit(2)
            if let age = board.ageText(in: year) {
                Text(age)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.babyPink)
                    .foregroundStyle(Palette.babyPinkText)
                    .clipShape(Capsule())
            } else if board.kind == .growth {
                Button("设置生日", action: editBirthday)
                    .font(.caption2).buttonStyle(.borderless)
            }
        }
    }
}

struct BoardEditorSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var colorHex: String
    @State private var iconName: String
    @State private var kind: BoardKind
    @State private var recordingTheme: String
    @State private var babyBirthday: Date
    @State private var disallowCloudAI: Bool
    @State private var validationMessage: String?
    @State private var nameSuggestions: [String] = []

    private var board: Board?
    private var onSaved: (Board) -> Void

    private let symbolCandidates = [
        "book", "book.fill", "heart.fill", "star.fill", "leaf.fill",
        "sun.max.fill", "moon.fill", "cloud.fill", "drop.fill", "flame.fill",
        "music.note", "paintbrush.fill", "camera.fill", "gift.fill", "graduationcap.fill",
        "airplane", "bicycle", "car.fill", "flag.fill", "bell.fill",
    ]

    private let colorPresets = [
        "#D85A30", "#E8A838", "#4CAF50", "#2196F3", "#9C27B0",
        "#F44336", "#009688", "#FF9800", "#607D8B", "#795548",
    ]

    init(board: Board?, onSaved: @escaping (Board) -> Void = { _ in }) {
        self.board = board
        self.onSaved = onSaved
        _name = State(initialValue: board?.name ?? "")
        _colorHex = State(initialValue: board?.colorHex ?? "#D85A30")
        _iconName = State(initialValue: board?.iconName ?? "book")
        _kind = State(initialValue: board?.kind ?? .freeform)
        _recordingTheme = State(initialValue: board?.recordingTheme ?? "")
        _babyBirthday = State(initialValue: board?.babyBirthday ?? Date())
        _disallowCloudAI = State(initialValue: board?.disallowCloudAI ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            Text(board == nil ? "新建板块" : "板块设置")
                .font(.title2.weight(.semibold))

            TextField("名称", text: $name)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("记录主题（选填）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("帮我起名") { suggestNames() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.cinnabar)
                        .disabled(recordingTheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                TextField("例如：周末散步时遇到的小店、街道与见闻", text: $recordingTheme, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                if !nameSuggestions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(nameSuggestions, id: \.self) { suggestion in
                            Button(suggestion) { name = suggestion }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("图标")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(symbolCandidates, id: \.self) { symbol in
                        Button {
                            iconName = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.title3)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(iconName == symbol ? Palette.cinnabar.opacity(0.18) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(iconName == symbol ? Palette.cinnabar : Palette.hairline, lineWidth: iconName == symbol ? 1.5 : 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(iconName == symbol ? Palette.cinnabarDeep : .primary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("颜色")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(colorPresets, id: \.self) { hex in
                        Button {
                            colorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle()
                                        .stroke(colorHex == hex ? Palette.cinnabarDeep : Color.clear, lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: colorHex) },
                        set: { colorHex = $0.toHex() ?? colorHex }
                    ), supportsOpacity: false)
                        .labelsHidden()
                }
            }

            Picker("类型", selection: $kind) {
                Text("五年").tag(BoardKind.fiveYear)
                Text("日常唠叨").tag(BoardKind.freeform)
                Text("宝贝成长记录").tag(BoardKind.growth)
            }
            .pickerStyle(.segmented)

            if kind == .growth {
                DatePicker("宝贝生日", selection: $babyBirthday, displayedComponents: .date)
            }

            Toggle("禁止云端 AI", isOn: $disallowCloudAI)
                .tint(Palette.cinnabar)

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

                HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.cinnabar)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
        }
        .frame(width: 420)
        .frame(maxHeight: 620)
    }

    private func save() {
        guard !appState.isRescueMode else {
            appState.errorMessage = "救援模式：板块修改已禁用。"
            return
        }
        do {
            let sortOrder = (try? appState.boards.all().count) ?? 0
            let updated = Board(
                id: board?.id ?? UUID(),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                colorHex: colorHex,
                iconName: iconName,
                kind: kind,
                recordingTheme: recordingTheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : recordingTheme.trimmingCharacters(in: .whitespacesAndNewlines),
                babyBirthday: kind == .growth ? babyBirthday : nil,
                disallowCloudAI: disallowCloudAI,
                sortOrder: board?.sortOrder ?? sortOrder,
                createdAt: board?.createdAt ?? Date()
            )
            try appState.boards.save(updated)
            // A privacy toggle must take effect for AI requests in the same session.
            appState.reloadAISettings()
            appState.syncCoordinator.notifyEditCompleted()
            onSaved(updated)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func suggestNames() {
        let theme = recordingTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !theme.isEmpty else { return }
        nameSuggestions = BoardSuggestion.localNames(theme: theme, kind: kind)
    }
}

extension Color {
    func toHex() -> String? {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int(nsColor.redComponent * 255)
        let g = Int(nsColor.greenComponent * 255)
        let b = Int(nsColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
