import Foundation
import CryptoKit

struct S3Provider: RemoteStorageProvider {
    var endpoint: URL
    var bucket: String
    var region: String = "us-east-1"
    var accessKey: String
    var secretKey: String
    var pathStyle: Bool = true

    func mkcolRecursive(_ path: String) async throws {}

    func list(_ path: String) async throws -> [RemoteItem] {
        let prefix = key(path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var items: [RemoteItem] = []
        var continuationToken: String?

        repeat {
            var queryItems = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix)
            ]
            if let continuationToken {
                queryItems.append(URLQueryItem(name: "continuation-token", value: continuationToken))
            }

            var components = URLComponents(url: bucketURL(), resolvingAgainstBaseURL: false)!
            components.percentEncodedQuery = canonicalQuery(items: queryItems)
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            try sign(&request, payloadHash: emptyPayloadHash)
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response, allowed: [200])
            let page = S3ListParser.parse(data: data)
            // Keep the provider path contract identical to WebDAV. S3 returns
            // object keys without a leading slash, while SyncEngine compares
            // and stores canonical paths such as `/Wuyan/...`.
            items.append(contentsOf: page.items.map { item in
                var item = item
                let key = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                item.path = "/" + key
                return item
            })
            continuationToken = page.nextContinuationToken
        } while continuationToken != nil

        return items
    }

    func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: objectURL(path))
        request.httpMethod = "GET"
        try sign(&request, payloadHash: emptyPayloadHash)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, allowed: [200])
        return data
    }

    func getVersioned(_ path: String) async throws -> RemoteObjectSnapshot {
        var request = URLRequest(url: objectURL(path))
        request.httpMethod = "GET"
        try sign(&request, payloadHash: emptyPayloadHash)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, allowed: [200])
        let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
            ?? "sha256-" + sha256Hex(data)
        return RemoteObjectSnapshot(data: data, etag: etag)
    }

    func getRange(_ path: String, bytes: Range<Int64>) async throws -> Data {
        var request = URLRequest(url: objectURL(path))
        request.httpMethod = "GET"
        request.setValue("bytes=\(bytes.lowerBound)-\(bytes.upperBound - 1)", forHTTPHeaderField: "Range")
        try sign(&request, payloadHash: emptyPayloadHash)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, allowed: [200, 206])
        return data
    }

    func put(_ path: String, data: Data, contentType: String) async throws {
        let payloadHash = sha256Hex(data)
        var request = URLRequest(url: objectURL(path))
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        try sign(&request, payloadHash: payloadHash)
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response, allowed: [200, 201, 204])
    }

    func putConditionally(
        _ path: String,
        data: Data,
        contentType: String,
        ifMatch: String?,
        ifNoneMatch: Bool
    ) async throws {
        let payloadHash = sha256Hex(data)
        var request = URLRequest(url: objectURL(path))
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        if ifNoneMatch { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        try sign(&request, payloadHash: payloadHash)
        let (_, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status == 409 || status == 412 {
            throw RemoteStorageError.concurrentModification(path: path)
        }
        try validate(response, allowed: [200, 201, 204])
    }

    func putChunked(_ path: String, fileURL: URL, chunkSize: Int) async throws {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size <= chunkSize {
            try await put(path, data: Data(contentsOf: fileURL), contentType: contentType(for: fileURL))
            return
        }

        let uploadId = try await initiateMultipartUpload(path: path, contentType: contentType(for: fileURL))
        do {
            var parts: [S3MultipartPart] = []
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var partNumber = 1
            while true {
                let data = try handle.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { break }
                let etag = try await uploadPart(path: path, uploadId: uploadId, partNumber: partNumber, data: data)
                parts.append(S3MultipartPart(partNumber: partNumber, etag: etag))
                partNumber += 1
            }
            try await completeMultipartUpload(path: path, uploadId: uploadId, parts: parts)
        } catch {
            try? await abortMultipartUpload(path: path, uploadId: uploadId)
            throw error
        }
    }

    func delete(_ path: String) async throws {
        var request = URLRequest(url: objectURL(path))
        request.httpMethod = "DELETE"
        try sign(&request, payloadHash: emptyPayloadHash)
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response, allowed: [200, 202, 204, 404])
    }

    func exists(_ path: String) async throws -> Bool {
        var request = URLRequest(url: objectURL(path))
        request.httpMethod = "HEAD"
        try sign(&request, payloadHash: emptyPayloadHash)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        if http.statusCode == 404 { return false }
        try validate(response, allowed: [200])
        return true
    }

    func contentLength(_ path: String) async throws -> Int64? {
        var request = URLRequest(url: objectURL(path))
        request.httpMethod = "HEAD"
        try sign(&request, payloadHash: emptyPayloadHash)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        try validate(response, allowed: [200])
        return http.expectedContentLength >= 0 ? http.expectedContentLength : nil
    }

    private var emptyPayloadHash: String { sha256Hex(Data()) }

    private func bucketURL() -> URL {
        if pathStyle {
            return endpoint.appendingPathComponent(bucket)
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.host = "\(bucket).\(components.host ?? "")"
        return components.url!
    }

    private func objectURL(_ path: String) -> URL {
        bucketURL().appendingPathComponent(key(path))
    }

    private func objectURL(_ path: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: objectURL(path), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = canonicalQuery(items: queryItems)
        return components.url!
    }

    private func key(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func sign(_ request: inout URLRequest, payloadHash: String) throws {
        guard !accessKey.isEmpty, !secretKey.isEmpty else { throw RemoteStorageError.missingCredentials }
        let now = Date()
        let amzDate = Self.amzDate.string(from: now)
        let dateStamp = Self.dateStamp.string(from: now)
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        let host = hostHeader(for: request.url)
        request.setValue(host, forHTTPHeaderField: "Host")

        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalURI = canonicalURI(for: request.url)
        let canonicalQuery = canonicalQuery(for: request.url)
        let canonicalHeaders = "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let canonicalRequest = "\(request.httpMethod ?? "GET")\n\(canonicalURI)\n\(canonicalQuery)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(credentialScope)\n\(sha256Hex(Data(canonicalRequest.utf8)))"
        let signingKey = signingKey(secret: secretKey, date: dateStamp, region: region)
        let signature = hmacHex(key: signingKey, string: stringToSign)
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
    }

    private func hostHeader(for url: URL?) -> String {
        guard let url else { return "" }
        var host = url.host ?? ""
        if let port = url.port {
            host += ":\(port)"
        }
        return host
    }

    private func canonicalURI(for url: URL?) -> String {
        guard let path = url?.path, !path.isEmpty else { return "/" }
        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { percentEncode(String($0)) }
            .joined(separator: "/")
    }

    private func canonicalQuery(for url: URL?) -> String {
        guard let components = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              let queryItems = components.queryItems,
              !queryItems.isEmpty
        else { return "" }
        return canonicalQuery(items: queryItems)
    }

    private func canonicalQuery(items: [URLQueryItem]) -> String {
        let encoded: [(name: String, value: String)] = items
            .map { item in
                (name: percentEncode(item.name), value: percentEncode(item.value ?? ""))
            }
            .sorted { lhs, rhs in
                lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
            }
        return encoded
            .map { item in "\(item.name)=\(item.value)" }
            .joined(separator: "&")
    }

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.awsAllowedCharacters) ?? value
    }

    private func signingKey(secret: String, date: String, region: String) -> SymmetricKey {
        let kDate = hmac(key: SymmetricKey(data: Data("AWS4\(secret)".utf8)), string: date)
        let kRegion = hmac(key: SymmetricKey(data: kDate), string: region)
        let kService = hmac(key: SymmetricKey(data: kRegion), string: "s3")
        return SymmetricKey(data: hmac(key: SymmetricKey(data: kService), string: "aws4_request"))
    }

    private func hmac(key: SymmetricKey, string: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(string.utf8), using: key))
    }

    private func hmacHex(key: SymmetricKey, string: String) -> String {
        hmac(key: key, string: string).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validate(_ response: URLResponse, allowed: Set<Int>) throws {
        guard let http = response as? HTTPURLResponse else { throw RemoteStorageError.unexpectedStatus(-1) }
        guard allowed.contains(http.statusCode) else { throw RemoteStorageError.unexpectedStatus(http.statusCode) }
    }

    /// S3-compatible services may return HTTP 200 with an XML `<Error>` body
    /// for multipart completion. Treat that body as failure so callers never
    /// cache or clean up an object that was not actually committed.
    private func validateNoS3Error(_ data: Data, path: String) throws {
        guard !data.isEmpty else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard body.range(of: "<Error", options: [.caseInsensitive, .diacriticInsensitive]) == nil else {
            let code = body.firstXMLValue(named: "Code") ?? "unknown error"
            let message = body.firstXMLValue(named: "Message")
            let reason = [code, message].compactMap { $0 }.joined(separator: ": ")
            throw RemoteStorageError.multipartFailed(path: path, reason: reason)
        }
    }

    private func initiateMultipartUpload(path: String, contentType: String) async throws -> String {
        var request = URLRequest(url: objectURL(path, queryItems: [URLQueryItem(name: "uploads", value: "")]))
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        try sign(&request, payloadHash: emptyPayloadHash)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, allowed: [200])
        guard let uploadId = S3MultipartInitiateParser.parseUploadId(data: data), !uploadId.isEmpty else {
            throw RemoteStorageError.unexpectedStatus(-1)
        }
        return uploadId
    }

    private func uploadPart(path: String, uploadId: String, partNumber: Int, data: Data) async throws -> String {
        let query = [
            URLQueryItem(name: "partNumber", value: "\(partNumber)"),
            URLQueryItem(name: "uploadId", value: uploadId)
        ]
        let payloadHash = sha256Hex(data)
        var request = URLRequest(url: objectURL(path, queryItems: query))
        request.httpMethod = "PUT"
        request.httpBody = data
        try sign(&request, payloadHash: payloadHash)
        let (responseBody, response) = try await URLSession.shared.data(for: request)
        try validate(response, allowed: [200])
        guard let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) else {
            throw RemoteStorageError.unexpectedStatus(-1)
        }
        try validateNoS3Error(responseBody, path: path)
        return etag
    }

    private func completeMultipartUpload(path: String, uploadId: String, parts: [S3MultipartPart]) async throws {
        let body = """
        <CompleteMultipartUpload>
        \(parts.map { "<Part><PartNumber>\($0.partNumber)</PartNumber><ETag>\"\($0.etag)\"</ETag></Part>" }.joined())
        </CompleteMultipartUpload>
        """
        let data = Data(body.utf8)
        var request = URLRequest(url: objectURL(path, queryItems: [URLQueryItem(name: "uploadId", value: uploadId)]))
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        try sign(&request, payloadHash: sha256Hex(data))
        let (responseBody, response) = try await URLSession.shared.data(for: request)
        try validate(response, allowed: [200])
        try validateNoS3Error(responseBody, path: path)
    }

    private func abortMultipartUpload(path: String, uploadId: String) async throws {
        var request = URLRequest(url: objectURL(path, queryItems: [URLQueryItem(name: "uploadId", value: uploadId)]))
        request.httpMethod = "DELETE"
        try sign(&request, payloadHash: emptyPayloadHash)
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response, allowed: [204])
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
        case "json":
            return "application/json"
        default:
            return "application/octet-stream"
        }
    }

    private static let amzDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static let dateStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private static let awsAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}

private struct S3ListResult {
    var items: [RemoteItem]
    var nextContinuationToken: String?
}

private struct S3MultipartPart {
    var partNumber: Int
    var etag: String
}

private final class S3MultipartInitiateParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var buffer = ""
    private var uploadId: String?

    static func parseUploadId(data: Data) -> String? {
        let parser = S3MultipartInitiateParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.uploadId
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "UploadId" {
            uploadId = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        buffer = ""
    }
}

private final class S3ListParser: NSObject, XMLParserDelegate {
    private var items: [RemoteItem] = []
    private var nextContinuationToken: String?
    private var currentElement = ""
    private var buffer = ""
    private var key = ""
    private var size: Int64 = 0
    private var etag: String?
    private var modified: Date?

    static func parse(data: Data) -> S3ListResult {
        let parser = S3ListParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return S3ListResult(items: parser.items, nextContinuationToken: parser.nextContinuationToken)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        buffer = ""
        if elementName == "Contents" {
            key = ""
            size = 0
            etag = nil
            modified = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "Key" { key = value }
        if elementName == "Size" { size = Int64(value) ?? 0 }
        if elementName == "ETag" { etag = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        if elementName == "LastModified" { modified = ISO8601DateFormatter().date(from: value) }
        if elementName == "NextContinuationToken" { nextContinuationToken = value.isEmpty ? nil : value }
        if elementName == "Contents" {
            items.append(RemoteItem(path: key, isDirectory: false, size: size, etag: etag, modified: modified))
        }
        buffer = ""
    }
}

private extension String {
    func firstXMLValue(named name: String) -> String? {
        guard let open = range(of: "<\(name)>", options: .caseInsensitive),
              let close = range(
                of: "</\(name)>",
                options: .caseInsensitive,
                range: open.upperBound..<endIndex
              )
        else { return nil }
        let value = self[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
