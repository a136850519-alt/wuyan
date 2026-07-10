import Foundation

protocol RemoteStorageProvider: Sendable {
    func mkcolRecursive(_ path: String) async throws
    func list(_ path: String) async throws -> [RemoteItem]
    func get(_ path: String) async throws -> Data
    func getRange(_ path: String, bytes: Range<Int64>) async throws -> Data
    func put(_ path: String, data: Data, contentType: String) async throws
    func putChunked(_ path: String, fileURL: URL, chunkSize: Int) async throws
    func delete(_ path: String) async throws
    func exists(_ path: String) async throws -> Bool
    /// 远端对象的字节大小；对象不存在时返回 nil。用于断点续传时计算偏移。
    func contentLength(_ path: String) async throws -> Int64?
    /// 断点续传下载：分段 GET 写入 `fileURL`，中断后按已落盘字节续传。
    func getResumable(_ path: String, into fileURL: URL) async throws
    /// 断点续传上传：能力允许时按已传字节续传，否则安全地整体重传。
    func putResumable(_ path: String, fileURL: URL, chunkSize: Int) async throws
}

extension RemoteStorageProvider {
    /// 默认的断点续传下载：用 Range GET 分段写入 `fileURL`.part，按已落盘字节续传，完成后落位。
    /// 任何支持 HTTP Range 的后端（WebDAV / S3）都适用。
    func getResumable(_ path: String, into fileURL: URL) async throws {
        let fm = FileManager.default
        let partURL = URL(fileURLWithPath: fileURL.path + ".part")
        try fm.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let total = try await contentLength(path), total > 0 else {
            // 无法确定大小：退回整取（仍保证正确性，只是不能续传）。
            let data = try await get(path)
            try data.write(to: fileURL, options: .atomic)
            return
        }

        var offset: Int64 = (try? fm.attributesOfItem(atPath: partURL.path)[.size] as? Int64) ?? 0
        if offset > total {
            // 残留分片比远端还大，说明远端已变，丢弃重来。
            try? fm.removeItem(at: partURL)
            offset = 0
        }

        if offset < total {
            if !fm.fileExists(atPath: partURL.path) {
                fm.createFile(atPath: partURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let chunk: Int64 = 8 * 1024 * 1024
            while offset < total {
                let upper = min(offset + chunk, total)
                let data = try await getRange(path, bytes: offset..<upper)
                if data.isEmpty { break }
                try handle.write(contentsOf: data)
                offset += Int64(data.count)
            }
        }

        try? fm.removeItem(at: fileURL)
        try fm.moveItem(at: partURL, to: fileURL)
    }

    /// 默认的「断点续传上传」：退回到流式分片 PUT。后端可覆盖以实现真正的续传。
    func putResumable(_ path: String, fileURL: URL, chunkSize: Int) async throws {
        try await putChunked(path, fileURL: fileURL, chunkSize: chunkSize)
    }

    func testConnection(timeout: Duration = .seconds(10)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }

            group.addTask {
                let probe = "/Wuyan/.sync/connection-\(UUID().uuidString).txt"
                if !(try await exists("/Wuyan/.sync/")) {
                    try await mkcolRecursive("/Wuyan/.sync/")
                }
                try await put(probe, data: Data("ok".utf8), contentType: "text/plain")
                _ = try await get(probe)
                try await delete(probe)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RemoteStorageError.timeout
            }

            try await group.next()
        }
    }
}

struct RemoteItem: Codable, Equatable, Sendable {
    var path: String
    var isDirectory: Bool
    var size: Int64
    var etag: String?
    var modified: Date?
}

enum RemoteStorageError: LocalizedError {
    case invalidBaseURL
    case missingConfiguration(String)
    case unexpectedStatus(Int)
    case requestFailed(method: String, path: String, statusCode: Int)
    case missingCredentials
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "远端地址无效。"
        case let .missingConfiguration(name):
            return "缺少远端存储配置：\(name)。"
        case let .unexpectedStatus(code):
            return "远端返回了未预期的状态码：\(code)。"
        case let .requestFailed(method, path, statusCode):
            if statusCode == 423 {
                return "远端资源被锁定：\(method) \(path)。请稍后重试，或在 NAS 文件管理器中检查该路径是否被 WebDAV 锁定。"
            }
            return "远端返回了未预期的状态码：\(statusCode)（\(method) \(path)）。"
        case .missingCredentials:
            return "缺少远端存储凭据。"
        case .timeout:
            return "连接超时，请检查远端地址、网络和账号密码。"
        }
    }
}

struct RemoteStorageConfiguration: Codable, Equatable {
    enum Backend: String, Codable, CaseIterable {
        case webDAV
        case s3
    }

    var backend: Backend = .webDAV
    var webDAVBaseURL: String = "https://nas.local:5006"
    var webDAVUsername: String = ""
    var webDAVPassword: String = ""
    var s3Endpoint: String = ""
    var s3Region: String = "us-east-1"
    var s3Bucket: String = "wuyan"
    var s3AccessKey: String = ""
    var s3SecretKey: String = ""
    var s3PathStyle: Bool = true
    var rootPath: String = "/Wuyan/"
}
