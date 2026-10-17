import CryptoKit
import Foundation

struct YearArchiveSummary: Equatable {
    var year: Int
    var entryCount: Int
    var dayNoteCount: Int
    var attachmentCount: Int
    var bytes: Int64
    var draftCount: Int
    var trashCount: Int

    var hasContent: Bool { entryCount > 0 || dayNoteCount > 0 || trashCount > 0 }
}

struct YearArchiveSnapshot {
    let year: Int
    let entries: [Entry]
    let dayNotes: [DayNote]
    let mediaAssets: [MediaAsset]
}

struct YearArchiveContents {
    let snapshot: YearArchiveSnapshot
    let boards: [Board]
    let mediaDataByID: [UUID: Data]
}

struct YearArchiveCleanupResult {
    let removedEntries: Int
    let retainedEntries: Int
    let removedMedia: Int
}

struct YearArchiveRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var year: Int
    var destination: String
    var location: String?
    var createdAt: Date
    var status: String
    var retainedCount: Int

    var sourceLabel: String {
        destination == "local" ? "本地文件" : "WebDAV"
    }
}

private struct YearArchivePayload: Codable {
    var magic = "WUYAN-ARCHIVE"
    var schemaVersion = 1
    var year: Int
    var createdAt: Date
    var theme: String
    var document: BackupDocument
    var mediaBlobs: [MediaBlob]

    struct MediaBlob: Codable {
        var id: UUID
        var sha256: String
        var size: Int64
        var dataBase64: String
    }
}

private struct YearArchiveContainer: Codable {
    var magic = "WUYANARCHIVE"
    var version = 1
    var algorithm = "AES-GCM"
    var kdf = "PBKDF2-HMAC-SHA256"
    var saltBase64: String
    var iterations: Int
    var ciphertextBase64: String
}

enum YearArchiveError: LocalizedError {
    case unsupportedYear
    case emptyArchive
    case missingMedia(String)
    case checksumMismatch(String)
    case invalidPassword
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedYear: return "当前年份和未来年份不能归档，请在年份结束后重试。"
        case .emptyArchive: return "所选年份没有可归档内容。"
        case let .missingMedia(name): return "附件缺失：\(name)。完整归档已中止，本地内容保留。"
        case let .checksumMismatch(name): return "附件校验失败：\(name)。完整归档已中止，本地内容保留。"
        case .invalidPassword: return "无法解密归档，请检查口令或文件完整性。"
        case let .corrupt(detail): return "归档文件损坏：\(detail)。"
        }
    }
}

final class YearArchiveService {
    private let crypto = AESGCMCryptoBox()

    func summary(year: Int, database: AppDatabase) throws -> YearArchiveSummary {
        let prefix = String(format: "%04d-", year)
        let active = try database.entryDAO.timeline(filter: .all).filter { $0.dayDate.hasPrefix(prefix) }
        let trash = try database.entryDAO.trashedEntries().filter { $0.dayDate.hasPrefix(prefix) }
        let notes = try database.dayNoteDAO.all().filter { $0.date.hasPrefix(prefix) }
        let ids = Set((active + trash).flatMap(\.mediaIds))
        let assets = try database.mediaAssetDAO.allAssets(for: Array(ids))
        return YearArchiveSummary(
            year: year,
            entryCount: active.count,
            dayNoteCount: notes.count,
            attachmentCount: assets.count,
            bytes: assets.reduce(0) { $0 + $1.size },
            draftCount: active.filter(\.isDraft).count + trash.filter(\.isDraft).count,
            trashCount: trash.count
        )
    }

    func createArchive(year: Int, password: String, to url: URL, database: AppDatabase) throws -> YearArchiveSnapshot {
        guard year < (Int(DayKey.today.prefix(4)) ?? Calendar.current.component(.year, from: Date())) else { throw YearArchiveError.unsupportedYear }
        guard !password.isEmpty else { throw YearArchiveError.invalidPassword }

        let prefix = String(format: "%04d-", year)
        let entries = try database.entryDAO.timeline(filter: .all).filter { $0.dayDate.hasPrefix(prefix) }
            + database.entryDAO.trashedEntries().filter { $0.dayDate.hasPrefix(prefix) }
        let dayNotes = try database.dayNoteDAO.all().filter { $0.date.hasPrefix(prefix) }
        guard !entries.isEmpty || !dayNotes.isEmpty else { throw YearArchiveError.emptyArchive }
        let ids = Set(entries.flatMap(\.mediaIds))
        let assets = try database.mediaAssetDAO.allAssets(for: Array(ids))
        let boards = try database.boardDAO.all().filter { Set(entries.map(\.boardId)).contains($0.id) }

        var blobs: [YearArchivePayload.MediaBlob] = []
        for asset in assets {
            guard let path = asset.absoluteLocalPath, FileManager.default.fileExists(atPath: path) else {
                throw YearArchiveError.missingMedia(asset.filename)
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard checksum == asset.sha256.lowercased() else { throw YearArchiveError.checksumMismatch(asset.filename) }
            blobs.append(.init(id: asset.id, sha256: checksum, size: Int64(data.count), dataBase64: data.base64EncodedString()))
        }

        let snapshot = YearArchiveSnapshot(year: year, entries: entries, dayNotes: dayNotes, mediaAssets: assets)
        let payload = YearArchivePayload(
            year: year,
            createdAt: Date(),
            theme: AppSettings.yearThemeValue(year).storageValue,
            document: BackupDocument(schemaVersion: 1, boards: boards, dayNotes: dayNotes, entries: entries, mediaAssets: assets),
            mediaBlobs: blobs
        )
        let payloadData = try JSONEncoder.wuyan.encode(payload)
        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let params = KDFParams(salt: salt)
        let key = try crypto.deriveKey(passphrase: password, salt: salt, params: params)
        let sealed = try crypto.seal(payloadData, key: key)
        let container = YearArchiveContainer(
            saltBase64: salt.base64EncodedString(),
            iterations: params.iterations,
            ciphertextBase64: sealed.base64EncodedString()
        )
        let data = try JSONEncoder.wuyan.encode(container)
        try data.write(to: url, options: .atomic)
        _ = try readArchive(from: url, password: password)
        return snapshot
    }

    func readArchive(from url: URL, password: String) throws -> YearArchiveSnapshot {
        try readArchiveContents(from: url, password: password).snapshot
    }

    func readArchiveContents(from url: URL, password: String) throws -> YearArchiveContents {
        let container: YearArchiveContainer
        do { container = try JSONDecoder.wuyan.decode(YearArchiveContainer.self, from: Data(contentsOf: url)) }
        catch { throw YearArchiveError.corrupt("无法读取外部头") }
        guard container.magic == "WUYANARCHIVE", container.version == 1,
              let salt = Data(base64Encoded: container.saltBase64),
              let ciphertext = Data(base64Encoded: container.ciphertextBase64) else {
            throw YearArchiveError.corrupt("格式版本或加密参数不受支持")
        }
        let key = try crypto.deriveKey(passphrase: password, salt: salt, params: KDFParams(salt: salt, iterations: container.iterations))
        let plain: Data
        do { plain = try crypto.open(ciphertext, key: key) } catch { throw YearArchiveError.invalidPassword }
        let payload: YearArchivePayload
        do { payload = try JSONDecoder.wuyan.decode(YearArchivePayload.self, from: plain) }
        catch { throw YearArchiveError.corrupt("加密清单无法解析") }
        guard payload.magic == "WUYAN-ARCHIVE", payload.schemaVersion == 1 else { throw YearArchiveError.corrupt("归档版本不受支持") }
        var mediaDataByID: [UUID: Data] = [:]
        for blob in payload.mediaBlobs {
            guard let data = Data(base64Encoded: blob.dataBase64), Int64(data.count) == blob.size else { throw YearArchiveError.corrupt("附件大小不一致") }
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard checksum == blob.sha256.lowercased() else { throw YearArchiveError.checksumMismatch(blob.id.uuidString) }
            guard mediaDataByID.updateValue(data, forKey: blob.id) == nil else { throw YearArchiveError.corrupt("附件 ID 重复") }
        }
        let snapshot = YearArchiveSnapshot(year: payload.year, entries: payload.document.entries, dayNotes: payload.document.dayNotes, mediaAssets: payload.document.mediaAssets)
        let referencedIDs = Set(snapshot.entries.flatMap(\.mediaIds))
        guard referencedIDs.isSubset(of: Set(mediaDataByID.keys)) else {
            throw YearArchiveError.corrupt("条目引用的附件未包含在归档中")
        }
        guard Set(snapshot.mediaAssets.map(\.id)) == Set(mediaDataByID.keys) else {
            throw YearArchiveError.corrupt("附件清单与附件内容不一致")
        }
        return YearArchiveContents(snapshot: snapshot, boards: payload.document.boards, mediaDataByID: mediaDataByID)
    }

    /// 将已验证的本地归档导入当前数据库。导入复用完整备份的快照、媒体落盘
    /// 和事务逻辑，默认跳过相同 ID 的当前记录，避免静默覆盖用户的新内容。
    func restoreArchive(
        from url: URL,
        password: String,
        database: AppDatabase,
        mediaStore: LocalMediaStore
    ) throws -> FullBackupRestoreReport {
        let contents = try readArchiveContents(from: url, password: password)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wuyan-restore-\(UUID().uuidString)", isDirectory: true)
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

        var mediaFiles: [FullBackupManifest.MediaFile] = []
        for asset in contents.snapshot.mediaAssets {
            guard let data = contents.mediaDataByID[asset.id] else {
                throw YearArchiveError.corrupt("附件记录与附件内容不一致")
            }
            let rawName = URL(fileURLWithPath: asset.filename).lastPathComponent
            let safeName = "\(asset.id.uuidString)-\(rawName.isEmpty ? "attachment" : rawName)"
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
            let fileURL = mediaDirectory.appendingPathComponent(safeName)
            try data.write(to: fileURL, options: .atomic)
            mediaFiles.append(.init(filename: safeName, sha256: asset.sha256.lowercased(), size: Int64(data.count)))
        }

        let manifest = FullBackupManifest(
            createdAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            database: BackupDocument(
                schemaVersion: 1,
                boards: contents.boards,
                dayNotes: contents.snapshot.dayNotes,
                entries: contents.snapshot.entries,
                mediaAssets: contents.snapshot.mediaAssets
            ),
            mediaFiles: mediaFiles
        )
        try JSONEncoder.wuyan.encode(manifest).write(to: root.appendingPathComponent("backup.json"), options: .atomic)
        return try ExportService().importFullBackupPackage(
            from: root,
            database: database,
            mediaStore: mediaStore,
            strategy: .skipExisting
        )
    }

    func cleanup(snapshot: YearArchiveSnapshot, database: AppDatabase, mediaStore: LocalMediaStore) throws -> YearArchiveCleanupResult {
        var removedEntries = 0
        var retainedEntries = 0
        var removedMedia = 0
        for archived in snapshot.entries {
            guard let current = try database.entryDAO.entry(id: archived.id), current.contentHash == archived.contentHash else {
                retainedEntries += 1
                continue
            }
            for asset in try database.mediaAssetDAO.allAssets(for: current.mediaIds) {
                if try database.mediaAssetDAO.referenceCount(sha256: asset.sha256) <= 1 {
                    try mediaStore.removeLocalFiles(for: asset)
                    removedMedia += 1
                }
            }
            try database.entryDAO.removeArchivedLocal(id: archived.id)
            removedEntries += 1
        }
        let noteHashes = Set(snapshot.dayNotes.map(Hashing.dayNoteHash))
        for note in try database.dayNoteDAO.all().filter({ $0.date.hasPrefix(String(format: "%04d-", snapshot.year)) }) where noteHashes.contains(Hashing.dayNoteHash(note) ) {
            try database.dayNoteDAO.delete(dayKey: note.date)
        }
        return YearArchiveCleanupResult(removedEntries: removedEntries, retainedEntries: retainedEntries, removedMedia: removedMedia)
    }
}
