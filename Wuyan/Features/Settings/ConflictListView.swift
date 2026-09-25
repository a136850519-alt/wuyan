import SwiftUI

/// UI-06：应用内冲突列表。冲突发生时本地被替代版本留档于本地 conflict_copy
/// （与远端 conflicts 目录同源），此处可逐条查看并选择保留版本。
struct ConflictListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var copies: [ConflictCopyItem] = []
    @State private var selected: ConflictCopyItem?
    @State private var currentEntry: Entry?

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
                if copies.isEmpty {
                    Text("没有待处理的冲突。")
                        .foregroundStyle(.secondary)
                }
                ForEach(copies) { item in
                    Button {
                        selected = item
                        currentEntry = try? appState.entries.entry(id: item.id)
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
            .frame(minWidth: 260, maxWidth: 340)

            VStack(alignment: .leading, spacing: 12) {
                if let item = selected {
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
                } else {
                    ContentUnavailableView("选择一个冲突条目", systemImage: "arrow.triangle.branch")
                }
            }
            .frame(minWidth: 420)
        }
        .navigationTitle("同步冲突")
        .onAppear(perform: reload)
    }

    private func reload() {
        copies = ((try? appState.db.entryDAO.conflictCopies()) ?? []).map { copy in
            ConflictCopyItem(
                id: copy.entryId,
                dayDate: copy.envelope.entry.dayDate,
                title: copy.envelope.entry.title,
                body: copy.envelope.entry.body,
                journalDate: copy.envelope.entry.journalDate,
                createdAt: copy.createdAt
            )
        }
        if let selected, !copies.contains(where: { $0.id == selected.id }) {
            self.selected = nil
            currentEntry = nil
        }
    }

    private enum Resolution {
        case keepLocal
        case keepRemote
        case keepBoth
    }

    /// 冲突解决（UI-06 已确认方案）：
    /// - 保留本地：把留档副本写回为主版本（dirty=true），下次同步覆盖远端；
    /// - 保留远端：丢弃副本（当前本地已是远端版本）；
    /// - 都保留：留档副本以新 ID 存为独立日记，两边内容都在。
    private func resolve(_ resolution: Resolution) {
        guard let item = selected else { return }
        do {
            let copy = (try appState.db.entryDAO.conflictCopies()).first { $0.entryId == item.id }
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
                    // 新条目必须拥有独立的媒体记录；只复用 mediaIds 会让原条目删除时
                    // 级联删除冲突副本仍在引用的附件。
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
            try appState.db.entryDAO.dropConflictCopy(id: item.id)
            appState.syncCoordinator.notifyEditCompleted()
            reload()
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }
}
