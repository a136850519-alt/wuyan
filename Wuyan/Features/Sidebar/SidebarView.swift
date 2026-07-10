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

    var body: some View {
        List(selection: $appState.sidebarSelection) {
            Section {
                Label("全部", systemImage: "tray.full")
                    .tag(SidebarSelection.all)
                Label("收藏", systemImage: "heart")
                    .tag(SidebarSelection.favorites)
                Label("草稿", systemImage: "doc.text")
                    .tag(SidebarSelection.drafts)
                Label("历史上的今天", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarSelection.todayInHistory)
                Label("日历", systemImage: "calendar")
                    .tag(SidebarSelection.calendar)
                Label("回收站", systemImage: "trash")
                    .tag(SidebarSelection.trash)
            }

            Section("年份") {
                ForEach(years, id: \.self) { year in
                    HStack {
                        Label(String(year), systemImage: "calendar")
                        Spacer()
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
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingArchiveYear = year
                        } label: {
                            Label("归档到 NAS（删除本地）", systemImage: "archivebox")
                        }
                        Button {
                            appState.downloadYearFromRemote(year)
                        } label: {
                            Label("下载本年内容", systemImage: "arrow.down.circle")
                        }
                    }

                    if expandedYears.contains(year) {
                        ForEach(boards) { board in
                            BoardRow(board: board)
                                .padding(.leading, 18)
                                .tag(SidebarSelection.yearBoard(year, board.id))
                                .contextMenu {
                                    Button("重命名与设置") {
                                        editingBoard = board
                                    }
                                    Button("删除板块") {
                                        delete(board)
                                    }
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
                    Text("连续 \(StreakTracker(summaries: entries).currentStreak()) 天")
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
        .sheet(isPresented: $isAddingBoard, onDismiss: reloadBoards) {
            BoardEditorSheet(board: nil)
                .environmentObject(appState)
        }
        .sheet(item: $editingBoard, onDismiss: reloadBoards) { board in
            BoardEditorSheet(board: board)
                .environmentObject(appState)
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
        do {
            try appState.boards.delete(id: board.id)
            if appState.sidebarSelection.boardId == board.id {
                appState.sidebarSelection = .all
            }
            reloadBoards()
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }
}

private struct BoardRow: View {
    var board: Board

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: board.colorHex))
                .frame(width: 8, height: 8)
            Label(board.name, systemImage: board.iconName)
                .labelStyle(.titleAndIcon)
            if let age = board.ageText() {
                Text(age)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.babyPink)
                    .foregroundStyle(Palette.babyPinkText)
                    .clipShape(Capsule())
            }
        }
    }
}

private struct BoardEditorSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var colorHex: String
    @State private var iconName: String
    @State private var kind: BoardKind
    @State private var babyBirthday: Date
    @State private var disallowCloudAI: Bool

    private var board: Board?

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

    init(board: Board?) {
        self.board = board
        _name = State(initialValue: board?.name ?? "")
        _colorHex = State(initialValue: board?.colorHex ?? "#D85A30")
        _iconName = State(initialValue: board?.iconName ?? "book")
        _kind = State(initialValue: board?.kind ?? .freeform)
        _babyBirthday = State(initialValue: board?.babyBirthday ?? Date())
        _disallowCloudAI = State(initialValue: board?.disallowCloudAI ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(board == nil ? "新建板块" : "板块设置")
                .font(.title2.weight(.semibold))

            TextField("名称", text: $name)

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
        .frame(width: 420)
    }

    private func save() {
        do {
            let sortOrder = (try? appState.boards.all().count) ?? 0
            let updated = Board(
                id: board?.id ?? UUID(),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                colorHex: colorHex,
                iconName: iconName,
                kind: kind,
                babyBirthday: kind == .growth ? babyBirthday : nil,
                disallowCloudAI: disallowCloudAI,
                sortOrder: board?.sortOrder ?? sortOrder,
                createdAt: board?.createdAt ?? Date()
            )
            try appState.boards.save(updated)
            dismiss()
        } catch {
            appState.errorMessage = error.localizedDescription
        }
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
