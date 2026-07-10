import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol MediaStoreProtocol {
    func importMedia(_ url: URL, entryId: UUID) async throws -> MediaAsset
    func localURL(for asset: MediaAsset) async -> URL?
    func thumbnail(for asset: MediaAsset) async -> NSImage?
    func evictCacheIfNeeded()
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
        try migrateFromCachesIfNeeded()
    }

    // MARK: - Migration from Caches

    private static let migrationKey = "wuyan.media.migratedFromCaches"

    private func migrateFromCachesIfNeeded() throws {
        guard !UserDefaults.standard.bool(forKey: Self.migrationKey) else { return }

        let cachesURL = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let oldMediaURL = cachesURL.appendingPathComponent("Wuyan/media", isDirectory: true)

        guard fileManager.fileExists(atPath: oldMediaURL.path) else {
            // 没有旧 Caches 媒体文件，标记已迁移即可
            UserDefaults.standard.set(true, forKey: Self.migrationKey)
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

    func evictCacheIfNeeded() {
        guard let enumerator = fileManager.enumerator(at: mediaURL, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        guard total > 2 * 1024 * 1024 * 1024 else { return }
        // P3-7 会实现真正的清理逻辑
    }

    private func makeThumbnailIfPossible(for url: URL, sha: String) throws -> String? {
        guard mediaType(for: url) == .photo,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
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
