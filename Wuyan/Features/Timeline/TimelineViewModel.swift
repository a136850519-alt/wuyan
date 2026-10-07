import Foundation

@MainActor
final class TimelineViewModel: ObservableObject {
    @Published var summaries: [EntrySummary] = []
    @Published var searchResults: [EntrySummary] = []
    @Published var isSearching = false
    /// UI-08③：搜索失败原因。nil 表示正常；非 nil 时界面显示错误而非「无结果」。
    @Published var searchError: String?

    private var observationTask: Task<Void, Never>?

    deinit {
        observationTask?.cancel()
    }

    func observe(appState: AppState) {
        observationTask?.cancel()
        let filter: TimelineFilter
        switch appState.sidebarSelection {
        case .all:
            filter = .all
        case .favorites:
            filter = .favorites
        case .drafts:
            filter = .drafts
        case .todayInHistory:
            filter = .todayInHistory
        case let .board(id):
            filter = .board(id)
        case let .year(year):
            filter = .year(year)
        case let .yearBoard(year, boardId):
            // UI-08②（已确认）：「某年 + 某板块」严格过滤该板块该年份，
            // 不再错误地把板块条件丢掉显示全年。
            filter = .yearBoard(year, boardId)
        case .calendar, .settings, .trash:
            filter = .all
        }

        observationTask = Task {
            // The first emission follows an explicit filter change and should
            // establish a selection in the new result set. Later emissions
            // are database updates and must preserve the user's current row.
            var isFirstEmission = true
            for await newSummaries in appState.entries.observeTimelineSummaries(filter: filter) {
                self.summaries = newSummaries
                if let selected = appState.selectedEntryId,
                   !newSummaries.contains(where: { $0.id == selected }) {
                    // A live entry may leave the current filter after saving
                    // (for example, a draft becomes non-draft). Keep it
                    // selected so subsequent keystrokes cannot land in the
                    // first remaining row. Move selection only when the row
                    // was actually removed or soft-deleted.
                    if isFirstEmission {
                        appState.selectedEntryId = newSummaries.first?.id
                    } else if let current = try? appState.entries.entry(id: selected),
                       current.deleted == false {
                        // Keep the current selection outside the filtered list.
                    } else {
                        appState.selectedEntryId = newSummaries.first?.id
                    }
                } else if appState.selectedEntryId == nil {
                    appState.selectedEntryId = newSummaries.first?.id
                }
                isFirstEmission = false
            }
        }
    }

    /// 使用 FTS5 trigram 执行全文搜索（<3 字自动走 LIKE 回退，见 EntryDAO.search）
    func search(query: String, appState: AppState) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            searchError = nil
            return
        }
        isSearching = true
        do {
            let results = try appState.entries.search(EntrySearchQuery(term: trimmed))
            // UI-08③：数据库错误明确报出，不再 try? 伪装成「无结果」
            searchError = nil
            searchResults = results.map { result in
                EntrySummary(
                    id: result.entry.id,
                    dayDate: result.entry.dayDate,
                    journalDate: result.entry.journalDate,
                    title: result.entry.title,
                    bodyPreview: result.bodySnippet.strippingHTMLMarks,
                    bodyLength: result.entry.body.count,
                    isFavorite: result.entry.isFavorite,
                    boardId: result.entry.boardId,
                    tags: result.entry.tags,
                    isDraft: result.entry.isDraft
                )
            }
        } catch {
            searchResults = []
            searchError = error.localizedDescription
        }
    }

    func clearSearch() {
        searchResults = []
        isSearching = false
        searchError = nil
    }
}

// 辅助：去除 FTS snippet 中的 <mark> 标签，保留文字
private extension String {
    var strippingHTMLMarks: String {
        replacingOccurrences(of: "<mark>", with: "")
            .replacingOccurrences(of: "</mark>", with: "")
    }
}

struct TimelineDay: Identifiable, Equatable {
    var id: String { day }
    let day: String
    let entries: [EntrySummary]

    var totalWords: Int {
        entries.reduce(0) { $0 + $1.bodyLength }
    }

    var latestEntry: EntrySummary? {
        // 行渲染每帧调用：max 一次遍历即可，不必整段排序。
        entries.max { $0.journalDate < $1.journalDate }
    }

    var boardCount: Int {
        Set(entries.map(\.boardId)).count
    }
}
