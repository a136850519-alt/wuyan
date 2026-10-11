import SwiftUI

/// UI-06：应用内冲突列表。条目和日札落败版本都在这里查看、恢复或丢弃。
struct ConflictListView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var copies: [ConflictCopyItem] = []
    @State private var selected: ConflictCopyItem?
    @State private var currentEntry: Entry?
    @State private var dayNoteCopies: [DayNoteConflictCopy] = []
    @State private var selectedDayNote: DayNoteConflictCopy?
    @State private var loadError: String?
    @State private var pendingResolution: Resolution?
    @State private var pendingNoteRestore: Bool?

    struct ConflictCopyItem: Identifiable, Equatable {
        let id: UUID
        let dayDate: String
        let title: String?
        let body: String
        let journalDate: Date
        let createdAt: Date
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("同步冲突").font(.title3.weight(.semibold))
                    Text("对比并选择要保留的版本；关闭不会处理任何冲突。")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.bordered).accessibilityLabel("关闭同步冲突")
            }.padding(20).background(Palette.inspectorSurface)
            if let loadError {
                HStack { Text(loadError); Button("重试", action: reload) }.font(.callout).padding(12)
            }
            HSplitView {
            List {
                if copies.isEmpty && dayNoteCopies.isEmpty {
                    Text("没有待处理的冲突。")
                        .foregroundStyle(.secondary)
                }
                if !copies.isEmpty {
                    Section("日记") {
                        ForEach(copies) { item in
                            Button {
                                selected = item
                                selectedDayNote = nil
                                currentEntry = ((try? appState.db.entryDAO.conflictCopies()) ?? [])
                                    .first { $0.id == item.id }
                                    .flatMap { try? appState.entries.entry(id: $0.entryId) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(item.dayDate) · \(item.title?.isEmpty == false ? item.title! : String(item.body.prefix(24)))")
                                        .lineLimit(1)
                                    Text("副本时间 \(item.createdAt.formatted(.dateTime))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(selected?.id == item.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        }
                    }
                }
                if !dayNoteCopies.isEmpty {
                    Section("日札") {
                        ForEach(dayNoteCopies) { item in
                            Button {
                                selected = nil
                                currentEntry = nil
                                selectedDayNote = item
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.note.date)
                                    Text(item.note.rawSummary)
                                        .lineLimit(1)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(selectedDayNote?.id == item.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        }
                    }
                }
            }
            .frame(minWidth: 210, idealWidth: 245, maxWidth: 300)

            detailPane
                .frame(minWidth: 420)
        }
            HStack {
                Button { dismiss() } label: { Label("返回设置", systemImage: "chevron.left") }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if selectedDayNote != nil {
                    Button("恢复此日札") { pendingNoteRestore = true }
                    Button("丢弃副本") { pendingNoteRestore = false }
                } else if selected != nil {
                    Button("保留本地副本") { pendingResolution = .keepLocal }
                    Button("保留当前版本") { pendingResolution = .keepRemote }
                    Button("两份都保留") { resolve(.keepBoth) }.buttonStyle(.borderedProminent)
                }
            }.padding(16).background(Palette.inspectorSurface)
        }
        .frame(minWidth: 800, idealWidth: 1000, minHeight: 500, idealHeight: 590)
        .background(Palette.paper)
        .onAppear(perform: reload)
        .onExitCommand { dismiss() }
        .confirmationDialog("只保留所选版本？", isPresented: Binding(get: { pendingResolution != nil }, set: { if !$0 { pendingResolution = nil } })) {
            Button("确认只保留所选版本", role: .destructive) {
                if let resolution = pendingResolution { resolve(resolution) }
                pendingResolution = nil
            }
            Button("取消", role: .cancel) { pendingResolution = nil }
        } message: {
            Text("另一版本将被替换或丢弃。若想保留两份内容，请取消并选择“两份都保留”。")
        }
        .confirmationDialog("处理日札副本？", isPresented: Binding(get: { pendingNoteRestore != nil }, set: { if !$0 { pendingNoteRestore = nil } })) {
            Button(pendingNoteRestore == true ? "恢复此日札" : "丢弃副本", role: .destructive) {
                if let restore = pendingNoteRestore { resolveDayNote(restore: restore) }
                pendingNoteRestore = nil
            }
            Button("取消", role: .cancel) { pendingNoteRestore = nil }
        } message: {
            Text(pendingNoteRestore == true ? "恢复会更新这一天的一句话与共享心情，当前日札会另存为副本。" : "这个日札副本将被丢弃，当前日札不变。")
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let noteCopy = selectedDayNote {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("日札冲突副本", systemImage: "note.text")
                            .font(.headline)
                        Text("\(noteCopy.note.date) · 副本时间 \(noteCopy.createdAt.formatted(.dateTime))")
                            .foregroundStyle(.secondary)
                        Text(Mood.from(noteCopy.note.mood).map { "当日心情：\($0.emoji) \($0.label)" } ?? "心情未记录")
                            .font(.callout)
                        Text(noteCopy.note.rawSummary)
                            .textSelection(.enabled)
                        Divider()
                        Text(noteCopy.note.poeticLine)
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if let item = selected {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("本地副本（冲突时被远端版本替代）", systemImage: "doc")
                            .font(.headline)
                        Text("\(item.dayDate) \(item.journalDate.formatted(.dateTime.hour().minute()))")
                            .foregroundStyle(.secondary)
                        Text(item.body)
                            .textSelection(.enabled)
                        if let current = currentEntry {
                            Divider()
                            Label("当前版本", systemImage: "doc.text")
                                .font(.headline)
                            Text(current.body)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ContentUnavailableView(copies.isEmpty && dayNoteCopies.isEmpty ? "没有待处理的冲突" : "选择一个冲突条目", systemImage: "arrow.triangle.branch")
        }
    }

    private func reload() {
        do {
        copies = (try appState.db.entryDAO.conflictCopies()).map { copy in
            ConflictCopyItem(
                id: copy.id,
                dayDate: copy.envelope.entry.dayDate,
                title: copy.envelope.entry.title,
                body: copy.envelope.entry.body,
                journalDate: copy.envelope.entry.journalDate,
                createdAt: copy.createdAt
            )
        }
        dayNoteCopies = try appState.db.dayNoteDAO.conflictCopyRecords()
        loadError = nil
        if let selected, !copies.contains(where: { $0.id == selected.id }) {
            self.selected = nil
            currentEntry = nil
        }
        if let selectedDayNote, !dayNoteCopies.contains(where: { $0.id == selectedDayNote.id }) {
            self.selectedDayNote = nil
        }
        } catch { loadError = "冲突列表加载失败：\(error.localizedDescription)" }
    }

    private enum Resolution {
        case keepLocal
        case keepRemote
        case keepBoth
    }

    private func resolve(_ resolution: Resolution) {
        guard let item = selected else { return }
        do {
            let copy = (try appState.db.entryDAO.conflictCopies()).first { $0.id == item.id }
            if let envelope = copy?.envelope {
                switch resolution {
                case .keepLocal:
                    try appState.db.entryDAO.saveResolvedConflict(
                        entry: envelope.entry, board: envelope.board,
                        dayNote: envelope.dayNote, mediaAssets: envelope.mediaAssets ?? []
                    )
                case .keepBoth:
                    var entry = envelope.entry
                    entry.id = UUID()
                    let clonedAssets = (envelope.mediaAssets ?? []).map { asset -> MediaAsset in
                        var clone = asset
                        clone.id = UUID()
                        clone.entryId = entry.id
                        return clone
                    }
                    try appState.db.entryDAO.saveResolvedConflict(
                        entry: entry, board: envelope.board,
                        dayNote: envelope.dayNote, mediaAssets: clonedAssets
                    )
                case .keepRemote:
                    break
                }
            }
            try appState.db.entryDAO.dropConflictCopy(copyID: item.id)
            appState.syncCoordinator.notifyEditCompleted()
            reload()
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func resolveDayNote(restore: Bool) {
        guard let selectedDayNote else { return }
        do {
            if restore {
                try appState.db.dayNoteDAO.restoreConflictCopy(selectedDayNote)
                appState.syncCoordinator.notifyEditCompleted()
            }
            try appState.db.dayNoteDAO.dropConflictCopy(id: selectedDayNote.id)
            reload()
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }
}
