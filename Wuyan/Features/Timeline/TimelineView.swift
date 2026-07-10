import SwiftUI

struct TimelineView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = TimelineViewModel()
    @State private var searchText = ""

    private var displayedSummaries: [EntrySummary] {
        viewModel.isSearching ? viewModel.searchResults : viewModel.summaries
    }

    private var days: [TimelineDay] {
        let items = displayedSummaries
        return Dictionary(grouping: items, by: \.dayDate)
            .map { TimelineDay(day: $0.key, entries: $0.value) }
            .sorted { $0.sortDate > $1.sortDate }
    }

    var body: some View {
        VStack(spacing: 0) {
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
            .background(.thinMaterial)

            if days.isEmpty {
                ContentUnavailableView("还没有日记", systemImage: "text.book.closed", description: Text("按 ⌘N，从今天的一句话开始。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(days) { day in
                        Button {
                            appState.showBoardChooser(day: day.day)
                        } label: {
                            TimelineDayRow(day: day)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("时间线")
        .onAppear {
            viewModel.observe(appState: appState)
        }
        .onChange(of: appState.sidebarSelection) {
            viewModel.observe(appState: appState)
        }
    }

    private func performSearch() {
        viewModel.search(query: searchText, appState: appState)
    }
}

private struct TimelineDayRow: View {
    var day: TimelineDay

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Palette.cinnabar)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(displayDate)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text("\(day.entries.count) 篇")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label("\(day.boardCount) 个板块", systemImage: "square.grid.2x2")
                    Label("\(day.totalWords) 字", systemImage: "textformat")
                    if day.entries.contains(where: \.isFavorite) {
                        Label("有收藏", systemImage: "heart.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }

    private var displayDate: String {
        guard let date = DayKey.date(from: day.day) else { return day.day }
        return date.formatted(.dateTime.year().month(.wide).day().weekday(.wide))
    }

    private var preview: String {
        guard let entry = day.latestEntry else { return "这一天还没有正文" }
        if let title = entry.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if !entry.bodyPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return entry.bodyPreview
        }
        return "这一天还没有正文"
    }
}
