import SwiftUI

struct TrashView: View {
    @EnvironmentObject private var appState: AppState
    @State private var entries: [Entry] = []
    @State private var pendingDelete: Entry?
    @State private var showsDeleteConfirm = false

    var body: some View {
        List(entries) { entry in
            HStack {
                VStack(alignment: .leading) {
                    Text(entry.title ?? "未命名")
                    Text(entry.updatedAt, style: .date)
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
        .task { load() }
        .confirmationDialog("彻底删除后无法恢复", isPresented: $showsDeleteConfirm) {
            Button("彻底删除", role: .destructive) {
                if let pendingDelete {
                    delete(pendingDelete)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将永久删除“\(pendingDelete?.title ?? "未命名")”。")
        }
    }

    private func load() {
        entries = (try? appState.entries.trashedEntries()) ?? []
    }

    private func restore(_ entry: Entry) {
        try? appState.entries.restore(id: entry.id)
        load()
    }

    private func delete(_ entry: Entry) {
        appState.permanentlyDelete(entryId: entry.id)
        load()
    }
}
