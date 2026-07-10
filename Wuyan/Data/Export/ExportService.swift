import AppKit
import CoreText
import Foundation

/// 完整备份文档：包含所有数据表，不止 entries
struct BackupDocument: Codable {
    var schemaVersion: Int = 1
    var boards: [Board]
    var dayNotes: [DayNote]
    var entries: [Entry]
    var mediaAssets: [MediaAsset]
}

final class ExportService {
    func exportMarkdown(entries: [Entry], mediaDAO: MediaAssetDAO? = nil, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mediaDirectory = directory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        for entry in entries {
            let filename = "\(entry.dayDate)-\(entry.id.uuidString).md"
            let url = directory.appendingPathComponent(filename)
            let assets = (try? mediaDAO?.allAssets(for: entry.mediaIds)) ?? []
            for asset in assets {
                if let localPath = asset.localPath {
                    let absolutePath = LocalMediaStore.resolvePath(localPath)
                    let destination = mediaDirectory.appendingPathComponent(asset.filename)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try? FileManager.default.copyItem(at: URL(fileURLWithPath: absolutePath), to: destination)
                    }
                }
            }
            let mediaLinks = assets.map { "![\($0.filename)](media/\($0.filename))" }.joined(separator: "\n")
            let frontmatter = """
            ---
            id: \(entry.id.uuidString)
            boardId: \(entry.boardId.uuidString)
            journalDate: \(ISO8601DateFormatter().string(from: entry.journalDate))
            tags: \(entry.tags.joined(separator: ", "))
            mood: \(entry.mood.map(String.init) ?? "")
            favorite: \(entry.isFavorite)
            ---

            """
            try (frontmatter + "# \(entry.title ?? "未命名")\n\n" + entry.body + "\n\n" + mediaLinks).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func exportJSON(entries: [Entry], to url: URL) throws {
        let data = try JSONEncoder.wuyan.encode(entries)
        try data.write(to: url, options: .atomic)
    }

    /// 导出完整备份（包含 boards/dayNotes/entries/mediaAssets），替代只导 entries 的旧版
    func exportFullBackup(database: AppDatabase, to url: URL) throws {
        let boards = try database.boardDAO.all()
        let dayNotes = try database.dayNoteDAO.all()
        let entries = try database.entryDAO.timeline(filter: .all)
        let mediaAssets = try database.mediaAssetDAO.allAssets()
        let doc = BackupDocument(
            schemaVersion: 1,
            boards: boards,
            dayNotes: dayNotes,
            entries: entries,
            mediaAssets: mediaAssets
        )
        let data = try JSONEncoder.wuyan.encode(doc)
        try data.write(to: url, options: .atomic)
    }

    func importJSON(from url: URL, database: AppDatabase) throws -> Int {
        let data = try Data(contentsOf: url)
        // 先尝试完整备份格式，失败回退旧格式（纯 entries 数组）
        if let doc = try? JSONDecoder.wuyan.decode(BackupDocument.self, from: data) {
            return try importBackupDocument(doc, database: database)
        }
        // 旧格式兼容
        let entries = try JSONDecoder.wuyan.decode([Entry].self, from: data)
        for entry in entries {
            if try database.boardDAO.board(id: entry.boardId) == nil,
               let fallback = try database.boardDAO.all().first {
                var repaired = entry
                repaired.boardId = fallback.id
                try database.entryDAO.save(repaired)
            } else {
                try database.entryDAO.save(entry)
            }
            try database.entryDAO.upsertBaseline(for: entry)
        }
        return entries.count
    }

    private func importBackupDocument(_ doc: BackupDocument, database: AppDatabase) throws -> Int {
        // 导入板块（跳过已存在的内置板块）
        for board in doc.boards {
            if try database.boardDAO.board(id: board.id) == nil {
                try database.boardDAO.save(board)
            }
        }
        // 导入每日一句
        for note in doc.dayNotes {
            try database.dayNoteDAO.upsert(note)
        }
        // 导入条目（dirty=true，确保还原后可推送同步）
        for entry in doc.entries {
            if try database.boardDAO.board(id: entry.boardId) == nil,
               let fallback = try database.boardDAO.all().first {
                var repaired = entry
                repaired.boardId = fallback.id
                repaired.dirty = true
                try database.entryDAO.save(repaired)
            } else {
                var dirtyEntry = entry
                dirtyEntry.dirty = true
                try database.entryDAO.save(dirtyEntry)
            }
        }
        // 导入媒体元数据
        for asset in doc.mediaAssets {
            try? database.mediaAssetDAO.save(asset)
        }
        return doc.entries.count
    }

    func exportPDF(entries: [Entry], to url: URL) throws {
        let text = entries.map { entry in
            "\(entry.title ?? "未命名")\n\(entry.journalDate)\n\n\(entry.body)"
        }.joined(separator: "\n\n---\n\n")
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { return }
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)] as CFDictionary)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 48, y: 48, width: 499, height: 746), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
        context.closePDF()
        try data.write(to: url, options: .atomic)
    }
}
