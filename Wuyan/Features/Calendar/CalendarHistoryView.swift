import SwiftUI

struct CalendarHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var month = Date()
    @State private var entries: [EntrySummary] = []
    @State private var selectedDay: String? = Date().dayKey
    @State private var selectedDayNote: DayNote?

    var body: some View {
        let currentStreak = tracker.currentStreak()
        let longestStreak = tracker.longestStreak()
        let countsByDay = Dictionary(grouping: entries, by: \.dayDate).mapValues(\.count)
        let totalWords = entries.reduce(0) { $0 + $1.bodyLength }
        let visibleEntries = filteredEntries
        let dailyCounts = tracker.dailyCounts(in: lastYearInterval)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    StatSummaryCard(title: "当前连续", value: "\(currentStreak) 天")
                    StatSummaryCard(title: "最长连续", value: "\(longestStreak) 天")
                    StatSummaryCard(title: "累计篇", value: "\(entries.count)")
                    StatSummaryCard(title: "累计字", value: "\(totalWords)")
                }
                .padding(.horizontal)

            monthCalendar(countsByDay: countsByDay)
                .padding(.horizontal)

            dayNoteCard
                .padding(.horizontal)

            dayPreviewSection(entries: visibleEntries)
                .padding(.horizontal)

            todayInHistory
                Text("过去一年")
                    .font(.headline)
                    .padding(.horizontal)
                CalendarHeatmap(counts: dailyCounts)
                    .padding(.horizontal)
            }
        }
        .navigationTitle("日历")
        .task { load() }
        .onChange(of: selectedDay) {
            loadSelectedDayNote()
        }
    }

    private var tracker: StreakTracker {
        StreakTracker(summaries: entries)
    }

    private var lastYearInterval: DateInterval {
        let end = Date()
        let start = Calendar.current.date(byAdding: .month, value: -12, to: end) ?? end
        return DateInterval(start: start, end: end)
    }

    private var filteredEntries: [EntrySummary] {
        guard let selectedDay else { return [] }
        return entries.filter { $0.dayDate == selectedDay }
    }

    private var todayInHistory: some View {
        let today = DayKey.today
        let todayMonthDay = String(today.dropFirst(5))
        let todayYear = String(today.prefix(4))
        let matches = entries.filter {
            String($0.dayDate.dropFirst(5)) == todayMonthDay && String($0.dayDate.prefix(4)) != todayYear
        }
        return VStack(alignment: .leading) {
            Text("历史上的今天")
                .font(.headline)
            ForEach(Array(matches.prefix(3))) { entry in
                Text(entry.title ?? entry.bodyPreview)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var dayNoteCard: some View {
        WuyanCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("每日一句", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    if let selectedDay {
                        Text(selectedDay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(selectedDayLine)
                    .font(WuyanFont.body(18))
                    .foregroundStyle(Palette.cinnabarDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func monthCalendar(countsByDay: [String: Int]) -> some View {
        WuyanCard {
            VStack(spacing: 10) {
                HStack {
                    Button {
                        shiftMonth(by: -1)
                    } label: {
                        Label("上个月", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    DatePicker("月份", selection: $month, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)

                    Spacer()

                    Button {
                        shiftMonth(by: 1)
                    } label: {
                        Label("下个月", systemImage: "chevron.right")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }

                LazyVGrid(columns: calendarColumns, spacing: 5) {
                    ForEach(weekdaySymbols, id: \.self) { weekday in
                        Text(weekday)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 20)
                    }
                    ForEach(monthCells) { cell in
                        CalendarDayCell(
                            cell: cell,
                            entryCount: cell.date.map { countsByDay[calendarDayKey(for: $0), default: 0] } ?? 0,
                            isSelected: cell.date.map { calendarDayKey(for: $0) } == selectedDay
                        ) {
                            guard let date = cell.date else { return }
                            selectedDay = calendarDayKey(for: date)
                            loadSelectedDayNote()
                        }
                    }
                }
            }
        }
    }

    private func dayPreviewSection(entries: [EntrySummary]) -> some View {
        WuyanCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("当天记录", systemImage: "doc.text")
                        .font(.headline)
                    Spacer()
                    Text("\(entries.count) 篇")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if entries.isEmpty {
                    Text("这一天还没有日记")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(entries) { entry in
                            CalendarEntryPreviewRow(entry: entry) {
                                openEntry(entry)
                            }
                            if entry.id != entries.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedDayLine: String {
        let line = selectedDayNote?.poeticLine.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !line.isEmpty { return line }
        let summary = selectedDayNote?.rawSummary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty { return summary }
        return "这一天还没有每日一句。"
    }

    private func load() {
        entries = (try? appState.entries.timelineSummaries(filter: .all)) ?? []
        loadSelectedDayNote()
    }

    private func loadSelectedDayNote() {
        guard let selectedDay else {
            selectedDayNote = nil
            return
        }
        selectedDayNote = try? appState.dayNotes.note(dayKey: selectedDay)
    }

    private func openEntry(_ entry: EntrySummary) {
        appState.openEntry(id: entry.id)
    }

    private var calendarColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
    }

    private var weekdaySymbols: [String] {
        ["一", "二", "三", "四", "五", "六", "日"]
    }

    private var monthCells: [CalendarMonthCell] {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: month)
        guard let monthStart = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: monthStart)
        else { return [] }

        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leadingEmptyCount = (firstWeekday + 5) % 7
        var cells: [CalendarMonthCell] = (0..<leadingEmptyCount).map { CalendarMonthCell(id: "empty-leading-\($0)", date: nil) }
        cells += range.compactMap { day -> CalendarMonthCell? in
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { return nil }
            return CalendarMonthCell(id: calendarDayKey(for: date), date: date)
        }
        while cells.count % 7 != 0 {
            cells.append(CalendarMonthCell(id: "empty-trailing-\(cells.count)", date: nil))
        }
        while cells.count < 42 {
            cells.append(CalendarMonthCell(id: "empty-trailing-\(cells.count)", date: nil))
        }
        return cells
    }

    private func shiftMonth(by value: Int) {
        let calendar = Calendar(identifier: .gregorian)
        month = calendar.date(byAdding: .month, value: value, to: month) ?? month
    }

    private func calendarDayKey(for date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1, components.month ?? 1, components.day ?? 1)
    }
}

private struct CalendarMonthCell: Identifiable {
    let id: String
    let date: Date?
}

private struct CalendarDayCell: View {
    var cell: CalendarMonthCell
    var entryCount: Int
    var isSelected: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(border, lineWidth: isSelected ? 1.2 : 0.5)
                    )

                if let date = cell.date {
                    Text("\(Calendar.current.component(.day, from: date))")
                        .font(.callout.weight(isToday(date) ? .semibold : .regular))
                        .foregroundStyle(textColor(for: date))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                    if entryCount > 0 {
                        Capsule()
                            .fill(entryMarkerColor)
                            .frame(width: min(CGFloat(entryCount) * 8, 28), height: 3)
                            .padding(.bottom, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(cell.date == nil)
    }

    private var background: Color {
        guard cell.date != nil else { return Color.clear }
        if isSelected { return Palette.cinnabar.opacity(0.18) }
        if entryCount > 0 { return Color.primary.opacity(0.032) }
        return Color.primary.opacity(0.018)
    }

    private var border: Color {
        guard cell.date != nil else { return Color.clear }
        if isSelected { return Palette.cinnabar }
        if entryCount > 0 { return Palette.cinnabarStroke }
        return Palette.hairline
    }

    private func isToday(_ date: Date) -> Bool {
        calendarDayKey(for: date) == DayKey.today
    }

    private func calendarDayKey(for date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1, components.month ?? 1, components.day ?? 1)
    }

    private func textColor(for date: Date) -> Color {
        if isToday(date) { return Palette.cinnabarDeep }
        return .primary
    }

    private var entryMarkerColor: Color {
        isSelected ? Palette.cinnabar : Palette.cinnabar.opacity(0.72)
    }
}

private struct CalendarEntryPreviewRow: View {
    var entry: EntrySummary
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title ?? "未命名")
                        .font(.headline)
                    Spacer()
                    Text(entry.journalDate, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Label("\(entry.bodyLength) 字", systemImage: "textformat")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Label("打开", systemImage: "arrow.forward")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private var preview: String {
        let trimmed = entry.bodyPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "还没有正文" : trimmed
    }
}

private struct StatSummaryCard: View {
    var title: String
    var value: String

    var body: some View {
        WuyanCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CalendarHeatmap: View {
    var counts: [Date: Int]
    private let calendar = Calendar.current

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(12), spacing: 4), count: 31), spacing: 4) {
            ForEach(days, id: \.self) { day in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Palette.heatmap[min(counts[calendar.startOfDay(for: day), default: 0], Palette.heatmap.count - 1)])
                    .frame(width: 12, height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Palette.hairline, lineWidth: 0.5))
            }
        }
    }

    private var days: [Date] {
        let end = DayKey.date(from: DayKey.today) ?? calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -364, to: end) ?? end
        return (0...364).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}
