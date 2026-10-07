import CryptoKit
import Foundation
import os

struct WebDAVProvider: RemoteStorageProvider {
    private let baseURL: URL
    private let credential: URLCredential?
    private let session: URLSession

    init(baseURL: URL, username: String? = nil, password: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        if let username, let password, !username.isEmpty {
            credential = URLCredential(user: username, password: password, persistence: .forSession)
        } else {
            credential = nil
        }
    }

    func mkcolRecursive(_ path: String) async throws {
        var current = ""
        for component in normalized(path).split(separator: "/") {
            current += "/\(component)"
            var request = try request(path: current + "/", method: "MKCOL")
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            _ = try await send(request, method: "MKCOL", path: current + "/", allowed: [201, 405])
        }
    }

    func list(_ path: String) async throws -> [RemoteItem] {
        var request = try request(path: path, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.httpBody = """
        <?xml version="1.0" encoding="utf-8" ?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:resourcetype/>
            <D:getcontentlength/>
            <D:getetag/>
            <D:getlastmodified/>
          </D:prop>
        </D:propfind>
        """.data(using: .utf8)
        let (data, response) = try await send(
            request,
            method: "PROPFIND",
            path: path,
            allowed: [200, 207, 404]
        )
        guard let http = response as? HTTPURLResponse else { return [] }
        if http.statusCode == 404 { return [] }
        return WebDAVMultistatusParser.parse(data: data).compactMap { item in
            guard let path = logicalPath(for: item.path, isDirectory: item.isDirectory) else {
                WuyanLog.sync.warning("WebDAV PROPFIND 忽略 base URL 之外的 href：\(item.path)")
                return nil
            }
            var normalizedItem = item
            normalizedItem.path = path
            return normalizedItem
        }
    }

    func get(_ path: String) async throws -> Data {
        let request = try request(path: path, method: "GET")
        let (data, _) = try await send(request, method: "GET", path: path, allowed: [200])
        return data
    }

    func getVersioned(_ path: String) async throws -> RemoteObjectSnapshot {
        let request = try request(path: path, method: "GET")
        let (data, response) = try await send(request, method: "GET", path: path, allowed: [200])
        let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
            ?? "sha256-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return RemoteObjectSnapshot(data: data, etag: etag)
    }

    func getRange(_ path: String, bytes: Range<Int64>) async throws -> Data {
        var request = try request(path: path, method: "GET")
        request.setValue("bytes=\(bytes.lowerBound)-\(bytes.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, _) = try await send(request, method: "GET", path: path, allowed: [200, 206])
        return data
    }

    func put(_ path: String, data: Data, contentType: String) async throws {
        var request = try request(path: path, method: "PUT")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        _ = try await send(request, method: "PUT", path: path, allowed: [200, 201, 204])
    }

    func putConditionally(
        _ path: String,
        data: Data,
        contentType: String,
        ifMatch: String?,
        ifNoneMatch: Bool
    ) async throws {
        var request = try request(path: path, method: "PUT")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        if ifNoneMatch { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        request.httpBody = data
        let (_, response) = try await send(
            request,
            method: "PUT",
            path: path,
            allowed: [200, 201, 204, 409, 412]
        )
        if let status = (response as? HTTPURLResponse)?.statusCode, status == 409 || status == 412 {
            throw RemoteStorageError.concurrentModification(path: path)
        }
    }

    // 从文件流式 PUT：URLSession 直接从磁盘读取上传，不把整段（大视频）读进内存。
    // 注：标准 WebDAV 的单次 PUT 不支持断点续传；chunkSize 仅用于决定小文件是否走内存路径。
    func putChunked(_ path: String, fileURL: URL, chunkSize: Int = 8 * 1024 * 1024) async throws {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil ?? 0

        // 小文件直接走内存 PUT；大文件用 upload(fromFile:) 流式传输。
        if fileSize > 0, fileSize <= chunkSize {
            let data = try Data(contentsOf: fileURL)
            try await put(path, data: data, contentType: contentType(for: fileURL))
            return
        }

        try await streamUpload(path, fileURL: fileURL)
    }

    // 断点续传上传：先把文件传到远端 `<path>.part`，可续传则只补未传字节，完成后 MOVE 到最终路径。
    // 这样即便中途中断，最终的内容寻址对象（exists() 据此跳过重传）也只会在文件完整时才出现，
    // 不会留下半截文件被误判为「已存在」。
    func putResumable(_ path: String, fileURL: URL, chunkSize: Int = 8 * 1024 * 1024) async throws {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0

        // 小文件无需暂存，直接整传到最终路径。
        if fileSize > 0, fileSize <= Int64(chunkSize) {
            let data = try Data(contentsOf: fileURL)
            try await put(path, data: data, contentType: contentType(for: fileURL))
            return
        }

        let partPath = path + ".part"
        var uploaded: Int64 = (try? await contentLength(partPath)) ?? 0
        if uploaded > fileSize { uploaded = 0 } // 远端残留异常，丢弃重来。

        // 仅当远端已有部分 `.part`（上次中断的残留）时才尝试 Content-Range 续传：
        // 这样普通整传不会因服务器不支持续传而平白多传一遍。
        var staged = false
        if uploaded == fileSize {
            staged = true
        } else if uploaded > 0 {
            if try await appendByContentRange(partPath, fileURL: fileURL, from: uploaded, total: fileSize, chunkSize: Int64(chunkSize)) {
                let remoteSize = (try? await contentLength(partPath)) ?? -1
                staged = remoteSize == fileSize
            }
        }

        if !staged {
            // 全新上传，或续传不被支持/校验不一致：整文件流式覆盖到 .part。
            try await streamUpload(partPath, fileURL: fileURL)
        }

        // 完整后才 MOVE 到最终内容寻址路径，避免半截文件被 exists() 误判为已存在。
        try await move(partPath, to: path)
    }

    func contentLength(_ path: String) async throws -> Int64? {
        var request = try request(path: path, method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.httpBody = """
        <?xml version="1.0" encoding="utf-8" ?>
        <D:propfind xmlns:D="DAV:"><D:prop><D:getcontentlength/></D:prop></D:propfind>
        """.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 207 || http.statusCode == 200 else { return nil }
        return WebDAVMultistatusParser.parse(data: data).first?.size
    }

    // 流式整文件上传（不读进内存），423 锁则回退普通 PUT 的重试逻辑。
    private func streamUpload(_ path: String, fileURL: URL) async throws {
        var request = try request(path: path, method: "PUT")
        request.setValue(contentType(for: fileURL), forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        if let http = response as? HTTPURLResponse, http.statusCode == 423 {
            let data = try Data(contentsOf: fileURL)
            try await put(path, data: data, contentType: contentType(for: fileURL))
            return
        }
        try validate(response, method: "PUT", path: path, allowed: [200, 201, 204])
    }

    // 用 Content-Range 从 `from` 偏移逐块 PUT。返回服务器是否真正支持部分写入：
    // 传完首块后核对远端大小，若未按偏移增长说明服务器忽略了 Content-Range（返回 false 让调用方回退整传）。
    private func appendByContentRange(_ path: String, fileURL: URL, from: Int64, total: Int64, chunkSize: Int64) async throws -> Bool {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var offset = from
        var verified = false
        while offset < total {
            try handle.seek(toOffset: UInt64(offset))
            let upper = min(offset + chunkSize, total)
            let length = Int(upper - offset)
            let data = handle.readData(ofLength: length)
            if data.isEmpty { break }

            var request = try request(path: path, method: "PUT")
            request.setValue(contentType(for: fileURL), forHTTPHeaderField: "Content-Type")
            request.setValue("bytes \(offset)-\(upper - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            request.httpBody = data
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, [200, 201, 204, 308].contains(http.statusCode) else {
                return false
            }
            offset = upper

            if !verified {
                // 首块后核对：服务器是否按偏移把文件写到了预期大小。
                let remoteSize = (try? await contentLength(path)) ?? -1
                if remoteSize != offset { return false }
                verified = true
            }
        }
        return verified || from >= total
    }

    private func move(_ from: String, to: String) async throws {
        guard let destination = url(for: to) else { throw RemoteStorageError.invalidBaseURL }
        var request = try request(path: from, method: "MOVE")
        request.setValue(destination.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("T", forHTTPHeaderField: "Overwrite")
        _ = try await send(request, method: "MOVE", path: from, allowed: [200, 201, 204])
    }

    func delete(_ path: String) async throws {
        let request = try request(path: path, method: "DELETE")
        let (_, response) = try await send(request, method: "DELETE", path: path, allowed: [200, 202, 204, 404])
        if (response as? HTTPURLResponse)?.statusCode == 404 {
            WuyanLog.sync.warning("WebDAV DELETE 目标不存在：\(path)")
        }
    }

    func exists(_ path: String) async throws -> Bool {
        var request = try request(path: path, method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        // 只有 404 表示「不存在」；5xx 是服务端错误，必须抛错以防误判为"首次同步"而覆盖远端。
        if http.statusCode == 404 { return false }
        try validate(response, method: "PROPFIND", path: path, allowed: [200, 207])
        return true
    }

    private func request(path: String, method: String) throws -> URLRequest {
        guard let url = url(for: path) else {
            throw RemoteStorageError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let credential {
            let token = "\(credential.user ?? ""):\(credential.password ?? "")"
                .data(using: .utf8)?
                .base64EncodedString() ?? ""
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func url(for path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let remotePath = normalized(path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joinedPath = [basePath, remotePath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.path = joinedPath.isEmpty ? "/" : "/\(joinedPath)"
        return components.url
    }

    private func normalized(_ path: String) -> String {
        var path = path
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        return path
    }

    /// WebDAV hrefs are server URLs, while the rest of the sync layer uses
    /// paths relative to the configured base URL. Normalize both absolute URL
    /// and absolute-path hrefs and retain collection trailing slashes.
    private func logicalPath(for href: String, isDirectory: Bool) -> String? {
        let decoded = href.removingPercentEncoding ?? href
        let hrefPath: String
        if let url = URL(string: decoded), url.scheme != nil {
            hrefPath = url.path
        } else {
            hrefPath = decoded.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? decoded
        }
        var base = normalized(baseURL.path)
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        var path = normalized(hrefPath)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard base == "/" || path == base || path.hasPrefix(base + "/") else { return nil }
        let suffix = base == "/" ? path : String(path.dropFirst(base.count))
        var result = suffix.isEmpty ? "/" : normalized(suffix)
        if isDirectory && !result.hasSuffix("/") { result += "/" }
        return result
    }

    private func send(
        _ request: URLRequest,
        method: String,
        path: String,
        allowed: Set<Int>,
        lockedRetries: Int = 3
    ) async throws -> (Data, URLResponse) {
        var lastResponse: URLResponse?
        for attempt in 0...lockedRetries {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               (http.statusCode == 423 || [500, 502, 503, 504].contains(http.statusCode)),
               attempt < lockedRetries {
                WuyanLog.sync.warning("WebDAV \(method) \(path) → \(http.statusCode)，第\(attempt + 1)次重试")
                lastResponse = response
                try await Task.sleep(for: .milliseconds(350 * (attempt + 1)))
                continue
            }
            try validate(response, method: method, path: path, allowed: allowed)
            return (data, response)
        }
        try validate(lastResponse ?? URLResponse(), method: method, path: path, allowed: allowed)
        throw RemoteStorageError.requestFailed(method: method, path: path, statusCode: 423)
    }

    private func validate(_ response: URLResponse, method: String, path: String, allowed: Set<Int>) throws {
        guard let http = response as? HTTPURLResponse else {
            WuyanLog.sync.error("WebDAV \(method) \(path) → 非 HTTP 响应")
            throw RemoteStorageError.unexpectedStatus(-1)
        }
        guard allowed.contains(http.statusCode) else {
            WuyanLog.sync.error("WebDAV \(method) \(path) → \(http.statusCode)（允许：\(allowed.sorted().map(String.init).joined(separator: ","))）")
            throw RemoteStorageError.requestFailed(method: method, path: path, statusCode: http.statusCode)
        }
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "heic":
            return "image/heic"
        case "mov":
            return "video/quicktime"
        case "mp4":
            return "video/mp4"
        case "m4a":
            return "audio/mp4"
        default:
            return "application/octet-stream"
        }
    }
}

private final class WebDAVMultistatusParser: NSObject, XMLParserDelegate {
    private var items: [RemoteItem] = []
    private var currentPath = ""
    private var currentSize: Int64 = 0
    private var currentEtag: String?
    private var currentModified: Date?
    private var currentIsDirectory = false
    private var currentElement = ""
    private var buffer = ""

    static func parse(data: Data) -> [RemoteItem] {
        let parser = WebDAVMultistatusParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        buffer = ""
        if elementName.lowercased().hasSuffix("response") {
            currentPath = ""
            currentSize = 0
            currentEtag = nil
            currentModified = nil
            currentIsDirectory = false
        }
        if elementName.lowercased().hasSuffix("collection") {
            currentIsDirectory = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case let name where name.hasSuffix("href"):
            currentPath = value.removingPercentEncoding ?? value
        case let name where name.hasSuffix("getcontentlength"):
            currentSize = Int64(value) ?? 0
        case let name where name.hasSuffix("getetag"):
            currentEtag = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        case let name where name.hasSuffix("getlastmodified"):
            currentModified = Self.httpDateFormatter.date(from: value)
        case let name where name.hasSuffix("response"):
            items.append(RemoteItem(path: currentPath, isDirectory: currentIsDirectory, size: currentSize, etag: currentEtag, modified: currentModified))
        default:
            break
        }
        buffer = ""
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}
