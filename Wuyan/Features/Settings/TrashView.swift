import SwiftUI

struct TrashView: View {
    @EnvironmentObject private var appState: AppState
    @State private var entries: [Entry] = []
    @State private var pendingDelete: Entry?
    @State private var showsDeleteConfirm = false
    @State private var showsEmptyConfirm = false

    var body: some View {
        List(entries) { entry in
            HStack {
                VStack(alignment: .leading) {
                    Text(entry.title ?? "未命名")
                    HStack(spacing: 4) {
                        Text("删除于")
                        Text(entry.updatedAt, style: .date)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("还原") { restore(entry) }
                Button("彻底删除", role: .destructive) {
                    pendingDelete = entry
                    showsDeleteConfirm = true
                }
            }
        }
        .navigationTitle("回收站")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("清空回收站", role: .destructive) {
                    showsEmptyConfirm = true
                }
                .disabled(entries.isEmpty)
            }
        }
        .task { load() }
        .confirmationDialog("彻底删除后无法恢复", isPresented: $showsDeleteConfirm) {
            Button("彻底删除", role: .destructive) {
                if let pendingDelete {
                    delete(pendingDelete)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            // UI-04（已确认）：本地立即删除；远端正文/附件保留 90 天后由同步自动清理
            if let title = pendingDelete?.title {
                Text("将永久删除「\(title)」：本地立即删除；远端副本保留 90 天后自动清理，期间不可从其他设备恢复。")
            } else {
                Text("将永久删除此条目：本地立即删除；远端副本保留 90 天后自动清理，期间不可从其他设备恢复。")
            }
        }
        .confirmationDialog("清空回收站", isPresented: $showsEmptyConfirm) {
            Button("全部清空", role: .destructive) {
                emptyTrash()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将永久删除回收站中的 \(entries.count) 篇日记：本地立即删除；远端副本保留 90 天后自动清理。此操作不可撤销。")
        }
    }

    private func load() {
        entries = (try? appState.entries.trashedEntries()) ?? []
    }

    private func restore(_ entry: Entry) {
        appState.restoreEntry(entryId: entry.id)
        load()
    }

    private func delete(_ entry: Entry) {
        appState.permanentlyDelete(entryId: entry.id)
        load()
    }

    private func emptyTrash() {
        for entry in entries {
            appState.permanentlyDelete(entryId: entry.id)
        }
        load()
    }
}
