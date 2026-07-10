import Foundation

@MainActor
final class TimelineViewModel: ObservableObject {
    @Published var entries: [Entry] = []

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
            for await entries in appState.entries.observeTimeline(filter: filter) {
                self.entries = entries
                if let selected = appState.selectedEntryId,
                   !entries.contains(where: { $0.id == selected }) {
                    appState.selectedEntryId = entries.first?.id
                } else if appState.selectedEntryId == nil {
                    appState.selectedEntryId = entries.first?.id
                }
            }
        }
    }

    var days: [TimelineDay] {
        Dictionary(grouping: entries, by: \.dayDate)
            .map { day, entries in
                TimelineDay(day: day, entries: entries)
            }
            .sorted { $0.sortDate > $1.sortDate }
    }
}

struct TimelineDay: Identifiable, Equatable {
    var id: String { day }
    let day: String
    let entries: [Entry]

    var sortDate: Date {
        DayKey.date(from: day) ?? entries.map(\.journalDate).max() ?? .distantPast
    }

    var totalWords: Int {
        entries.reduce(0) { $0 + $1.body.count }
    }

    var latestEntry: Entry? {
        entries.sorted { $0.journalDate > $1.journalDate }.first
    }

    var boardCount: Int {
        Set(entries.map(\.boardId)).count
    }
}
