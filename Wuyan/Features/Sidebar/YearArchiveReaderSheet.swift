import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct YearArchiveReaderSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let record: YearArchiveRecord
    @State private var archiveURL: URL?
    @State private var password = ""
    @State private var snapshot: YearArchiveSnapshot?
    @State private var errorMessage: String?
    @State private var restoreMessage: String?
    @State private var isReading = false
    @State private var isRestoring = false
    @State private var showsRestoreConfirmation = false

    init(record: YearArchiveRecord) {
        self.record = record
        _archiveURL = State(initialValue: record.location.map { URL(fileURLWithPath: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("打开 \(record.year) 年归档")
                        .font(.title2.weight(.semibold))
                    Text("只读查看，不会把内容导入当前日记库。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(archiveURL?.lastPathComponent ?? "尚未定位归档文件", systemImage: "doc.zipper")
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    Text(archiveURL?.path ?? "文件位置不可用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("重新定位…", action: chooseArchive)
                }
            }
            .padding(14)
            .background(Palette.sidebarPaper)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            SecureField("归档口令", text: $password)
                .textFieldStyle(.roundedBorder)

            if let snapshot {
                archiveSummary(snapshot)
            } else {
                Text("输入创建归档时设置的口令后，晤言会从最终文件解密并校验内容与附件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let restoreMessage {
                Text(restoreMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if snapshot != nil {
                    Button {
                        showsRestoreConfirmation = true
                    } label: {
                        if isRestoring {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("恢复到 App", systemImage: "arrow.uturn.backward.circle")
                        }
                    }
                    .disabled(isRestoring || appState.isBackupTaskRunning)
                }
                Spacer()
                Button {
                    readArchive()
                } label: {
                    if isReading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("验证并打开", systemImage: "lock.open")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.cinnabar)
                .disabled(isReading || password.isEmpty || archiveURL == nil)
            }
        }
        .padding(28)
        .frame(width: 600)
        .confirmationDialog("恢复 (record.year) 年归档？", isPresented: $showsRestoreConfirmation, titleVisibility: .visible) {
            Button("恢复并保留当前内容") { restore() }
            Button("取消", role: .cancel) { showsRestoreConfirmation = false }
        } message: {
            Text("相同 ID 的当前条目会保留，归档中的新条目和媒体会导入。恢复前会自动创建数据库回退快照。")
        }
    }

    private func archiveSummary(_ snapshot: YearArchiveSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                ArchiveReaderMetric(value: "\(snapshot.entries.count)", label: "篇日记")
                ArchiveReaderMetric(value: "\(snapshot.dayNotes.count)", label: "条日札")
                ArchiveReaderMetric(value: "\(snapshot.mediaAssets.count)", label: "个附件")
                ArchiveReaderMetric(
                    value: ByteCountFormatter.string(fromByteCount: snapshot.mediaAssets.reduce(0) { $0 + $1.size }, countStyle: .file),
                    label: "附件容量"
                )
            }
            Divider()
            Text("已验证内容")
                .font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.entries.sorted { $0.dayDate == $1.dayDate ? $0.journalDate < $1.journalDate : $0.dayDate < $1.dayDate }.prefix(8)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.dayDate)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.title?.isEmpty == false ? entry.title! : "无标题")
                                .lineLimit(1)
                            if entry.deleted {
                                Text("回收站").font(.caption2).foregroundStyle(.secondary)
                            } else if entry.isDraft {
                                Text("草稿").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if snapshot.entries.count > 8 {
                        Text("还有 \(snapshot.entries.count - 8) 篇日记未展开显示。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .padding(14)
        .background(Palette.paper)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Palette.hairline, lineWidth: 1)
        }
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.title = "选择晤言年度归档"
        panel.allowedContentTypes = [UTType(filenameExtension: "wuyanarchive") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archiveURL = url
        snapshot = nil
        errorMessage = nil
    }

    private func readArchive() {
        guard let archiveURL else { return }
        isReading = true
        errorMessage = nil
        Task {
            do {
                let loaded = try YearArchiveService().readArchive(from: archiveURL, password: password)
                guard loaded.year == record.year else {
                    throw YearArchiveError.corrupt("文件年份与归档索引不一致")
                }
                snapshot = loaded
                appState.relinkArchive(record, to: archiveURL)
            } catch {
                snapshot = nil
                errorMessage = error.localizedDescription
            }
            isReading = false
        }
    }

    private func restore() {
        guard let archiveURL, snapshot != nil else { return }
        isRestoring = true
        restoreMessage = nil
        appState.isBackupTaskRunning = true
        Task {
            do {
                let report = try YearArchiveService().restoreArchive(
                    from: archiveURL,
                    password: password,
                    database: appState.db,
                    mediaStore: appState.mediaStore
                )
                appState.syncCoordinator.notifyEditCompleted()
                restoreMessage = "恢复完成：导入 \(report.importedEntries) 篇，跳过 \(report.skippedEntries) 篇，恢复 \(report.restoredMediaFiles) 个媒体文件。"
            } catch {
                restoreMessage = "恢复未完成：\(error.localizedDescription)"
            }
            appState.isBackupTaskRunning = false
            isRestoring = false
        }
    }
}

private struct ArchiveReaderMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
