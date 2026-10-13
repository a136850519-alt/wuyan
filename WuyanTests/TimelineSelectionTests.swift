import Foundation
import Testing
@testable import Wuyan

extension GlobalStateSuite {
@Suite("Timeline selection")
@MainActor
struct TimelineSelectionTests {
    @Test("筛选变化后首次结果选择新列表第一项")
    func filterChangeSelectsFirstResult() async throws {
        try await TestIsolation.withIsolatedDefaults { _ in
            let db = try AppDatabase.makeInMemory()
            let appState = AppState(database: db)
            let board = try #require(db.boardDAO.all().first)
            let old = Entry(boardId: board.id, body: "旧", isFavorite: false, isDraft: false)
            let favorite = Entry(boardId: board.id, body: "收藏", isFavorite: true, isDraft: false)
            try db.entryDAO.save(old)
            try db.entryDAO.save(favorite)
            appState.selectedEntryId = old.id
            appState.sidebarSelection = .favorites

            let viewModel = TimelineViewModel()
            viewModel.observe(appState: appState)
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline && appState.selectedEntryId != favorite.id {
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(appState.selectedEntryId == favorite.id)
        }
    }
}
}
