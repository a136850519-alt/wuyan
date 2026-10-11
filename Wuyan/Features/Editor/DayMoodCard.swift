import SwiftUI

struct DayMoodCard: View {
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject private var appState: AppState
    @State private var editing = false
    @State private var draft: Int?
    @State private var snapshot = DayMoodSnapshot(value: nil, hasLegacyConflict: false, noteHash: nil)
    @FocusState private var editFocused: Bool

    var body: some View {
        InspectorCard(title: "", background: Palette.moodSurface, foreground: Palette.moodText) {
            HStack {
                Text(viewModel.draftEntry?.dayDate == DayKey.today ? "今日心绪" : "当日心绪")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(viewModel.mood == nil ? "补选" : "修改") {
                    snapshot = viewModel.currentMoodSnapshot
                    draft = viewModel.mood
                    editing = true
                }.buttonStyle(.plain).font(.system(size: 11)).focused($editFocused)
            }
            HStack(spacing: 14) {
                if let mood = Mood.from(viewModel.mood) {
                    Text(mood.emoji).font(.system(size: 46)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(mood.label).font(.system(size: 17, weight: .semibold))
                        Text("已记录 · 当天各板块共用").font(.system(size: 11))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("尚未记录心情").font(.system(size: 15, weight: .semibold))
                        Text(viewModel.moodNeedsConfirmation ? "旧文章心情不一致，请确认当日心情。原记录会保留。" : "可以在这里补选")
                            .font(.system(size: 11))
                    }
                }
            }
            if editing {
                Text("为这一天重新选择心情").font(.system(size: 12))
                MoodChoices(selection: $draft)
                Text(Mood.from(draft).map { "已选：\($0.label) · 尚未保存" } ?? "请选择心情")
                    .font(.system(size: 11))
                HStack {
                    Button("取消", action: cancel)
                    Spacer()
                    if draft != nil {
                        Button("清除当日心情", role: .destructive) {
                            if viewModel.saveMood(nil, expectedSnapshot: snapshot, appState: appState) { cancel() }
                        }
                    }
                    Button("保存修改") {
                        if let draft, viewModel.saveMood(draft, expectedSnapshot: snapshot, appState: appState) { cancel() }
                    }.disabled(draft == nil)
                }
            }
        }
        .onExitCommand { if editing { cancel() } }
    }
    private func cancel() { editing = false; draft = nil; editFocused = true }
}
