import AppKit
import CoreText
import Foundation

enum YearbookStyle: String, CaseIterable, Identifiable {
    case plain = "素纸文集"
    case journal = "时光手帐"
    case album = "年度影集"
    var id: String { rawValue }
}

enum YearbookPaper: String, CaseIterable, Identifiable {
    case a5 = "A5"
    case a4 = "A4"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .a5: return CGSize(width: 419.5, height: 595.3)
        case .a4: return CGSize(width: 595.3, height: 841.9)
        }
    }
}

struct YearbookOptions {
    var year: Int
    var title: String
    var style: YearbookStyle
    var paper: YearbookPaper
    var includeEntries = true
    var includeDayNotes = true
    var includePhotos = true
    var includeDrafts = false
    var includeTrash = false
    var followTheme = true
}

struct YearbookExportReport {
    var pages: Int
    var entryCount: Int
    var outputURL: URL
}

extension ExportService {
    func exportYearbook(database: AppDatabase, options: YearbookOptions, to url: URL) throws -> YearbookExportReport {
        let prefix = String(format: "%04d-", options.year)
        var entries = options.includeTrash ? try database.entryDAO.timeline(filter: .all) + database.entryDAO.trashedEntries() : try database.entryDAO.timeline(filter: .all)
        entries = entries.filter { $0.dayDate.hasPrefix(prefix) && (options.includeDrafts || !$0.isDraft) }
            .sorted { $0.dayDate == $1.dayDate ? ($0.journalDate, $0.id.uuidString) < ($1.journalDate, $1.id.uuidString) : $0.dayDate < $1.dayDate }
        let notes = options.includeDayNotes ? try database.dayNoteDAO.all().filter { $0.date.hasPrefix(prefix) }.sorted { $0.date < $1.date } : []
        guard !entries.isEmpty || !notes.isEmpty else { throw YearArchiveError.emptyArchive }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy 年 M 月 d 日"
        let actualDates = entries.map(\.dayDate) + notes.map(\.date)
        let dateRange = actualDates.sorted().first.map { first in
            let last = actualDates.sorted().last ?? first
            return "收录 \(first) 至 \(last)"
        } ?? "本年度暂无日期记录"

        let pageSize = options.paper.size
        let innerMargin: CGFloat = {
            let base: CGFloat = options.paper == .a5 ? 54 : 68
            switch options.style {
            case .plain: return base + 10
            case .journal: return base
            case .album: return max(42, base - 8)
            }
        }()
        let fontSize: CGFloat = {
            let base: CGFloat = options.paper == .a5 ? 11.5 : 13
            return options.style == .album ? base + 0.5 : base
        }()
        let bodyFont = NSFont(name: WuyanFont.bundledSerifName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let titleFont = NSFont(name: WuyanFont.bundledSerifName, size: fontSize + (options.style == .album ? 11 : 8)) ?? NSFont.systemFont(ofSize: fontSize + 8, weight: .semibold)
        let headingFont = NSFont(name: WuyanFont.bundledSerifName, size: fontSize + 3) ?? NSFont.systemFont(ofSize: fontSize + 3, weight: .semibold)
        let paragraph = NSMutableAttributedString()
        func add(_ text: String, _ font: NSFont, _ color: NSColor = .textColor, _ spacing: CGFloat = 7) {
            paragraph.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: Self.paragraphStyle(lineSpacing: spacing)
            ]))
        }

        let themeColor = options.followTheme ? NSColor(AppSettings.yearThemeValue(options.year).color) : .textColor
        let styleColor: NSColor = {
            switch options.style {
            case .plain: return .textColor
            case .journal: return themeColor
            case .album: return themeColor
            }
        }()
        add(options.title.isEmpty ? "\(options.year) · 日记" : options.title, titleFont, themeColor, 14)
        let subtitle = options.style == .album ? "年度影集 · \(dateRange)" : "\(options.year) 年度日记本\n\(dateRange)"
        add("\n\(subtitle)\n收录 \(entries.count) 篇日记 · \(notes.count) 条日札\n\n", bodyFont, .secondaryLabelColor, 9)
        add(options.style == .plain ? "扉页\n" : options.style == .journal ? "扉页 · 此刻\n" : "扉页 · 影像索引\n", headingFont, styleColor, 8)
        let intro = options.style == .album
            ? "照片按原始比例嵌入，长文会自然续页；缺少照片时保留文字记录。\n\n"
            : "这本日记本按晤言中的真实日期排版。未选择的草稿和回收站内容不会出现在本次导出中。\n\n"
        add(intro, bodyFont, .secondaryLabelColor)
        add(options.style == .album ? "月份 · 影集目录\n" : "月份目录\n", headingFont, styleColor, 8)
        let months = Set(entries.compactMap { Int($0.dayDate.dropFirst(5).prefix(2)) }).sorted()
        add(months.map { "\($0) 月" }.joined(separator: "    ") + "\n\n", bodyFont, .secondaryLabelColor)

        var lastMonth = ""
        for entry in entries where options.includeEntries {
            let month = String(entry.dayDate.prefix(7))
            if month != lastMonth {
                lastMonth = month
                let monthHeading = options.style == .album ? "\nMONTH · \(month)\n" : "\n\(month)\n"
                add(monthHeading, headingFont, styleColor, 9)
            }
            let date = dateFormatter.string(from: entry.journalDate)
            let title = entry.title?.isEmpty == false ? entry.title! : "无标题"
            let state = entry.deleted ? " · 回收站" : entry.isDraft ? " · 草稿" : ""
            let dateHeading = options.style == .journal ? "\n· \(date)\(state)\n\(title)\n" : "\n\(date)\(state)\n\(title)\n"
            add(dateHeading, headingFont, .textColor, options.style == .plain ? 6 : 8)
            add(entry.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", bodyFont, .textColor, 7)
            if !entry.tags.isEmpty { add("标签：\(entry.tags.joined(separator: "、"))\n", bodyFont, .secondaryLabelColor, 5) }
            if options.includePhotos, !entry.mediaIds.isEmpty {
                let assets = (try? database.mediaAssetDAO.allAssets(for: entry.mediaIds)) ?? []
                for asset in assets {
                    switch asset.type {
                    case .photo:
                        guard let path = asset.absoluteLocalPath,
                              let image = NSImage(contentsOfFile: path) else {
                            throw YearArchiveError.missingMedia(asset.filename)
                        }
                        let maxWidth = pageSize.width - innerMargin * 2
                        let scale = min(1, maxWidth / max(image.size.width, 1))
                        let attachment = NSTextAttachment()
                        attachment.image = image
                        attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
                        paragraph.append(NSAttributedString(attachment: attachment))
                        add("\n照片：\(asset.filename)\n", bodyFont, .secondaryLabelColor, 4)
                    case .audio: add("音频附件：\(asset.filename)\(asset.durationSec.map { String(format: " · %.0f 秒", $0) } ?? "")\n", bodyFont, .secondaryLabelColor, 4)
                    case .video: add("视频附件：\(asset.filename)\(asset.durationSec.map { String(format: " · %.0f 秒", $0) } ?? "")\n", bodyFont, .secondaryLabelColor, 4)
                    }
                }
                add("音视频原件未包含在此 PDF 中。\n", bodyFont, .tertiaryLabelColor, 4)
            }
        }
        if options.includeDayNotes {
            var noteDates = Set<String>()
            for note in notes where noteDates.insert(note.date).inserted {
                add("\n日札 · \(note.date)\n", headingFont, themeColor, 7)
                if !note.rawSummary.isEmpty { add(note.rawSummary + "\n", bodyFont, .textColor, 5) }
                if !note.poeticLine.isEmpty { add(note.poeticLine + "\n", bodyFont, .secondaryLabelColor, 5) }
            }
        }
        add("\n\n—— 晤言 · \(options.year) ——\n", bodyFont, .secondaryLabelColor, 8)

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw YearArchiveError.corrupt("无法创建 PDF 输出")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(paragraph)
        var currentIndex = 0
        var pages = 0
        while currentIndex < paragraph.length {
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            Self.drawPageDecoration(context: context, pageSize: pageSize, margin: innerMargin, style: options.style, color: styleColor)
            let path = CGPath(rect: CGRect(x: innerMargin, y: innerMargin, width: pageSize.width - innerMargin * 2, height: pageSize.height - innerMargin * 2), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: currentIndex, length: paragraph.length - currentIndex), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            pages += 1
            guard visible.length > 0 else { break }
            currentIndex += visible.length
        }
        context.closePDF()
        try data.write(to: url, options: .atomic)
        return YearbookExportReport(pages: pages, entryCount: entries.count, outputURL: url)
    }

    private static func paragraphStyle(lineSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private static func drawPageDecoration(context: CGContext, pageSize: CGSize, margin: CGFloat, style: YearbookStyle, color: NSColor) {
        switch style {
        case .plain:
            context.setStrokeColor(color.withAlphaComponent(0.28).cgColor)
            context.setLineWidth(0.7)
            context.move(to: CGPoint(x: margin, y: pageSize.height - margin + 14))
            context.addLine(to: CGPoint(x: pageSize.width - margin, y: pageSize.height - margin + 14))
            context.strokePath()
        case .journal:
            context.setFillColor(color.withAlphaComponent(0.10).cgColor)
            let dotSize: CGFloat = 1.2
            stride(from: margin, to: pageSize.width - margin, by: 12).forEach { x in
                stride(from: margin, to: pageSize.height - margin, by: 12).forEach { y in
                    context.fill(CGRect(x: x, y: y, width: dotSize, height: dotSize))
                }
            }
        case .album:
            context.setFillColor(color.withAlphaComponent(0.18).cgColor)
            context.fill(CGRect(x: 0, y: pageSize.height - 18, width: pageSize.width, height: 18))
            context.setStrokeColor(color.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: margin, y: 22))
            context.addLine(to: CGPoint(x: pageSize.width - margin, y: 22))
            context.strokePath()
        }
    }
}
