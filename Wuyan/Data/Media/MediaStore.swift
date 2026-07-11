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

final class LocalMediaStore: MediaStoreProtocol {
    private let database: AppDatabase
    private let fileManager: FileManager
    private let mediaURL: URL  // Application Support/Wuyan/media

    /// 媒体根目录（Application Support/Wuyan/），供外部解析相对路径使用。
    static let mediaRootURL: URL = {
        let fm = FileManager.default
        // 使用 try! 因为 Application Support 目录一定存在
        let support = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("Wuyan", isDirectory: true)
    }()

    /// 将 DB 中的相对路径解析为绝对路径。兼容旧版绝对路径（直接返回）。
    /// R2-1: 外部调用应使用 MediaAsset.absoluteLocalPath / absoluteThumbnailPath，
    /// 此方法仅在 MediaStore 内部和 MediaAsset 模型层使用。
    static func resolvePath(_ relative: String) -> String {
        // 如果已经是绝对路径（旧数据兼容），直接返回
        if relative.hasPrefix("/") { return relative }
        return mediaRootURL.appendingPathComponent(relative).path
    }

    /// Optional 版本：传入 nil 返回 nil。
    static func resolvePath(_ relative: String?) -> String? {
        guard let relative else { return nil }
        return resolvePath(relative)
    }

    /// 将绝对路径转为相对路径（相对 mediaRootURL）。无法转换时返回原路径。
    /// R2-1: 外部不应直接调用，仅 MediaStore 内部使用
    static func toRelativePath(_ absolute: String) -> String {
        let prefix = mediaRootURL.path + "/"
        if absolute.hasPrefix(prefix) {
            return String(absolute.dropFirst(prefix.count))
        }
        return absolute
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

    /// R2-3: 供 AppMigrationRunner 调用的媒体迁移入口。
    /// 幂等：已迁移时直接返回。
    func performCachesMigration() throws {
        try migrateFromCachesIfNeeded()
    }

    private func migrateFromCachesIfNeeded() throws {
        guard !UserDefaults.standard.bool(forKey: Self.migrationKey) else { return }

        WuyanLog.media.info("开始媒体迁移：从 Caches 迁移到 Application Support")
        let cachesURL = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let oldMediaURL = cachesURL.appendingPathComponent("Wuyan/media", isDirectory: true)

        guard fileManager.fileExists(atPath: oldMediaURL.path) else {
            // 没有旧 Caches 媒体文件，标记已迁移即可
            UserDefaults.standard.set(true, forKey: Self.migrationKey)
            WuyanLog.media.info("无旧 Caches 媒体，跳过迁移")
            return
        }

        // 1. 将旧 Caches 下的文件逐个移到新目录
        migrateDirectoryContents(from: oldMediaURL, to: mediaURL)

        // 2. 迁移录音目录
        let oldRecordingsURL = cachesURL.appendingPathComponent("Wuyan/recordings", isDirectory: true)
        let newRecordingsURL = Self.mediaRootURL.appendingPathComponent("recordings", isDirectory: true)
        if fileManager.fileExists(atPath: oldRecordingsURL.path) {
            try? fileManager.createDirectory(at: newRecordingsURL, withIntermediateDirectories: true)
            migrateDirectoryContents(from: oldRecordingsURL, to: newRecordingsURL)
        }

        // 3. 将 DB 中绝对路径转为相对路径（同时把旧的 Caches 前缀替换掉）
        try migrateDatabasePaths()

        UserDefaults.standard.set(true, forKey: Self.migrationKey)
        WuyanLog.media.info("媒体迁移完成")
    }

    private func migrateDirectoryContents(from source: URL, to destination: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        for item in contents {
            let dest = destination.appendingPathComponent(item.lastPathComponent)
            if !fileManager.fileExists(atPath: dest.path) {
                try? fileManager.moveItem(at: item, to: dest)
            } else {
                // 目标已存在，合并子内容（适用于 bucket 目录）
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
                    migrateDirectoryContents(from: item, to: dest)
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
            return Self.toRelativePath(absolutePath)
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

    func storeRemoteMedia(_ data: Data, for asset: MediaAsset) throws -> URL {
        let ext = URL(fileURLWithPath: asset.filename).pathExtension
        let bucket = mediaURL.appendingPathComponent(String(asset.sha256.prefix(2)), isDirectory: true)
        try fileManager.createDirectory(at: bucket, withIntermediateDirectories: true)
        let local = bucket.appendingPathComponent(ext.isEmpty ? asset.sha256 : "\(asset.sha256).\(ext)")
        if !fileManager.fileExists(atPath: local.path) {
            try data.write(to: local, options: .atomic)
        }
        var updated = asset
        updated.localPath = Self.toRelativePath(local.path)
        try database.mediaAssetDAO.save(updated)
        return local
    }

    // 把断点续传下载好的完整文件落位到内容寻址缓存（移动而非读进内存，适合大视频）。
    func storeRemoteMediaFile(movingFrom tempURL: URL, for asset: MediaAsset) throws -> URL {
        let ext = URL(fileURLWithPath: asset.filename).pathExtension
        let bucket = mediaURL.appendingPathComponent(String(asset.sha256.prefix(2)), isDirectory: true)
        try fileManager.createDirectory(at: bucket, withIntermediateDirectories: true)
        let local = bucket.appendingPathComponent(ext.isEmpty ? asset.sha256 : "\(asset.sha256).\(ext)")
        if fileManager.fileExists(atPath: local.path) {
            try? fileManager.removeItem(at: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: local)
        }
        var updated = asset
        updated.localPath = Self.toRelativePath(local.path)
        try database.mediaAssetDAO.save(updated)
        return local
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
        let uploadedPaths = try database.mediaAssetDAO.uploadedPaths()

        var removed = 0
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
                guard let provider = try? ProviderFactory.makeRemoteStorageProvider() else {
                    WuyanLog.media.warning("跳过驱逐 \(asset.sha256.prefix(8))：无法连接远端存储")
                    continue
                }
                let plainExists = (try? await provider.contentLength(plainPath)) != nil
                let encExists = plainExists ? true : ((try? await provider.contentLength(encPath)) != nil)
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
