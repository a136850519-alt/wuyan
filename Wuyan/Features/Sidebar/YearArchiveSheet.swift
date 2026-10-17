import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct YearArchiveSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let year: Int
    let onClose: () -> Void
    @State private var destination = "webdav"
    @State private var summary: YearArchiveSummary?
    @State private var localURL: URL?
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var clearLocal = false
    @State private var errorMessage: String?
    @State private var isStarting = false

    init(year: Int, onClose: @escaping () -> Void) {
        self.year = year
        self.onClose = onClose
    }

    private var passwordMatches: Bool { !password.isEmpty && password == passwordConfirmation }
    private var canStart: Bool {
        guard year < AppState.year(fromDayKey: DayKey.today), clearLocal, summary?.hasContent == true else { return false }
        if destination == "webdav" { return !AppSettings.webDAVBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return localURL != nil && passwordMatches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("归档 \(year) 年").font(.title2.weight(.semibold))
                    Text("先验证目标，再清理当前设备对应内容。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { close() }
                    .keyboardShortcut(.cancelAction)
            }

            if let summary {
                VStack(alignment: .leading, spacing: 8) {
                    Text("归档范围").font(.headline)
                    HStack(spacing: 18) {
                        ArchiveMetric(value: "\(summary.entryCount)", label: "篇日记")
                        ArchiveMetric(value: "\(summary.dayNoteCount)", label: "条日札")
                        ArchiveMetric(value: "\(summary.attachmentCount)", label: "个附件")
                        ArchiveMetric(value: ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file), label: "附件容量")
                    }
                    Text("范围包含草稿 \(summary.draftCount) 篇和回收站 \(summary.trashCount) 篇；共享附件仍被其它年份引用时会保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .background(Palette.sidebarPaper)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ProgressView("正在扫描内容与附件…")
            }

            Picker("归档到", selection: $destination) {
                Text("WebDAV / NAS").tag("webdav")
                Text("本地文件").tag("local")
            }
            .pickerStyle(.segmented)

            if destination == "webdav" {
                Label(AppSettings.webDAVBaseURL.isEmpty ? "尚未配置 WebDAV" : AppSettings.webDAVBaseURL, systemImage: "externaldrive.connected.to.line.below")
                    .font(.callout)
                    .foregroundStyle(AppSettings.webDAVBaseURL.isEmpty ? .secondary : Palette.ink)
                Text("上传、读回校验和清理会分别显示真实阶段进度；校验成功前本地内容始终保留。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "doc.zipper")
                        Text(localURL?.lastPathComponent ?? "尚未选择保存位置")
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("选择文件…", action: chooseLocalURL)
                    }
                    SecureField("归档口令", text: $password)
                    SecureField("再次输入归档口令", text: $passwordConfirmation)
                    Text("在另一台设备恢复时，也需要此口令。口令不会写入日志或归档索引。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !passwordConfirmation.isEmpty && !passwordMatches {
                        Text("两次输入的口令不一致。")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }

            Toggle("归档校验成功后，删除 App 内该年内容。", isOn: $clearLocal)
                .tint(Palette.cinnabar)
            if year >= AppState.year(fromDayKey: DayKey.today) {
                Label("年份结束后可归档", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { close() }
                Button {
                    start()
                } label: {
                    if isStarting { ProgressView().controlSize(.small) } else { Text("归档并腾出空间") }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.cinnabar)
                .disabled(!canStart || isStarting)
            }
        }
        .padding(28)
        .frame(width: 560)
        .task { summary = appState.archiveSummary(for: year) }
    }

    private func start() {
        guard canStart else { return }
        isStarting = true
        if destination == "webdav" {
            appState.archiveYearToRemote(year)
            close()
        } else if let localURL {
            appState.archiveYearLocally(year, to: localURL, password: password)
            close()
        }
    }

    private func chooseLocalURL() {
        let panel = NSSavePanel()
        panel.title = "保存年度归档"
        panel.nameFieldStringValue = "晤言-\(year).wuyanarchive"
        panel.allowedContentTypes = [UTType(filenameExtension: "wuyanarchive") ?? .data]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { localURL = panel.url }
    }

    private func close() {
        onClose()
        dismiss()
    }
}

private struct ArchiveMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
