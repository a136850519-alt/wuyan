import AppKit
import Foundation

@MainActor
final class RitualViewModel: ObservableObject {
    enum Step {
        case summary
        case board
    }

    @Published var step: Step = .summary
    @Published var rawSummary = ""
    @Published var dayNote: DayNote?
    @Published var boards: [Board] = []
    @Published var isGenerating = false
    @Published var showsPoeticLine = false
    @Published var visiblePoeticSegmentCount = 0
    @Published var visibleBoardCount = 0

    var poeticSegments: [String] {
        let line = dayNote?.poeticLine.isEmpty == false ? dayNote?.poeticLine ?? "" : dayNote?.rawSummary ?? ""
        let separators = CharacterSet(charactersIn: "，。；、 ")
        let parts = line.components(separatedBy: separators).filter { !$0.isEmpty }
        return parts.isEmpty ? [line].filter { !$0.isEmpty } : parts
    }

    func prepare(appState: AppState) async {
        do {
            boards = try appState.boards.all()
            if let note = try appState.dayNotes.note(on: Date()) {
                dayNote = note
                step = .board
                revealBoards()
            }
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    func generate(appState: AppState) async {
        guard !appState.isRescueMode else {
            appState.errorMessage = "救援模式：新建内容已禁用。"
            return
        }
        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        isGenerating = true
        let line = await appState.poeticGenerator.line(from: summary)
        let note = DayNote(
            rawSummary: summary,
            poeticLine: line.isEmpty ? summary : line,
            generatedBy: nil
        )
        do {
            try appState.dayNotes.upsert(note)
            appState.syncCoordinator.notifyEditCompleted()
            dayNote = note
            revealPoeticLine()
        } catch {
            appState.errorMessage = error.localizedDescription
        }
        isGenerating = false
    }

    func skip(appState: AppState) async {
        guard !appState.isRescueMode else {
            appState.errorMessage = "救援模式：新建内容已禁用。"
            return
        }
        if rawSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let note = DayNote(rawSummary: "", poeticLine: "今日留白，也算一笔。", generatedBy: nil)
            do {
                try appState.dayNotes.upsert(note)
                appState.syncCoordinator.notifyEditCompleted()
                dayNote = note
                step = .board
                revealBoards()
            } catch {
                appState.errorMessage = error.localizedDescription
            }
        } else {
            await generate(appState: appState)
        }
    }

    func createEntry(board: Board, appState: AppState) {
        guard !appState.isRescueMode else {
            appState.errorMessage = "救援模式：新建内容已禁用。"
            return
        }
        guard let dayNote else { return }
        do {
            let entry = try appState.entries.create(boardId: board.id, dayNote: dayNote)
            appState.syncCoordinator.notifyEditCompleted()
            appState.enrichEntryMetadataIfNeeded(entry.id)
            let year = AppState.year(fromDayKey: entry.dayDate)
            appState.sidebarSelection = .yearBoard(year, board.id)
            appState.selectedEntryId = entry.id
            appState.isShowingRitual = false
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func revealBoards() {
        visibleBoardCount = 0
        if WuyanMotion.reduceMotion {
            visibleBoardCount = boards.count
            return
        }
        for index in boards.indices {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(index) * 240_000_000)
                visibleBoardCount = min(boards.count, index + 1)
            }
        }
    }

    func nextToBoards() {
        step = .board
        revealBoards()
    }

    private func revealPoeticLine() {
        showsPoeticLine = true
        visiblePoeticSegmentCount = 0
        if WuyanMotion.reduceMotion {
            visiblePoeticSegmentCount = poeticSegments.count
            return
        }
        for index in poeticSegments.indices {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(index) * 240_000_000)
                visiblePoeticSegmentCount = min(poeticSegments.count, index + 1)
            }
        }
    }
}
