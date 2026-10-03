import AppKit
import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

protocol MediaStoreProtocol {
    func importMedia(_ url: URL, entryId: UUID) async throws -> MediaAsset
    func localURL(for asset: MediaAsset) async -> URL?
    func thumbnail(for asset: MediaAsset) async -> NSImage?
    // R2-9: evictCacheIfNeeded 死代码已删除，真正占用管理由按年清理承担
    func removeLocalFiles(for asset: MediaAsset) throws
}

enum MediaMigrationError: LocalizedError {
    case moveFailed(source: String, destination: String, underlying: Error)
    case destinationConflict(String)

    var errorDescription: String? {
        switch self {
        case let .moveFailed(source, destination, underlying):
            return "媒体迁移失败：\(source) -> \(destination)：\(underlying.localizedDescription)"
        case let .destinationConflict(path):
            return "媒体迁移发现同名文件内容不一致：\(path)"
        }
    }
}

final class LocalMediaStore: MediaStoreProtocol {
    private let database: AppDatabase
    private let fileManager: FileManager
    private let mediaURL: URL  // Application Support/Wuyan/media

    /// 媒体根目录（Application Support/Wuyan/），供外部解析相对路径使用。
    /// C03：测试可注入隔离根目录（injectMediaRootForTesting），注入后环境变量
    /// 与真实 Application Support 都不再参与解析；未注入时保持原行为。
    private static var mediaRootOverride: URL?

    /// 仅测试目标可调用：注入隔离的媒体根目录。传 nil 恢复默认解析。
    static func injectMediaRootForTesting(_ url: URL?) {
        mediaRootOverride = url
    }

    static var mediaRootURL: URL {
        if let mediaRootOverride {
            return mediaRootOverride
        }
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["WUYAN_MEDIA_ROOT"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        // 正常运行使用 Application Support；测试可通过环境变量注入隔离根目录。
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return support.appendingPathComponent("Wuyan", isDirectory: true)
    }

    /// 将 DB 中的相对路径解析为绝对路径。旧版绝对路径只有在已经位于
    /// Application Support/Wuyan 根目录内时才接受；其它路径返回空字符串，
    /// 防止异常备份或损坏数据库借媒体字段访问应用目录之外的文件。
    /// R2-1: 外部调用应使用 MediaAsset.absoluteLocalPath / absoluteThumbnailPath，
    /// 此方法仅在 MediaStore 内部和 MediaAsset 模型层使用。
    static func resolvePath(_ relative: String) -> String {
        guard !relative.isEmpty else { return "" }
        let root = mediaRootURL.standardizedFileURL
        let candidate: URL
        if relative.hasPrefix("/") {
            candidate = URL(fileURLWithPath: relative).standardizedFileURL
        } else {
            candidate = root.appendingPathComponent(relative).standardizedFileURL
        }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPath) else {
            WuyanLog.security.warning("拒绝越界媒体路径：\(relative, privacy: .private)")
            return ""
        }
        return candidate.path
    }

    /// Optional 版本：传入 nil 返回 nil。
    static func resolvePath(_ relative: String?) -> String? {
        guard let relative else { return nil }
        return resolvePath(relative)
    }

    /// 将绝对路径转为相对路径（相对 mediaRootURL）。无法转换时返回原路径。
    /// R2-1: 外部不应直接调用，仅 MediaStore 内部使用
    static func toRelativePath(_ absolute: String) -> String {
        guard !absolute.isEmpty else { return "" }
        let root = mediaRootURL.standardizedFileURL
        let candidate: URL
        if absolute.hasPrefix("/") {
            candidate = URL(fileURLWithPath: absolute).standardizedFileURL
        } else {
            candidate = root.appendingPathComponent(absolute).standardizedFileURL
        }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(prefix) else {
            return ""
        }
        return String(candidate.path.dropFirst(prefix.count))
    }

    init(database: AppDatabase, fileManager: FileManager = .default) throws {
        self.database = database
        self.fileManager = fileManager
        let supportURL = Self.mediaRootURL
        self.mediaURL = supportURL.appendingPathComponent("media", isDirectory: true)
        try fileManager.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        // R2-3/R2-4: 迁移移入 AppMigrationRunner，init 不再执行迁移
        // migrateFromCachesIfNeeded() 改为公开方法供 MigrationRunner 调用
    }

    // MARK: - Migration from Caches (R2-3: 由 AppMigrationRunner 调用)

    private static let migrationKey = "wuyan.media.migratedFromCaches"
    /// Q01：迁移标记可注入。生产固定 standard；测试注入隔离 suite，
    /// 构造 AppState 的测试不会读写/推进用户的真实迁移标记。
    private static var defaults: UserDefaults = .standard

    /// 仅测试目标可调用：注入隔离的 UserDefaults。
    static func injectDefaultsForTesting(_ injected: UserDefaults) {
        defaults = injected
    }

    /// C03：Caches 迁移的源目录。生产未注入时懒解析真实用户 Caches；
    /// 测试注入临时目录后，AppState 构造触发的迁移只会搬动合成夹具，
    /// 绝不读取或移动真实用户缓存（WUYAN_MEDIA_ROOT 只隔离目标端，隔离不了源端）。
    private static var cachesSourceOverride: URL?

    /// 仅测试目标可调用：注入隔离的 Caches 源目录。传 nil 恢复真实目录。
    static func injectCachesSourceForTesting(_ url: URL?) {
        cachesSourceOverride = url
    }

    /// 解析当前生效的 Caches 源目录。internal 供测试断言注入已生效。
    static func currentCachesRoot(fileManager: FileManager) -> URL {
        if let cachesSourceOverride {
            return cachesSourceOverride
        }
        return (try? fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? fileManager.temporaryDirectory
    }

    /// R2-3: 供 AppMigrationRunner 调用的媒体迁移入口。
    /// 幂等：已迁移时直接返回。
    func performCachesMigration() throws {
        try migrateFromCachesIfNeeded()
    }

    private func migrateFromCachesIfNeeded() throws {
        guard !Self.defaults.bool(forKey: Self.migrationKey) else { return }

        WuyanLog.media.info("开始媒体迁移：从 Caches 迁移到 Application Support")
        // C03：源目录经注入点解析；测试容器里永远不会触碰真实用户 Caches。
        let cachesURL = Self.currentCachesRoot(fileManager: fileManager)
        let oldMediaURL = cachesURL.appendingPathComponent("Wuyan/media", isDirectory: true)
        let oldRecordingsURL = cachesURL.appendingPathComponent("Wuyan/recordings", isDirectory: true)
        let newRecordingsURL = Self.mediaRootURL.appendingPathComponent("recordings", isDirectory: true)

        // 1. 媒体和录音分别迁移。任一目录失败都不写完成标记，下一次启动会
        // 从剩余源文件继续，避免「移动失败但已标记成功」导致永久丢附件。
        if fileManager.fileExists(atPath: oldMediaURL.path) {
            try migrateDirectoryContents(from: oldMediaURL, to: mediaURL)
        }
        if fileManager.fileExists(atPath: oldRecordingsURL.path) {
            try fileManager.createDirectory(at: newRecordingsURL, withIntermediateDirectories: true)
            try migrateDirectoryContents(from: oldRecordingsURL, to: newRecordingsURL)
        }

        // 2. 将 DB 中绝对路径转为相对路径（同时把旧的 Caches 前缀替换掉）
        try migrateDatabasePaths()

        Self.defaults.set(true, forKey: Self.migrationKey)
        WuyanLog.media.info("媒体迁移完成")
    }

    private func migrateDirectoryContents(from source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in contents {
            let dest = destination.appendingPathComponent(item.lastPathComponent)
            if !fileManager.fileExists(atPath: dest.path) {
                do {
                    try fileManager.moveItem(at: item, to: dest)
                } catch {
                    throw MediaMigrationError.moveFailed(source: item.path, destination: dest.path, underlying: error)
                }
            } else {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
                    try migrateDirectoryContents(from: item, to: dest)
                } else {
                    // 同名文件已在目标目录时，只有内容完全一致才可视为已迁移。
                    // 不一致必须中止，避免静默覆盖用户文件。
                    let sourceHash = try Hashing.sha256Hex(ofFileAt: item)
                    let destinationHash = try Hashing.sha256Hex(ofFileAt: dest)
                    guard sourceHash == destinationHash else {
                        throw MediaMigrationError.destinationConflict(dest.path)
                    }
                    try fileManager.removeItem(at: item)
                }
            }
        }
    }

    private func migrateDatabasePaths() throws {
        // 将所有 media_asset 中的 localPath 和 thumbnailPath 从绝对路径转为相对路径
        // 旧的 Caches 绝对路径包含 "Caches/Wuyan/media/" 前缀，新的相对路径以 "media/" 开头
        try database.mediaAssetDAO.migratePathsToRelative { absolutePath in
            // 兼容旧 Caches 路径：.../Caches/Wuyan/media/ab/xxx.jpg → media/ab/xxx.jpg
            if let range = absolutePath.range(of: "Caches/Wuyan/media/") {
                return "media/" + String(absolutePath[range.upperBound...])
            }
            if let range = absolutePath.range(of: "Caches/Wuyan/recordings/") {
                return "recordings/" + String(absolutePath[range.upperBound...])
            }
            // 已经在新 App Support 路径下：.../Application Support/Wuyan/media/ab/xxx.jpg → media/ab/xxx.jpg
            let relative = Self.toRelativePath(absolutePath)
            return relative.isEmpty ? nil : relative
        }
    }

    // MARK: - MediaStoreProtocol

    func importMedia(_ url: URL, entryId: UUID) async throws -> MediaAsset {
        WuyanLog.media.info("导入媒体：\(url.lastPathComponent) → 条目 \(entryId.uuidString.prefix(8))")
        let data = try Data(contentsOf: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension
        let bucket = mediaURL.appendingPathComponent(String(sha.prefix(2)), isDirectory: true)
        try fileManager.createDirectory(at: bucket, withIntermediateDirectories: true)
        let local = bucket.appendingPathComponent(ext.isEmpty ? sha : "\(sha).\(ext)")
        if !fileManager.fileExists(atPath: local.path) {
            try data.write(to: local, options: .atomic)
        }

        let thumbnailRelPath = try makeThumbnailIfPossible(for: local, sha: sha)
        let localRelPath = Self.toRelativePath(local.path)
        let asset = MediaAsset(
            entryId: entryId,
            type: mediaType(for: url),
            filename: url.lastPathComponent,
            mime: mimeType(for: url),
            size: Int64(data.count),
            sha256: sha,
            thumbnailPath: thumbnailRelPath,
            localPath: localRelPath,
            capturedAt: Date()
        )
        try database.mediaAssetDAO.save(asset)
        if var entry = try database.entryDAO.entry(id: entryId), !entry.mediaIds.contains(asset.id) {
            entry.mediaIds.append(asset.id)
            try database.entryDAO.save(entry)
        }
        WuyanLog.media.info("导入媒体完成：\(sha.prefix(8))，\(data.count) 字节")
        return asset
    }

    func localURL(for asset: MediaAsset) async -> URL? {
        let ext = URL(fileURLWithPath: asset.filename).pathExtension
        let url = mediaURL
            .appendingPathComponent(String(asset.sha256.prefix(2)), isDirectory: true)
            .appendingPathComponent(ext.isEmpty ? asset.sha256 : "\(asset.sha256).\(ext)")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func thumbnail(for asset: MediaAsset) async -> NSImage? {
        guard let thumbnailPath = asset.thumbnailPath else { return nil }
        let absolutePath = Self.resolvePath(thumbnailPath)
        return NSImage(contentsOfFile: absolutePath)
    }

    /// A05：写入内存中的远端媒体前先校验内容指纹；本机已有缓存但内容不符时
    /// 以校验通过的新内容覆盖（损坏缓存不可继续使用）。
    func storeRemoteMedia(_ data: Data, for asset: MediaAsset) throws -> URL {
        try Self.verify(data, matches: asset.sha256, source: asset.filename)
        let local = try materializeRemoteMedia(data, for: asset)
        var updated = asset
        updated.localPath = Self.toRelativePath(local.path)
        try database.mediaAssetDAO.save(updated)
        return local
    }

    /// 将远端媒体写入内容寻址目录，但不修改数据库。
    /// 备份还原可先完成所有文件落地，再一次性提交数据库记录。
    /// A05：写入前后都校验 SHA-256——负载不符直接报错；已有缓存内容不符时覆盖。
    func materializeRemoteMedia(_ data: Data, for asset: MediaAsset) throws -> URL {
        try Self.verify(data, matches: asset.sha256, source: asset.filename)
        let local = localMediaURL(for: asset)
        let bucket = local.deletingLastPathComponent()
        try fileManager.createDirectory(at: bucket, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: local.path) {
            // 内容寻址：已有文件校验一致才复用；不一致说明缓存损坏，必须覆盖。
            if try Hashing.sha256Hex(ofFileAt: local) != asset.sha256 {
                try data.write(to: local, options: .atomic)
            }
        } else {
            try data.write(to: local, options: .atomic)
        }
        return local
    }

    /// 内容寻址媒体在本地媒体库中的目标位置。
    func localMediaURL(for asset: MediaAsset) -> URL {
        let ext = URL(fileURLWithPath: asset.filename).pathExtension
        return mediaURL
            .appendingPathComponent(String(asset.sha256.prefix(2)), isDirectory: true)
            .appendingPathComponent(ext.isEmpty ? asset.sha256 : "\(asset.sha256).\(ext)")
    }

    // 把断点续传下载好的完整文件落位到内容寻址缓存（移动而非读进内存，适合大视频）。
    // A05：落位前对照资产元数据校验 SHA-256，等长损坏/错误旧前缀的内容绝不入缓存；
    // 已有缓存校验一致时复用，不一致时以校验通过的新文件覆盖。
    func storeRemoteMediaFile(movingFrom tempURL: URL, for asset: MediaAsset) throws -> URL {
        let ext = URL(fileURLWithPath: asset.filename).pathExtension
        let bucket = mediaURL.appendingPathComponent(String(asset.sha256.prefix(2)), isDirectory: true)
        try fileManager.createDirectory(at: bucket, withIntermediateDirectories: true)
        let local = bucket.appendingPathComponent(ext.isEmpty ? asset.sha256 : "\(asset.sha256).\(ext)")
        let tempHash = try Hashing.sha256Hex(ofFileAt: tempURL)
        guard tempHash == asset.sha256 else {
            try? fileManager.removeItem(at: tempURL)
            throw RemoteStorageError.checksumMismatch(path: tempURL.path, expected: asset.sha256, actual: tempHash)
        }
        defer { try? fileManager.removeItem(at: tempURL) }
        if fileManager.fileExists(atPath: local.path) {
            if try Hashing.sha256Hex(ofFileAt: local) == asset.sha256 {
                // 缓存完好：丢弃临时文件即可。
            } else {
                // 缓存损坏：用校验通过的新文件覆盖。
                try fileManager.removeItem(at: local)
                try fileManager.moveItem(at: tempURL, to: local)
            }
        } else {
            try fileManager.moveItem(at: tempURL, to: local)
        }
        var updated = asset
        updated.localPath = Self.toRelativePath(local.path)
        try database.mediaAssetDAO.save(updated)
        return local
    }

    // MARK: - A05：完整性校验

    private static func hexDigest(of data: Data) throws -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func verify(_ data: Data, matches sha256: String, source: String) throws {
        let hex = try hexDigest(of: data)
        guard hex == sha256 else {
            throw RemoteStorageError.checksumMismatch(path: source, expected: sha256, actual: hex)
        }
    }

    func storeRemoteThumbnail(_ data: Data, for asset: MediaAsset) throws {
        let thumbnailDirectory = mediaURL.appendingPathComponent("thumbnails", isDirectory: true)
        try fileManager.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let outputURL = thumbnailDirectory.appendingPathComponent("\(asset.sha256).jpg")
        try data.write(to: outputURL, options: .atomic)
        var updated = try database.mediaAssetDAO.asset(id: asset.id) ?? asset
        updated.thumbnailPath = Self.toRelativePath(outputURL.path)
        try database.mediaAssetDAO.save(updated)
    }

    func removeLocalFiles(for asset: MediaAsset) throws {
        if let localPath = asset.localPath {
            let absolutePath = Self.resolvePath(localPath)
            if fileManager.fileExists(atPath: absolutePath) {
                try fileManager.removeItem(atPath: absolutePath)
            }
        }
        if let thumbnailPath = asset.thumbnailPath {
            let absolutePath = Self.resolvePath(thumbnailPath)
            if fileManager.fileExists(atPath: absolutePath) {
                try fileManager.removeItem(atPath: absolutePath)
            }
        }
        try database.mediaAssetDAO.clearLocalFiles(id: asset.id)
    }

    // R2-9: evictCacheIfNeeded() 空壳已删除（零调用，真正占用管理由按年清理承担）

    // MARK: - 磁盘用量

    /// 计算媒体目录总大小（字节）
    func totalMediaSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(at: mediaURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    /// 按年份统计本地媒体大小。key = 年份，value = 字节数
    func mediaSizeByYear() -> [Int: Int64] {
        var sizes: [Int: Int64] = [:]
        let allAssets = (try? database.mediaAssetDAO.allAssets()) ?? []
        let calendar = Calendar.current
        for asset in allAssets {
            guard let localPath = asset.localPath else { continue }
            let absolutePath = Self.resolvePath(localPath)
            guard fileManager.fileExists(atPath: absolutePath) else { continue }
            let fileSize = (try? fileManager.attributesOfItem(atPath: absolutePath)[.size] as? Int) ?? 0
            let year: Int
            if let date = asset.capturedAt {
                year = calendar.component(.year, from: date)
            } else {
                year = 0
            }
            sizes[year, default: 0] += Int64(fileSize)
        }
        return sizes
    }

    /// 清理指定年份的本地媒体文件（仅删除已同步到远端的）。
    /// R0-4: 修复安全检查——不再仅凭 sha256 非空就删除，而是：
    ///   1. 用条目的 dayDate（而非 capturedAt）判断年份归属
    ///   2. 只删除已在 sync_uploaded 表中记录的资产，确保远端有备份
    ///   3. 对未在 sync_uploaded 中的资产查询远端是否存在
    func evictYearMedia(year: Int) async throws -> Int {
        let yearEntries = try database.entryDAO.timeline(filter: .year(year))
        let allMediaIds = yearEntries.flatMap(\.mediaIds)
        let allAssets = try database.mediaAssetDAO.allAssets(for: allMediaIds)
        // D08：上传缓存按后端身份隔离——拿当前后端的缓存判断，绝不能拿其它后端
        // 的「已上传」记录批准本次删除。
        let uploadedPaths = try database.mediaAssetDAO.uploadedPaths(backend: ProviderFactory.backendFingerprint())

        var removed = 0
        var fallbackProvider: (any RemoteStorageProvider)?
        var attemptedProviderCreation = false
        for asset in allAssets {
            guard !asset.sha256.isEmpty else { continue }
            guard let localPath = asset.localPath else { continue }
            let absolutePath = Self.resolvePath(localPath)
            guard fileManager.fileExists(atPath: absolutePath) else { continue }

            // 安全检查：确认远端已备份
            let plainPath = SyncPaths.mediaPath(sha256: asset.sha256, filename: asset.filename)
            let encPath = SyncPaths.encryptedMediaPath(sha256: asset.sha256, filename: asset.filename)
            let isUploaded = uploadedPaths.contains(plainPath) || uploadedPaths.contains(encPath)

            if !isUploaded {
                // 未在 sync_uploaded 表中，查询远端是否确实存在
                if !attemptedProviderCreation {
                    attemptedProviderCreation = true
                    fallbackProvider = try? ProviderFactory.makeRemoteStorageProvider()
                }
                guard let fallbackProvider else {
                    WuyanLog.media.warning("跳过驱逐 \(asset.sha256.prefix(8))：无法连接远端存储")
                    continue
                }
                let plainExists = (try? await fallbackProvider.contentLength(plainPath)) != nil
                let encExists = plainExists ? true : ((try? await fallbackProvider.contentLength(encPath)) != nil)
                guard plainExists || encExists else {
                    WuyanLog.media.warning("跳过驱逐 \(asset.sha256.prefix(8))：远端不存在，删除将导致数据丢失")
                    continue
                }
            }

            try removeLocalFiles(for: asset)
            removed += 1
        }
        WuyanLog.media.info("已清理 \(year) 年本地媒体：\(removed) 个文件")
        return removed
    }

    private func makeThumbnailIfPossible(for url: URL, sha: String) throws -> String? {
        let type = mediaType(for: url)

        if type == .photo {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480
                  ] as CFDictionary)
            else { return nil }

            let thumbURL = mediaURL.appendingPathComponent("thumbnails", isDirectory: true)
            try fileManager.createDirectory(at: thumbURL, withIntermediateDirectories: true)
            let outputURL = thumbURL.appendingPathComponent("\(sha).jpg")
            guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            return Self.toRelativePath(outputURL.path)
        }

        if type == .video {
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            do {
                let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
                let thumbURL = mediaURL.appendingPathComponent("thumbnails", isDirectory: true)
                try fileManager.createDirectory(at: thumbURL, withIntermediateDirectories: true)
                let outputURL = thumbURL.appendingPathComponent("\(sha).jpg")
                guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                    return nil
                }
                CGImageDestinationAddImage(destination, cgImage, nil)
                CGImageDestinationFinalize(destination)
                return Self.toRelativePath(outputURL.path)
            } catch {
                WuyanLog.media.warning("视频缩略图生成失败：\(error.localizedDescription)")
                return nil
            }
        }

        return nil
    }

    private func mediaType(for url: URL) -> MediaType {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "tiff":
            return .photo
        case "mov", "mp4", "m4v":
            return .video
        default:
            return .audio
        }
    }

    private func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
