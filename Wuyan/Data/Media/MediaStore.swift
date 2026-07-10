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
    private let cacheURL: URL

    init(database: AppDatabase, fileManager: FileManager = .default) throws {
        self.database = database
        self.fileManager = fileManager
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        self.cacheURL = caches.appendingPathComponent("Wuyan/media", isDirectory: true)
        try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    }

    func importMedia(_ url: URL, entryId: UUID) async throws -> MediaAsset {
        let data = try Data(contentsOf: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension
        let bucket = cacheURL.appendingPathComponent(String(sha.prefix(2)), isDirectory: true)
        try fileManager.createDirectory(at: bucket, withIntermediateDirectories: true)
        let local = bucket.appendingPathComponent(ext.isEmpty ? sha : "\(sha).\(ext)")
        if !fileManager.fileExists(atPath: local.path) {
            try data.write(to: local, options: .atomic)
        }

        let thumbnailPath = try makeThumbnailIfPossible(for: local, sha: sha)
        let asset = MediaAsset(
            entryId: entryId,
            type: mediaType(for: url),
            filename: url.lastPathComponent,
            mime: mimeType(for: url),
            size: Int64(data.count),
            sha256: sha,
            thumbnailPath: thumbnailPath,
            localPath: local.path,
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
        let url = cacheURL
            .appendingPathComponent(String(asset.sha256.prefix(2)), isDirectory: true)
            .appendingPathComponent(ext.isEmpty ? asset.sha256 : "\(asset.sha256).\(ext)")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func thumbnail(for asset: MediaAsset) async -> NSImage? {
        guard let thumbnailPath = asset.thumbnailPath else { return nil }
        return NSImage(contentsOfFile: thumbnailPath)
    }

    func storeRemoteMedia(_ data: Data, for asset: MediaAsset) throws -> URL {
        let ext = URL(fileURLWithPath: asset.filename).pathExtension
        let bucket = cacheURL.appendingPathComponent(String(asset.sha256.prefix(2)), isDirectory: true)
        try fileManager.createDirectory(at: bucket, withIntermediateDirectories: true)
        let local = bucket.appendingPathComponent(ext.isEmpty ? asset.sha256 : "\(asset.sha256).\(ext)")
        if !fileManager.fileExists(atPath: local.path) {
            try data.write(to: local, options: .atomic)
        }
        var updated = asset
        updated.localPath = local.path
        try database.mediaAssetDAO.save(updated)
        return local
    }

    // 把断点续传下载好的完整文件落位到内容寻址缓存（移动而非读进内存，适合大视频）。
    func storeRemoteMediaFile(movingFrom tempURL: URL, for asset: MediaAsset) throws -> URL {
        let ext = URL(fileURLWithPath: asset.filename).pathExtension
        let bucket = cacheURL.appendingPathComponent(String(asset.sha256.prefix(2)), isDirectory: true)
        try fileManager.createDirectory(at: bucket, withIntermediateDirectories: true)
        let local = bucket.appendingPathComponent(ext.isEmpty ? asset.sha256 : "\(asset.sha256).\(ext)")
        if fileManager.fileExists(atPath: local.path) {
            try? fileManager.removeItem(at: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: local)
        }
        var updated = asset
        updated.localPath = local.path
        try database.mediaAssetDAO.save(updated)
        return local
    }

    func storeRemoteThumbnail(_ data: Data, for asset: MediaAsset) throws {
        let thumbnailDirectory = cacheURL.appendingPathComponent("thumbnails", isDirectory: true)
        try fileManager.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let outputURL = thumbnailDirectory.appendingPathComponent("\(asset.sha256).jpg")
        try data.write(to: outputURL, options: .atomic)
        var updated = try database.mediaAssetDAO.asset(id: asset.id) ?? asset
        updated.thumbnailPath = outputURL.path
        try database.mediaAssetDAO.save(updated)
    }

    func removeLocalFiles(for asset: MediaAsset) throws {
        if let localPath = asset.localPath, fileManager.fileExists(atPath: localPath) {
            try fileManager.removeItem(atPath: localPath)
        }
        if let thumbnailPath = asset.thumbnailPath, fileManager.fileExists(atPath: thumbnailPath) {
            try fileManager.removeItem(atPath: thumbnailPath)
        }
        try database.mediaAssetDAO.clearLocalFiles(id: asset.id)
    }

    func evictCacheIfNeeded() {
        guard let enumerator = fileManager.enumerator(at: cacheURL, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        guard total > 2 * 1024 * 1024 * 1024 else { return }
    }

    private func makeThumbnailIfPossible(for url: URL, sha: String) throws -> String? {
        guard mediaType(for: url) == .photo,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 480
              ] as CFDictionary)
        else { return nil }

        let thumbURL = cacheURL.appendingPathComponent("thumbnails", isDirectory: true)
        try fileManager.createDirectory(at: thumbURL, withIntermediateDirectories: true)
        let outputURL = thumbURL.appendingPathComponent("\(sha).jpg")
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return outputURL.path
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
