import CryptoKit
import Foundation

protocol RemoteStorageProvider: Sendable {
    func mkcolRecursive(_ path: String) async throws
    func list(_ path: String) async throws -> [RemoteItem]
    func get(_ path: String) async throws -> Data
    func getRange(_ path: String, bytes: Range<Int64>) async throws -> Data
    func put(_ path: String, data: Data, contentType: String) async throws
    /// 读取对象及其服务端版本标识（通常为 ETag）。
    func getVersioned(_ path: String) async throws -> RemoteObjectSnapshot
    /// 按服务端版本条件写入；新对象可用 ifNoneMatch 防止并发创建覆盖。
    func putConditionally(
        _ path: String,
        data: Data,
        contentType: String,
        ifMatch: String?,
        ifNoneMatch: Bool
    ) async throws
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
    func getVersioned(_ path: String) async throws -> RemoteObjectSnapshot {
        let data = try await get(path)
        return RemoteObjectSnapshot(data: data, etag: remoteContentFingerprint(data))
    }

    func putConditionally(
        _ path: String,
        data: Data,
        contentType: String,
        ifMatch: String?,
        ifNoneMatch: Bool
    ) async throws {
        if ifNoneMatch, try await exists(path) {
            throw RemoteStorageError.concurrentModification(path: path)
        }
        if let ifMatch {
            let latest = try await getVersioned(path)
            let currentToken = latest.etag ?? remoteContentFingerprint(latest.data)
            guard currentToken == ifMatch else {
                throw RemoteStorageError.concurrentModification(path: path)
            }
        }
        try await put(path, data: data, contentType: contentType)
    }

    private func remoteContentFingerprint(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return "sha256-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 默认的断点续传下载：用 Range GET 分段写入 `fileURL`.part，按已落盘字节续传，完成后落位。
    /// 任何支持 HTTP Range 的后端（WebDAV / S3）都适用。
    ///
    /// R01：服务器可能忽略 Range 返回整文件（HTTP 200 语义）。此时既有分片不可信
    /// （可能来自旧版本对象），必须丢弃后整体重写；空片段或长度不符一律报错，
    /// 绝不能把未完成分片落位；落位前强制校验最终长度。
    ///
    /// A05：残留分片用 sidecar 元数据绑定到「同一路径 + 同一长度」的远端对象。
    /// 没有元数据、或元数据与当前对象不一致的旧分片一律视为陈旧数据丢弃重下——
    /// 只比较长度会把恰好等长的损坏前缀当成有效续传起点。
    /// 调用方能提供预期 SHA-256 时（如内容寻址的媒体文件），走
    /// `getResumable(_:into:expectedSHA256:)` 在落位前强制校验内容指纹。
    func getResumable(_ path: String, into fileURL: URL) async throws {
        try await getResumable(path, into: fileURL, expectedSHA256: nil)
    }

    /// A05：带完整性校验的断点续传下载。落位前对照预期 SHA-256；
    /// 不一致时删除分片并抛错，绝不把损坏内容当成下载成功的附件。
    func getResumable(_ path: String, into fileURL: URL, expectedSHA256: String?) async throws {
        let fm = FileManager.default
        let partURL = URL(fileURLWithPath: fileURL.path + ".part")
        let metaURL = URL(fileURLWithPath: fileURL.path + ".part.meta")
        try fm.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let total = try await contentLength(path), total > 0 else {
            // 无法确定大小：退回整取（仍保证正确性，只是不能续传）。
            let data = try await get(path)
            if let expectedSHA256 {
                do {
                    try Self.verifyChecksum(of: data, expectedSHA256: expectedSHA256, path: path)
                } catch {
                    try? fm.removeItem(at: fileURL)
                    throw error
                }
            }
            try data.write(to: fileURL, options: .atomic)
            try? fm.removeItem(at: partURL)
            try? fm.removeItem(at: metaURL)
            return
        }

        // 分片绑定远端对象版本：元数据记录「正在下载哪个路径、多长的对象」。
        // 元数据缺失（异常中断于写入前）或与当前对象不符（对象已变化/残留自
        // 旧版本）时，既有分片不可信，丢弃后从 0 重新下载。
        let expectedMeta = "\(path)|\(total)"
        let metaMatches = (try? String(contentsOf: metaURL, encoding: .utf8)) == expectedMeta
        var offset: Int64 = metaMatches
            ? ((try? fm.attributesOfItem(atPath: partURL.path)[.size] as? Int64) ?? 0)
            : 0
        if !metaMatches || offset > total {
            try? fm.removeItem(at: partURL)
            offset = 0
        }
        try expectedMeta.write(to: metaURL, atomically: true, encoding: .utf8)

        if offset < total {
            if !fm.fileExists(atPath: partURL.path) {
                fm.createFile(atPath: partURL.path, contents: nil)
                offset = 0
            }
            let handle = try FileHandle(forWritingTo: partURL)
            defer { try? handle.close() }
            let chunk: Int64 = 8 * 1024 * 1024
            while offset < total {
                let upper = min(offset + chunk, total)
                let expected = Int(upper - offset)
                let data = try await getRange(path, bytes: offset..<upper)
                if data.count == expected {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    offset += Int64(data.count)
                } else if data.count == Int(total) {
                    // 服务器忽略 Range，把整个对象从 0 返回了：已有分片不可信，
                    // 丢弃后整体重写，不能把整文件追加到分片后面。
                    try handle.truncate(atOffset: 0)
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: data)
                    offset = total
                } else {
                    // 空片段或长度不符：下载不完整，报错并删除分片，绝不落位。
                    try? fm.removeItem(at: partURL)
                    try? fm.removeItem(at: metaURL)
                    throw RemoteStorageError.incompleteDownload(path: path, expected: Int64(expected), received: Int64(data.count))
                }
            }
        }

        // 落位前强制校验长度，防止任何路径下的短读悄悄进入「已下载」状态。
        let finalSize = (try? fm.attributesOfItem(atPath: partURL.path)[.size] as? Int64) ?? 0
        guard finalSize == total else {
            try? fm.removeItem(at: partURL)
            try? fm.removeItem(at: metaURL)
            throw RemoteStorageError.incompleteDownload(path: path, expected: total, received: finalSize)
        }
        // A05：能提供预期指纹时，落位前校验整文件 SHA-256。等长损坏、错误旧前缀
        // 等长度无法暴露的问题在这里被拦截。
        if let expectedSHA256 {
            do {
                try Self.verifyChecksum(of: partURL, expectedSHA256: expectedSHA256, path: path)
            } catch {
                try? fm.removeItem(at: partURL)
                try? fm.removeItem(at: metaURL)
                throw error
            }
        }
        try? fm.removeItem(at: fileURL)
        try fm.moveItem(at: partURL, to: fileURL)
        try? fm.removeItem(at: metaURL)
    }

    private static func verifyChecksum(of fileURL: URL, expectedSHA256: String, path: String) throws {
        let hex = try Hashing.sha256Hex(ofFileAt: fileURL)
        guard hex == expectedSHA256.lowercased() else {
            throw RemoteStorageError.checksumMismatch(path: path, expected: expectedSHA256, actual: hex)
        }
    }

    private static func verifyChecksum(of data: Data, expectedSHA256: String, path: String) throws {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex == expectedSHA256.lowercased() else {
            throw RemoteStorageError.checksumMismatch(path: path, expected: expectedSHA256, actual: hex)
        }
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

struct RemoteObjectSnapshot: Sendable {
    var data: Data
    var etag: String?
}

enum RemoteStorageError: LocalizedError {
    case invalidBaseURL
    case missingConfiguration(String)
    case unexpectedStatus(Int)
    case requestFailed(method: String, path: String, statusCode: Int)
    case missingCredentials
    case timeout
    case incompleteDownload(path: String, expected: Int64, received: Int64)
    case checksumMismatch(path: String, expected: String, actual: String)
    case archiveVerificationFailed(path: String)
    case multipartFailed(path: String, reason: String)
    case concurrentModification(path: String)

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
        case let .incompleteDownload(path, expected, received):
            return "下载不完整（应为 \(expected) 字节，实收 \(received) 字节）：\(path)。已放弃本次落位，请重试。"
        case let .checksumMismatch(path, expected, actual):
            return "下载内容校验失败（SHA-256 不匹配：预期 \(expected.prefix(16))…，实际 \(actual.prefix(16))…）：\(path)。已放弃本次落位，请重试。"
        case let .archiveVerificationFailed(path):
            return "归档校验失败：\(path) 读回内容与本地不一致。已停止归档，本地数据未被删除，请重试或检查远端。"
        case let .multipartFailed(path, reason):
            return "分片上传完成响应失败（\(path)）：\(reason)。远端对象未视为上传成功。"
        case let .concurrentModification(path):
            return "远端对象在提交期间被其它设备更新：\(path)。已重新合并或请稍后重试。"
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
    var s3Endpoint: String = ""
    var s3Region: String = "us-east-1"
    var s3Bucket: String = "wuyan"
    var s3AccessKey: String = ""
    var s3PathStyle: Bool = true
    var rootPath: String = "/Wuyan/"
}
