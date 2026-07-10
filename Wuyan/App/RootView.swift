import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showsOnboarding = !UserDefaults.standard.bool(forKey: "onboarding.completed")

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
    }
}
