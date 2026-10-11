import AppKit
import SwiftUI

struct WordExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: Entry
    let boardName: String
    let assets: [MediaAsset]
    @State private var includeMetadata = false
    @State private var includeAttachments = false
    @State private var isExporting = false
    @State private var statusMessage = ""
    @State private var exportedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .font(.title2)
                    .foregroundStyle(Palette.cinnabar)
                VStack(alignment: .leading, spacing: 3) {
                    Text("导出为 Word").font(.title2.weight(.semibold))
                    Text(entry.title?.isEmpty == false ? entry.title! : "无标题日记")
                        .font(.callout)
                        .lineLimit(1)
                    Text("仅导出当前这篇日记 · .docx")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("始终包含").font(.headline)
                Label("标题、文章日期、所属板块、正文", systemImage: "checkmark.circle.fill")
                Label("正文内图片", systemImage: "checkmark.circle.fill")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("可选内容").font(.headline)
                Toggle("心情、天气与标签", isOn: $includeMetadata)
                Toggle("文末附上其他图片附件", isOn: $includeAttachments)
            }
            Text("音频、视频只列出文件名，不嵌入播放对象。导出的文件不受晤言日记密码保护。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(exportedURL == nil ? Palette.cinnabar : .secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    chooseLocation()
                } label: {
                    Label(isExporting ? "正在导出…" : "选择保存位置…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.cinnabar)
                .disabled(isExporting)
                if let exportedURL {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
                }
            }
        }
        .padding(28)
        .frame(width: 510)
    }

    private func chooseLocation() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "docx")!]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFilename
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let target = url.pathExtension.lowercased() == "docx" ? url : url.appendingPathExtension("docx")
        isExporting = true
        statusMessage = "正在生成 Word 文档…"
        exportedURL = nil
        let snapshotEntry = entry
        let snapshotBoardName = boardName
        let snapshotAssets = assets
        let metadata = includeMetadata
        let attachments = includeAttachments
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try DocxExportService().export(
                    entry: snapshotEntry,
                    boardName: snapshotBoardName,
                    assets: snapshotAssets,
                    options: DocxExportOptions(includeMetadata: metadata, includeAttachments: attachments),
                    to: target
                )
                DispatchQueue.main.async {
                    exportedURL = target
                    statusMessage = "导出完成：\(target.path)"
                    isExporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    statusMessage = error.localizedDescription
                    isExporting = false
                }
            }
        }
    }

    private var defaultFilename: String {
        let title = (entry.title?.isEmpty == false ? entry.title! : "无标题日记")
        let sanitized = title.map { "\\/:*?\"<>|".contains($0) ? "_" : String($0) }.joined()
        return "\(entry.dayDate)_\(sanitized).docx"
    }
}
