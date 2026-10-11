import SwiftUI

struct TimelineView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = TimelineViewModel()
    @State private var searchText = ""
    @State private var boards: [Board] = []

    private var displayedSummaries: [EntrySummary] {
        viewModel.isSearching ? viewModel.searchResults : viewModel.summaries
    }

    private var days: [TimelineDay] {
        let items = displayedSummaries
        // day 键固定为 yyyy-MM-dd（DayKey 生成），定宽零填充，字典序即时间序；
        // 不能在比较器里走 DayKey.date（DateFormatter）——每次 SwiftUI 重算 body
        // 都会 O(n log n) 次解析日期，同步进度连发时足以打满主线程。
        return Dictionary(grouping: items, by: \.dayDate)
            .map { TimelineDay(day: $0.key, entries: $0.value) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        // body 内 isEmpty 判断与列表渲染共用同一份 days，避免每帧分组排序两次。
        let days = self.days
        return VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { performSearch() }
                    .onChange(of: searchText) {
                        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            viewModel.clearSearch()
                        }
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        viewModel.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Palette.inspectorSurface)

            // UI-08③：搜索出错时明确报错，不伪装成「还没有日记」
            if viewModel.isSearching, let searchError = viewModel.searchError {
                ContentUnavailableView("搜索失败", systemImage: "exclamationmark.triangle", description: Text(searchError))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if days.isEmpty {
                ContentUnavailableView("还没有日记", systemImage: "text.book.closed", description: Text("按 ⌘N，从今天的一句话开始。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $appState.selectedEntryId) {
                    ForEach(days) { day in
                        Section {
                            ForEach(day.entries) { entry in
                                TimelineEntryRow(entry: entry, board: boards.first { $0.id == entry.boardId }, isSelected: appState.selectedEntryId == entry.id)
                                    .tag(entry.id)
                                    .listRowBackground(appState.selectedEntryId == entry.id ? Palette.timelineSelection : Color.clear)
                            }
                        } header: {
                            HStack {
                                Text(DayKey.date(from: day.day)?.formatted(.dateTime.year().month().day().weekday()) ?? day.day)
                                Spacer()
                                Text("\(day.entries.count) 篇")
                            }
                            .font(.caption)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Palette.inspectorSurface)
        .navigationTitle("时间线")
        .onAppear {
            boards = (try? appState.boards.all()) ?? []
            viewModel.observe(appState: appState)
        }
        .onChange(of: appState.sidebarSelection) {
            searchText = ""
            viewModel.observe(appState: appState)
        }
        .onChange(of: viewModel.summaries) {
            // 板块名称/颜色是时间线行的外部元数据；数据库更新后重新读取，
            // 避免只在首次出现时缓存旧值。
            boards = (try? appState.boards.all()) ?? boards
        }
    }

    private func performSearch() {
        viewModel.search(query: searchText, appState: appState)
    }
}

private struct TimelineEntryRow: View {
    var entry: EntrySummary
    var board: Board?
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: board?.colorHex ?? "#D85A30")).frame(width: 7, height: 7)
                Text(board?.name ?? "日记")
                    .lineLimit(2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if entry.title?.isEmpty == false {
                Text(entry.title!)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Palette.cinnabarDeep : Palette.ink)
                    .lineLimit(2)
                Text(entry.bodyPreview)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(entry.bodyPreview.isEmpty ? "无标题" : String(entry.bodyPreview.prefix(48)))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Palette.cinnabarDeep : Palette.ink)
                    .lineLimit(2)
            }
            HStack {
                Text(entry.journalDate, format: .dateTime.hour().minute())
                Spacer()
                if entry.isFavorite { Image(systemName: "heart.fill") }
                if entry.isDraft { Text("草稿") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
