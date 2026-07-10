import SwiftUI

struct DayBoardChooserView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let day: String

    @State private var dayNote: DayNote?
    @State private var boards: [Board] = []
    @State private var entries: [Entry] = []
    @State private var visibleBoardCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Spacer(minLength: 8)

            VStack(spacing: 14) {
                ForEach(Array(boards.enumerated()), id: \.element.id) { index, board in
                    BoardDayButton(
                        board: board,
                        entries: entriesByBoard[board.id] ?? [],
                        action: { openEntry(for: board) }
                    )
                    .opacity(index < visibleBoardCount ? 1 : 0)
                    .offset(y: index < visibleBoardCount ? 0 : 16)
                    .animation(.easeOut(duration: 0.65), value: visibleBoardCount)
                }
            }

            Spacer()

            HStack {
                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(WuyanSecondaryButtonStyle())
                Spacer()
                Text("\(entries.count) 篇日记")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(38)
        .frame(width: 600, height: 560)
        .background(Palette.paper)
        .task {
            load()
            revealBoards()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayDate)
                    .font(WuyanFont.title(30))
                Text("回看这一天")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("每日一句")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(dayLine)
                    .font(WuyanFont.title(24))
                    .foregroundStyle(Palette.cinnabarDeep)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.035))
                    .stroke(Palette.hairline)
            )
        }
    }

    private var displayDate: String {
        guard let date = DayKey.date(from: day) else { return day }
        return date.formatted(.dateTime.year().month(.wide).day())
    }

    private var dayLine: String {
        let line = dayNote?.poeticLine.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !line.isEmpty { return line }
        let summary = dayNote?.rawSummary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty { return summary }
        return "这一天还没有每日一句。"
    }

    private var entriesByBoard: [UUID: [Entry]] {
        Dictionary(grouping: entries, by: \.boardId)
    }

    private func load() {
        do {
            boards = try appState.boards.all()
            entries = try appState.entries.entries(on: day)
            dayNote = try appState.dayNotes.note(dayKey: day)
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

    private func openEntry(for board: Board) {
        guard let entry = (entriesByBoard[board.id] ?? []).sorted(by: { $0.journalDate > $1.journalDate }).first else {
            return
        }
        appState.openEntry(id: entry.id)
        dismiss()
    }
}

private struct BoardDayButton: View {
    var board: Board
    var entries: [Entry]
    var action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: board.iconName)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(board.name)
                            .font(WuyanFont.body(21))
                        if entries.count > 1 {
                            Text("\(entries.count) 篇")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: entries.isEmpty ? "minus.circle" : "chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(WuyanBoardKeyButtonStyle(hovering: hover))
        .disabled(entries.isEmpty)
        .opacity(entries.isEmpty ? 0.55 : 1)
        .onHover { hover = $0 }
    }

    private var subtitle: String {
        guard let entry = entries.sorted(by: { $0.journalDate > $1.journalDate }).first else {
            return "这天没有写入这个板块"
        }
        if let title = entry.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if !entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return entry.body
        }
        return "还没有正文"
    }
}
