import SwiftUI

struct AppCommands: Commands {
    // 注意：SwiftUI 的 .commands 不继承 WindowGroup 注入的 environmentObject，
    // 必须由 App 显式传入，否则菜单一构建就找不到 AppState 而崩溃。
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("新建日记") {
                appState.showNewEntryRitual()
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("日记") {
            Button("日历") {
                appState.sidebarSelection = .calendar
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("设置") {
                appState.sidebarSelection = .settings
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("回收站") {
                appState.sidebarSelection = .trash
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])

            Divider()

            Button("同步") {
                appState.syncNow()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("删除当前条目") {
                guard let id = appState.selectedEntryId else { return }
                do {
                    try appState.entries.softDelete(id: id)
                    appState.selectedEntryId = nil
                } catch {
                    appState.errorMessage = error.localizedDescription
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(appState.selectedEntryId == nil)
        }
    }
}
