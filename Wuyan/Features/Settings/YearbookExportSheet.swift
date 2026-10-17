import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct YearbookExportSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let year: Int
    @State private var options: YearbookOptions
    @State private var summary: YearArchiveSummary?
    @State private var previewEntries: [Entry] = []
    @State private var isExporting = false
    @State private var statusMessage: String?

    init(year: Int) {
        self.year = year
        _options = State(initialValue: YearbookOptions(year: year, title: "\(year) · 日记", style: .journal, paper: .a5))
    }

    var body: some View {
        HStack(spacing: 0) {
            settings
                .frame(width: 300)
                .padding(26)
                .background(Palette.sidebarPaper)
            Divider()
            preview
                .padding(26)
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 940, height: 650)
        .task {
            summary = appState.archiveSummary(for: year)
            previewEntries = ((try? appState.entries.timeline(filter: .all)) ?? [])
                .filter { $0.dayDate.hasPrefix(String(format: "%04d-", year)) }
                .sorted { $0.dayDate < $1.dayDate }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("制作年度日记本").font(.title3.weight(.semibold))
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(year) 年 · 实际内容预览").font(.callout).foregroundStyle(.secondary)

            TextField("书名", text: $options.title)
                .textFieldStyle(.roundedBorder)
            Picker("样式", selection: $options.style) {
                ForEach(YearbookStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("纸张", selection: $options.paper) {
                ForEach(YearbookPaper.allCases) { Text($0.rawValue + " 竖版").tag($0) }
            }
            Divider()
            Toggle("包含普通日记", isOn: $options.includeEntries)
            Toggle("包含日札", isOn: $options.includeDayNotes)
            Toggle("包含照片与媒体说明", isOn: $options.includePhotos)
            DisclosureGroup("更多设置") {
                Toggle("包含草稿", isOn: $options.includeDrafts)
                Toggle("包含回收站", isOn: $options.includeTrash)
            }
            Toggle("封面跟随年度主题色", isOn: $options.followTheme)
            Spacer()
            if let statusMessage {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                export()
            } label: {
                if isExporting { ProgressView().controlSize(.small) } else { Label("导出 PDF", systemImage: "arrow.down.doc") }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.cinnabar)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .disabled(isExporting || summary?.hasContent != true || (!options.includeEntries && !options.includeDayNotes))
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("预览").font(.headline)
                Spacer()
                if let summary {
                    Text("约 \(estimatedPages) 页 · \(summary.entryCount) 篇")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(previewPaper)
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                VStack(alignment: .leading, spacing: 14) {
                    Text(options.title.isEmpty ? "\(year) · 日记" : options.title)
                        .font(.system(size: options.style == .album ? 32 : 28, weight: .semibold, design: .serif))
                        .foregroundStyle(options.followTheme ? AppSettings.yearThemeValue(year).color : Palette.ink)
                    Text(previewSubtitle).font(.title3)
                    Divider()
                    if previewEntries.isEmpty {
                        Text("所选范围没有可导出的内容。").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(previewEntries.prefix(4))) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(options.style == .journal ? "· " + (entry.title?.isEmpty == false ? entry.title! : "无标题") : (entry.title?.isEmpty == false ? entry.title! : "无标题"))
                                    .font(.headline)
                                Text(entry.body).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                                Text(entry.dayDate).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        if previewEntries.count > 4 {
                            Text("还有 \(previewEntries.count - 4) 篇按日期继续排版…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(options.style.rawValue + " · " + options.paper.rawValue)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("预览与最终 PDF 共用同一套年度内容快照；实际页数以排版完成后为准。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var estimatedPages: Int {
        max(2, Int(ceil(Double(max(1, previewEntries.reduce(0) { $0 + max(1, $1.body.count) })) / (options.paper == .a5 ? 1500 : 2600))) + 2)
    }

    private var previewSubtitle: String {
        switch options.style {
        case .plain: return "\(year) 年度日记本 · 素纸文集"
        case .journal: return "\(year) 年度日记本 · 时光手帐"
        case .album: return "\(year) 年度影集"
        }
    }

    private var previewPaper: Color {
        switch options.style {
        case .plain: return Palette.paper
        case .journal: return Palette.paper.opacity(0.98)
        case .album: return Palette.adaptive(light: "#F7F5EF", dark: "#242422")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = "导出年度日记本"
        panel.nameFieldStringValue = "晤言-\(year)-\(options.style.rawValue).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        statusMessage = "正在生成 PDF…"
        Task {
            do {
                let report = try ExportService().exportYearbook(database: appState.db, options: options, to: url)
                statusMessage = "已导出 \(report.pages) 页：\(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                statusMessage = error.localizedDescription
            }
            isExporting = false
        }
    }
}
