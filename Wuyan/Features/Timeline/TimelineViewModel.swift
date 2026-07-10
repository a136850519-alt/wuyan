import Foundation

@MainActor
final class TimelineViewModel: ObservableObject {
    @Published var summaries: [EntrySummary] = []

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
        case let .yearBoard(year, _):
            filter = .year(year)
        case .calendar, .settings, .trash:
            filter = .all
        }

        observationTask = Task {
            for await newSummaries in appState.entries.observeTimelineSummaries(filter: filter) {
                self.summaries = newSummaries
                if let selected = appState.selectedEntryId,
                   !newSummaries.contains(where: { $0.id == selected }) {
                    appState.selectedEntryId = newSummaries.first?.id
                } else if appState.selectedEntryId == nil {
                    appState.selectedEntryId = newSummaries.first?.id
                }
            }
        }
    }

    var days: [TimelineDay] {
        Dictionary(grouping: summaries, by: \.dayDate)
            .map { day, entries in
                TimelineDay(day: day, entries: entries)
            }
            .sorted { $0.sortDate > $1.sortDate }
    }
}

struct TimelineDay: Identifiable, Equatable {
    var id: String { day }
    let day: String
    let entries: [EntrySummary]

    var sortDate: Date {
        DayKey.date(from: day) ?? entries.map(\.journalDate).max() ?? .distantPast
    }

    var totalWords: Int {
        entries.reduce(0) { $0 + $1.bodyLength }
    }

    var latestEntry: EntrySummary? {
        entries.sorted { $0.journalDate > $1.journalDate }.first
    }

    var boardCount: Int {
        Set(entries.map(\.boardId)).count
    }
}
