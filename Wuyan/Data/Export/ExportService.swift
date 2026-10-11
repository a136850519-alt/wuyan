import AppKit
import CoreText
import CryptoKit
import Foundation
import GRDB

/// 完整备份文档：包含所有数据表，不止 entries
struct BackupDocument: Codable {
    var schemaVersion: Int = 1
    var boards: [Board]
    var dayNotes: [DayNote]
    var entries: [Entry]
    var mediaAssets: [MediaAsset]
}

/// UI-03：完整备份清单——数据库内容 + 媒体文件校验信息（哈希逐一验证后才允许还原）。
struct FullBackupManifest: Codable {
    var schemaVersion: Int = 2
    var createdAt: Date
    var appVersion: String
    var database: BackupDocument
    var mediaFiles: [MediaFile]

    struct MediaFile: Codable, Equatable {
        var filename: String
        var sha256: String
        var size: Int64
    }
}

/// UI-03：还原结果报告。
struct FullBackupRestoreReport {
    var importedEntries: Int
    var skippedEntries: Int
    var restoredMediaFiles: Int
    var missingLocalCopies: Int
    var snapshotURL: URL
}

/// UI-03：备份包错误——任何校验失败都在写入前中止，保证原数据库不变。
enum BackupError: LocalizedError {
    case corruptPackage(String)
    case missingMediaFile(String)
    case mediaChecksumMismatch(String)
    case exportChecksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case let .corruptPackage(detail):
            return "备份包损坏：\(detail)。原数据库未修改。"
        case let .missingMediaFile(name):
            return "备份包缺少媒体文件：\(name)。还原已中止，原数据库未修改。"
        case let .mediaChecksumMismatch(name):
            return "备份媒体校验失败：\(name)。还原已中止，原数据库未修改。"
        case let .exportChecksumMismatch(path):
            return "导出中止：本地文件与元数据哈希不一致（\(path)），可能已损坏。"
        }
    }
}

enum ImportConflictStrategy: Equatable {
    case skipExisting   // 已存在的条目（同 ID）保留本地，跳过备份版本
    case overwrite      // 备份版本覆盖已存在的条目
}

final class ExportService {
    func exportMarkdown(entries: [Entry], mediaDAO: MediaAssetDAO? = nil, dayNotes: DayNoteDAO? = nil, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mediaDirectory = directory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        var usedFilenames = Set<String>()
        for entry in entries {
            let filename = "\(entry.dayDate)-\(entry.id.uuidString).md"
            let url = directory.appendingPathComponent(filename)
            let assets = (try? mediaDAO?.allAssets(for: entry.mediaIds)) ?? []
            // R0-9: 先计算所有 safeName 映射，确保 Markdown 链接与实际复制文件名一致
            let assetSafeNames: [UUID: String] = Dictionary(uniqueKeysWithValues: assets.compactMap { asset -> (UUID, String)? in
                guard asset.localPath != nil else { return nil }
                let prefix = String(asset.sha256.prefix(8))
                let filename = URL(fileURLWithPath: asset.filename).lastPathComponent
                guard !filename.isEmpty, filename != ".", filename != ".." else { return nil }
                let candidate = "\(prefix)-\(filename)"
                let safeName: String
                if usedFilenames.insert(candidate).inserted {
                    safeName = candidate
                } else {
                    // 极端情况：同 sha256 同名（不可能但防御性编码）
                    safeName = "\(prefix)-\(asset.id.uuidString.prefix(8))-\(filename)"
                    usedFilenames.insert(safeName)
                }
                return (asset.id, safeName)
            })
            for asset in assets {
                if let safeName = assetSafeNames[asset.id] {
                    // R2-1: 使用模型层计算属性替代 LocalMediaStore.resolvePath
                    if let absolutePath = asset.absoluteLocalPath {
                        let destination = mediaDirectory.appendingPathComponent(safeName)
                        if !FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.copyItem(at: URL(fileURLWithPath: absolutePath), to: destination)
                        }
                    }
                }
            }
            // Markdown 链接使用同一 safeName 映射
            let mediaLinks = assets.compactMap { asset -> String? in
                guard asset.localPath != nil, let safeName = assetSafeNames[asset.id] else { return nil }
                return "![\(asset.filename)](media/\(safeName))"
            }.joined(separator: "\n")
            let effectiveMood: Int?
            if let dayNotes {
                effectiveMood = try dayNotes.effectiveMood(dayKey: entry.dayDate)
            } else {
                effectiveMood = entry.mood
            }
            let frontmatter = """
            ---
            id: \(entry.id.uuidString)
            boardId: \(entry.boardId.uuidString)
            journalDate: \(ISO8601DateFormatter().string(from: entry.journalDate))
            tags: \(entry.tags.joined(separator: ", "))
            mood: \(effectiveMood.map(String.init) ?? "")
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

    // MARK: - UI-03（已确认）：完整备份包（清单 + 媒体文件，可独立恢复）

    /// 创建完整备份包：目录内含 backup.json（版本+校验清单+全部数据表，含回收站条目）
    /// 与 media/ 下的媒体文件。导出时逐一校验本地文件哈希，不一致立即中止。
    /// 返回备份的条目数。
    @discardableResult
    func exportFullBackupPackage(database: AppDatabase, to directory: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let mediaDirectory = directory.appendingPathComponent("media", isDirectory: true)
        try fm.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

        // 完整范围：全部未删除条目 + 回收站条目（备份必须完整往返，含已删除内容）
        var entries = try database.entryDAO.timeline(filter: .all)
        entries += try database.entryDAO.trashedEntries()
        let boards = try database.boardDAO.all()
        let dayNotes = try database.dayNoteDAO.all()
        let assets = try database.mediaAssetDAO.allAssets()
        let referencedAssetIDs = Set(entries.flatMap(\.mediaIds))

        var mediaFiles: [FullBackupManifest.MediaFile] = []
        // A07：媒体按完整内容哈希去重——多个条目引用同一内容的附件（含同名）只打包
        // 一份文件、一条清单项。还原端按 sha256 定位文件，引用计数不受影响。
        // 绝不允许清单出现重复文件名：导入器会视其为损坏包而拒绝整个还原。
        var packagedBySHA: [String: FullBackupManifest.MediaFile] = [:]
        var usedNames = Set<String>()
        for asset in assets {
            // localPath 非空表示数据库认为本机持有唯一副本；静默跳过会生成一个
            // “完整备份”却无法恢复的包，因此必须显式失败。
            guard let absolutePath = asset.absoluteLocalPath else {
                if referencedAssetIDs.contains(asset.id) {
                    throw BackupError.missingMediaFile(asset.filename)
                }
                continue
            }
            guard fm.fileExists(atPath: absolutePath) else {
                throw BackupError.missingMediaFile(absolutePath)
            }
            let sourceURL = URL(fileURLWithPath: absolutePath)
            let hex = try Hashing.sha256Hex(ofFileAt: sourceURL)
            // 导出校验：文件实际内容必须与元数据 sha256 一致，否则不产出不可信的备份
            guard hex == asset.sha256 else {
                throw BackupError.exportChecksumMismatch(absolutePath)
            }
            if let existing = packagedBySHA[hex] {
                // 同内容附件已打包：复用既有清单项，不重复写文件。
                _ = existing
                continue
            }
            let safeFilename = URL(fileURLWithPath: asset.filename).lastPathComponent
            guard !safeFilename.isEmpty, safeFilename != ".", safeFilename != ".." else {
                throw BackupError.corruptPackage("媒体文件名无效：\(asset.filename)")
            }
            var name = "\(asset.sha256.prefix(8))-\(safeFilename)"
            if !usedNames.insert(name).inserted {
                name = "\(asset.sha256)-\(safeFilename)"
            }
            // 任意多次重复也必须得到唯一名称（不同内容、同短前缀 + 同名的兜底）。
            if !usedNames.insert(name).inserted {
                name = "\(asset.sha256)-\(asset.id.uuidString)-\(safeFilename)"
                _ = usedNames.insert(name)
            }
            let destination = mediaDirectory.appendingPathComponent(name)
            try fm.copyItem(at: sourceURL, to: destination)
            let fileSize = (try fm.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let packaged = FullBackupManifest.MediaFile(filename: name, sha256: hex, size: fileSize)
            packagedBySHA[hex] = packaged
            mediaFiles.append(packaged)
        }

        let packagedShas = Set(mediaFiles.map(\.sha256))
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for entry in entries {
            for mediaID in entry.mediaIds {
                guard let asset = assetsByID[mediaID] else {
                    throw BackupError.corruptPackage("条目 \(entry.id) 引用了不存在的媒体记录 \(mediaID)")
                }
                if !packagedShas.contains(asset.sha256) {
                    throw BackupError.missingMediaFile(asset.filename)
                }
            }
        }

        let doc = BackupDocument(schemaVersion: 1, boards: boards, dayNotes: dayNotes, entries: entries, mediaAssets: assets)
        let manifest = FullBackupManifest(
            createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            database: doc,
            mediaFiles: mediaFiles
        )
        let manifestData = try JSONEncoder.wuyan.encode(manifest)
        try manifestData.write(to: directory.appendingPathComponent("backup.json"), options: .atomic)
        return entries.count
    }

    /// 从完整备份包还原。流程（UI-01 已确认语义）：
    /// 1) 全量校验清单与媒体文件哈希——任何缺失/损坏即报错，原库不变；
    /// 2) 自动快照当前数据库到 snapshots/（还原前的回退材料）；
    /// 3) 单事务导入板块/日札/条目（同 ID 按 strategy 跳过或覆盖，dirty=true 以便推送同步）；
    /// 4) 恢复媒体文件到本地媒体库（已有本地文件的跳过，缺失的计数报告，可随后从远端下载）。
    @discardableResult
    func importFullBackupPackage(
        from directory: URL,
        database: AppDatabase,
        mediaStore: LocalMediaStore,
        strategy: ImportConflictStrategy
    ) throws -> FullBackupRestoreReport {
        let fm = FileManager.default
        let manifestURL = directory.appendingPathComponent("backup.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw BackupError.corruptPackage("缺少 backup.json")
        }
        let manifest: FullBackupManifest
        do {
            manifest = try JSONDecoder.wuyan.decode(FullBackupManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw BackupError.corruptPackage("backup.json 无法解析（\(error.localizedDescription)）")
        }
        guard (1...2).contains(manifest.schemaVersion) else {
            throw BackupError.corruptPackage("不支持的备份版本：\(manifest.schemaVersion)")
        }

        // 1) 校验：清单中的每个媒体文件都必须存在且哈希一致
        let mediaDirectory = directory.appendingPathComponent("media", isDirectory: true)
        for file in manifest.mediaFiles {
            guard let url = Self.safeMediaURL(file.filename, in: mediaDirectory)
            else {
                throw BackupError.corruptPackage("媒体文件名无效或重复：\(file.filename)")
            }
            guard fm.fileExists(atPath: url.path) else {
                throw BackupError.missingMediaFile(file.filename)
            }
            let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard size == file.size else {
                throw BackupError.mediaChecksumMismatch(file.filename)
            }
            let hex = try Hashing.sha256Hex(ofFileAt: url)
            guard hex == file.sha256 else {
                throw BackupError.mediaChecksumMismatch(file.filename)
            }
        }

        let manifestAssets = Dictionary(grouping: manifest.database.mediaAssets, by: \.id)
        let manifestFilesBySHA = Dictionary(grouping: manifest.mediaFiles, by: \.sha256)
        for entry in manifest.database.entries {
            for mediaID in entry.mediaIds {
                guard let asset = manifestAssets[mediaID]?.first else {
                    throw BackupError.corruptPackage("条目 \(entry.id) 引用了不存在的媒体记录 \(mediaID)")
                }
                if asset.localPath != nil && manifestFilesBySHA[asset.sha256] == nil {
                    throw BackupError.missingMediaFile(asset.filename)
                }
            }
        }

        // 2) 还原前自动快照
        let snapshotURL = try Self.snapshotDatabase(database: database)

        // 3) 先把媒体落到内容寻址目录，但暂不改数据库。这样媒体失败发生在
        // 数据库事务之前，数据库不会出现“元数据已导入、文件未恢复”的半成品。
        var restoredAssets = manifest.database.mediaAssets
        var createdMediaURLs: [URL] = []
        var restoredMedia = 0
        do {
            for index in restoredAssets.indices {
                let asset = restoredAssets[index]
                guard asset.localPath != nil else { continue }
                guard let file = manifest.mediaFiles.first(where: { $0.sha256 == asset.sha256 }),
                      let sourceURL = Self.safeMediaURL(file.filename, in: mediaDirectory)
                else {
                    throw BackupError.missingMediaFile(asset.filename)
                }
                let targetURL = mediaStore.localMediaURL(for: asset)
                let existed = fm.fileExists(atPath: targetURL.path)
                if existed {
                    let existingSHA = try Hashing.sha256Hex(ofFileAt: targetURL)
                    if existingSHA != asset.sha256 {
                        throw BackupError.corruptPackage("本地媒体文件已存在但校验不一致：\(targetURL.path)")
                    }
                }
                let materialized = try mediaStore.materializeMediaFile(from: sourceURL, for: asset)
                if !existed {
                    createdMediaURLs.append(materialized)
                    restoredMedia += 1
                }
                var normalized = asset
                normalized.localPath = LocalMediaStore.toRelativePath(materialized.path)
                restoredAssets[index] = normalized
            }
        } catch {
            for url in createdMediaURLs {
                try? fm.removeItem(at: url)
            }
            throw error
        }

        // 4) 单事务导入。skipExisting 时，条目及其专属媒体元数据一并跳过，
        // 避免“条目没覆盖但附件元数据被覆盖”的半套恢复结果。
        let existingEntryIDs = Set((try database.entryDAO.timeline(filter: .all) + database.entryDAO.trashedEntries()).map(\.id))
        let entriesToImport = manifest.database.entries.filter {
            strategy == .overwrite || !existingEntryIDs.contains($0.id)
        }
        let importedMediaIDs = Set(entriesToImport.flatMap(\.mediaIds))
        let allReferencedMediaIDs = Set(manifest.database.entries.flatMap(\.mediaIds))

        // 4) 单事务导入
        var imported = 0
        var skipped = 0
        do {
            try database.writer.write { db in
                for board in manifest.database.boards {
                    if try Board.fetchOne(db, key: board.id.uuidString) == nil {
                        try board.save(db)
                    }
                }
                for note in manifest.database.dayNotes {
                    if strategy == .skipExisting,
                       try DayNote.fetchOne(db, key: note.date) != nil {
                        continue
                    }
                    try note.save(db)
                }
                for entry in manifest.database.entries {
                    let exists = try Entry.fetchOne(db, key: entry.id.uuidString) != nil
                    if exists, strategy == .skipExisting {
                        skipped += 1
                        continue
                    }
                    var restored = entry
                    restored.dirty = true
                    try restored.save(db)
                    imported += 1
                }
                for asset in restoredAssets where !allReferencedMediaIDs.contains(asset.id) || importedMediaIDs.contains(asset.id) {
                    try asset.save(db)
                }
            }
        } catch {
            for url in createdMediaURLs {
                try? fm.removeItem(at: url)
            }
            throw error
        }

        // 5) 包中 localPath 为空的资产没有本地副本，保留 nil 路径供后续远端补齐。
        var missingLocalCopies = 0
        missingLocalCopies = manifest.database.mediaAssets.filter { $0.localPath == nil }.count

        return FullBackupRestoreReport(
            importedEntries: imported,
            skippedEntries: skipped,
            restoredMediaFiles: restoredMedia,
            missingLocalCopies: missingLocalCopies,
            snapshotURL: snapshotURL
        )
    }

    private static func safeMediaURL(_ filename: String, in directory: URL) -> URL? {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/"),
              !filename.contains("\\")
        else { return nil }
        let url = directory.appendingPathComponent(filename)
        let root = directory.standardizedFileURL.path.hasSuffix("/")
            ? directory.standardizedFileURL.path
            : directory.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(root) ? url : nil
    }

    /// 还原前快照：用 GRDB backup API 把当前库一致性地复制到 snapshots/（含回退材料）。
    static func snapshotDatabase(database: AppDatabase) throws -> URL {
        let fm = FileManager.default
        let mediaRoot = LocalMediaStore.mediaRootURL
        let directory = mediaRoot.appendingPathComponent("snapshots", isDirectory: true)
        try migrateLegacySnapshots(from: mediaRoot.deletingLastPathComponent().appendingPathComponent("snapshots", isDirectory: true), to: directory, fileManager: fm)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("pre-restore-\(Int(Date().timeIntervalSince1970)).sqlite")
        let target = try DatabaseQueue(path: url.path)
        try database.writer.backup(to: target)
        let snapshots = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { isRestoreSnapshot($0.lastPathComponent) }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        for old in snapshots.dropFirst(5) {
            try? fm.removeItem(at: old)
        }
        return url
    }

    private static func isRestoreSnapshot(_ name: String) -> Bool {
        name.hasPrefix("pre-restore-") && name.hasSuffix(".sqlite")
    }

    /// Move only snapshots created by Wuyan out of the legacy shared directory.
    /// Other applications may use that directory, so unrelated files stay put.
    private static func migrateLegacySnapshots(from legacy: URL, to destination: URL, fileManager: FileManager) throws {
        guard legacy.standardizedFileURL != destination.standardizedFileURL,
              fileManager.fileExists(atPath: legacy.path)
        else { return }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let candidates = try fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { isRestoreSnapshot($0.lastPathComponent) }
        for file in candidates {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            try fileManager.moveItem(at: file, to: target)
        }
        let remaining = try fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        if remaining.isEmpty {
            try? fileManager.removeItem(at: legacy)
        }
    }

    func importJSON(from url: URL, database: AppDatabase) throws -> Int {
        let data = try Data(contentsOf: url)
        // Legacy JSON imports can overwrite IDs and are therefore reversible
        // only when they take the same pre-restore snapshot as full restores.
        _ = try Self.snapshotDatabase(database: database)
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
        // 合并所有条目为一个带分隔的富文本
        let fullText = entries.map { entry in
            "\(entry.title ?? "未命名")\n\(entry.journalDate)\n\n\(entry.body)"
        }.joined(separator: "\n\n---\n\n")

        // 使用霞鹜文楷字体（产品气质一致），回退到系统衬线体
        let font = NSFont(name: WuyanFont.bundledSerifName, size: 13) ?? NSFont.systemFont(ofSize: 13)
        let attributed = NSAttributedString(string: fullText, attributes: [.font: font])

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { return }

        let pageWidth: CGFloat = 595
        let pageHeight: CGFloat = 842
        let marginX: CGFloat = 48
        let marginY: CGFloat = 48
        let contentWidth = pageWidth - 2 * marginX
        let contentHeight = pageHeight - 2 * marginY

        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var currentIndex = 0
        let totalLength = attributed.length

        while currentIndex < totalLength {
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)] as CFDictionary)

            let path = CGPath(rect: CGRect(x: marginX, y: marginY, width: contentWidth, height: contentHeight), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: currentIndex, length: totalLength - currentIndex), path, nil)
            let visibleRange = CTFrameGetVisibleStringRange(frame)

            CTFrameDraw(frame, context)
            context.endPDFPage()

            if visibleRange.length <= 0 { break }
            currentIndex += visibleRange.length
        }

        context.closePDF()
        try data.write(to: url, options: .atomic)
    }
}
