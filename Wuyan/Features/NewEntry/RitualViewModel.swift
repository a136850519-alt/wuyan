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
    @Published var mood: Int?
    private var moodNoteHash: String?
    private(set) var dayKey = DayKey.today
    private var prepared = false
    private var dismissed = false
    @Published var errorMessage: String?
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
        guard !prepared else { return }
        do {
            dayKey = DayKey.today
            boards = try appState.boards.all()
            let note = try appState.dayNotes.note(dayKey: dayKey)
            dayNote = note
            rawSummary = note?.rawSummary ?? ""
            mood = try appState.dayNotes.effectiveMood(dayKey: dayKey)
            moodNoteHash = note.map(Hashing.dayNoteHash)
            prepared = true
            if let note, !note.rawSummary.isEmpty || !note.poeticLine.isEmpty {
                step = .board
                revealBoards()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func generate(appState: AppState) async {
        guard !isGenerating, !dismissed, prepared else { return }
        guard !appState.isRescueMode else { errorMessage = "救援模式：新建内容已禁用。"; return }
        isGenerating = true
        defer { isGenerating = false }
        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedMood = mood
        let line = await appState.poeticGenerator.line(from: summary)
        guard !Task.isCancelled, !dismissed else { return }
        if save(summary: summary, line: line.isEmpty ? summary : line, mood: selectedMood, appState: appState) {
            revealPoeticLine()
        }
    }

    func skip(appState: AppState) async {
        guard !isGenerating, !dismissed, prepared else { return }
        guard !appState.isRescueMode else { errorMessage = "救援模式：新建内容已禁用。"; return }
        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if save(summary: summary, line: summary.isEmpty ? "今日留白，也算一笔。" : summary, mood: mood, appState: appState) {
            nextToBoards()
        }
    }

    private func save(summary: String, line: String, mood: Int?, appState: AppState) -> Bool {
        let note = DayNote(date: dayKey, rawSummary: summary, poeticLine: line,
                           generatedBy: nil, mood: mood,
                           moodCleared: mood == nil ? (dayNote?.moodCleared ?? false) : false,
                           createdAt: dayNote?.createdAt ?? Date())
        do {
            try appState.dayNotes.upsert(note, expectedHash: moodNoteHash)
            dayNote = note
            moodNoteHash = Hashing.dayNoteHash(note)
            errorMessage = nil
            appState.syncCoordinator.notifyEditCompleted()
            return true
        } catch { errorMessage = "保存失败，输入与心情已保留。\(error.localizedDescription)"; return false }
    }

    func close() { dismissed = true }

    func createEntry(board: Board, appState: AppState) {
        guard !appState.isRescueMode else {
            appState.errorMessage = "救援模式：新建内容已禁用。"
            return
        }
        guard let dayNote else { return }
        do {
            let timestamp = DayKey.today == dayKey ? Date() : (DayKey.date(from: dayKey)?.addingTimeInterval(12 * 3600) ?? Date())
            let entry = try appState.entries.create(boardId: board.id, dayNote: dayNote, journalDate: timestamp)
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
