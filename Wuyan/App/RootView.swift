import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showsOnboarding = !AppSettings.onboardingCompleted

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } content: {
            TimelineView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
        } detail: {
            switch appState.sidebarSelection {
            case .calendar:
                CalendarHistoryView()
            case .settings:
                SettingsView()
            case .trash:
                TrashView()
            default:
                EditorView()
            }
        }
        .background(Palette.paper)
        .overlay(alignment: .top) {
            // UI-07：只读救援模式横幅——数据库未正常加载时的唯一合法操作出口
            if appState.isRescueMode {
                RescueModeBanner()
            }
        }
        .sheet(isPresented: $appState.isShowingRitual) {
            RitualView()
                .environmentObject(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.boardChooserDay != nil },
            set: { if !$0 { appState.boardChooserDay = nil } }
        )) {
            if let day = appState.boardChooserDay {
                DayBoardChooserView(day: day)
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView(isPresented: $showsOnboarding)
        }
        .alert("晤言遇到一个问题", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("好") {
                appState.errorMessage = nil
            }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .confirmationDialog("删除这篇日记？", isPresented: Binding(
            get: { appState.pendingDeleteEntryId != nil },
            set: { if !$0 { appState.pendingDeleteEntryId = nil } }
        ), titleVisibility: .visible) {
            Button("移入回收站", role: .destructive) {
                if let id = appState.pendingDeleteEntryId {
                    appState.pendingDeleteEntryId = nil
                    appState.softDelete(entryId: id)
                }
            }
            Button("取消", role: .cancel) { appState.pendingDeleteEntryId = nil }
        }
    }
}


/// UI-07：救援模式横幅：明示「内容未落盘/未同步」，提供救援副本导出。
private struct RescueModeBanner: View {
    @EnvironmentObject private var appState: AppState
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 6) {
            Label("只读救援模式：数据库加载失败，编辑与同步已禁用，当前输入不会被保存。", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
            HStack(spacing: 12) {
                Button("导出救援副本") { exportRescueCopy() }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.12))
    }

    private func exportRescueCopy() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出救援副本"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let url = try appState.exportRescueCopy(to: directory)
            statusMessage = "已导出：\(url.lastPathComponent)"
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }
}
