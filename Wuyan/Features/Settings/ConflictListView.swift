import SwiftUI

/// UI-06：应用内冲突列表。条目和日札落败版本都在这里查看、恢复或丢弃。
struct ConflictListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var copies: [ConflictCopyItem] = []
    @State private var selected: ConflictCopyItem?
    @State private var currentEntry: Entry?
    @State private var dayNoteCopies: [DayNoteConflictCopy] = []
    @State private var selectedDayNote: DayNoteConflictCopy?

    struct ConflictCopyItem: Identifiable, Equatable {
        let id: UUID
        let dayDate: String
        let title: String?
        let body: String
        let journalDate: Date
        let createdAt: Date
    }

    var body: some View {
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
            .frame(minWidth: 260, maxWidth: 340)

            detailPane
                .frame(minWidth: 420)
        }
        .navigationTitle("同步冲突")
        .onAppear(perform: reload)
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
                        Text(noteCopy.note.rawSummary)
                            .textSelection(.enabled)
                        Divider()
                        Text(noteCopy.note.poeticLine)
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("恢复此日札") { resolveDayNote(restore: true) }
                    Button("丢弃副本") { resolveDayNote(restore: false) }
                    Spacer()
                }
                .padding(12)
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
                            Label("当前本地版本（远端）", systemImage: "doc.text")
                                .font(.headline)
                            Text(current.body)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("保留本地副本") { resolve(.keepLocal) }
                    Button("保留远端版本") { resolve(.keepRemote) }
                    Button("都保留（副本存为新日记）") { resolve(.keepBoth) }
                    Spacer()
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView("选择一个冲突条目", systemImage: "arrow.triangle.branch")
        }
    }

    private func reload() {
        copies = ((try? appState.db.entryDAO.conflictCopies()) ?? []).map { copy in
            ConflictCopyItem(
                id: copy.id,
                dayDate: copy.envelope.entry.dayDate,
                title: copy.envelope.entry.title,
                body: copy.envelope.entry.body,
                journalDate: copy.envelope.entry.journalDate,
                createdAt: copy.createdAt
            )
        }
        dayNoteCopies = (try? appState.db.dayNoteDAO.conflictCopyRecords()) ?? []
        if let selected, !copies.contains(where: { $0.id == selected.id }) {
            self.selected = nil
            currentEntry = nil
        }
        if let selectedDayNote, !dayNoteCopies.contains(where: { $0.id == selectedDayNote.id }) {
            self.selectedDayNote = nil
        }
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
                try appState.db.dayNoteDAO.upsert(selectedDayNote.note)
                appState.syncCoordinator.notifyEditCompleted()
            }
            try appState.db.dayNoteDAO.dropConflictCopy(id: selectedDayNote.id)
            reload()
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }
}
