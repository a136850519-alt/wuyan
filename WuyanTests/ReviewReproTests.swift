import Foundation
import Testing
import GRDB
@testable import Wuyan

private final class ReviewHookedRemote: RemoteStorageProvider, @unchecked Sendable {
    let inner: MockRemoteStorageProvider
    var onGet: ((String) throws -> Void)?

    init(_ inner: MockRemoteStorageProvider) { self.inner = inner }
    func mkcolRecursive(_ path: String) async throws { try await inner.mkcolRecursive(path) }
    func list(_ path: String) async throws -> [RemoteItem] { try await inner.list(path) }
    func get(_ path: String) async throws -> Data {
        if let hook = onGet { try hook(path) }
        return try await inner.get(path)
    }
    func getVersioned(_ path: String) async throws -> RemoteObjectSnapshot { try await inner.getVersioned(path) }
    func getRange(_ path: String, bytes: Range<Int64>) async throws -> Data { try await inner.getRange(path, bytes: bytes) }
    func put(_ path: String, data: Data, contentType: String) async throws { try await inner.put(path, data: data, contentType: contentType) }
    func putConditionally(_ path: String, data: Data, contentType: String, ifMatch: String?, ifNoneMatch: Bool) async throws {
        try await inner.putConditionally(path, data: data, contentType: contentType, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch)
    }
    func putChunked(_ path: String, fileURL: URL, chunkSize: Int) async throws { try await inner.putChunked(path, fileURL: fileURL, chunkSize: chunkSize) }
    func delete(_ path: String) async throws { try await inner.delete(path) }
    func exists(_ path: String) async throws -> Bool { try await inner.exists(path) }
    func contentLength(_ path: String) async throws -> Int64? { try await inner.contentLength(path) }
    func getResumable(_ path: String, into fileURL: URL) async throws { try await inner.getResumable(path, into: fileURL) }
    func putResumable(_ path: String, fileURL: URL, chunkSize: Int) async throws { try await inner.putResumable(path, fileURL: fileURL, chunkSize: chunkSize) }
}

private func reviewEntry(_ db: AppDatabase, body: String, day: String) throws -> Entry {
    let board = try #require(try db.boardDAO.all().first)
    let entry = Entry(boardId: board.id, dayDate: day, journalDate: DayKey.date(from: day)!.addingTimeInterval(12 * 3600), body: body, isDraft: false)
    try db.entryDAO.save(entry)
    return try #require(try db.entryDAO.entry(id: entry.id))
}

private func reviewEdit(_ db: AppDatabase, _ id: UUID, body: String) throws {
    var entry = try #require(try db.entryDAO.entry(id: id))
    entry.body = body
    try db.entryDAO.save(entry)
}

extension GlobalStateSuite {
    @Suite("Review repro")
    struct ReviewReproTests {
        @Test("R1 归档不会用旧本地版本覆盖远端")
        func archiveRejectsStaleLocalVersion() async throws {
            try await TestIsolation.withIsolatedDefaults { _ in
                let remote = MockRemoteStorageProvider()
                let a = try AppDatabase.makeInMemory()
                let b = try AppDatabase.makeInMemory()
                let entry = try reviewEntry(a, body: "original", day: "2025-03-01")
                _ = try await SyncEngine(provider: remote, database: a, backendFingerprint: "review").syncNow()
                _ = try await SyncEngine(provider: remote, database: b, backendFingerprint: "review").syncNow()
                try reviewEdit(b, entry.id, body: "B 的新编辑")
                _ = try await SyncEngine(provider: remote, database: b, backendFingerprint: "review").syncNow()
                _ = try? await SyncEngine(provider: remote, database: a, backendFingerprint: "review").archiveYear(2025)
                _ = try await SyncEngine(provider: remote, database: b, backendFingerprint: "review").syncNow()
                #expect(try #require(try b.entryDAO.entry(id: entry.id)).body == "B 的新编辑")
            }
        }

        @Test("R2 pullYear 保留本地 dirty 编辑")
        func pullYearKeepsDirtyEdit() async throws {
            try await TestIsolation.withIsolatedDefaults { _ in
                let remote = MockRemoteStorageProvider()
                let db = try AppDatabase.makeInMemory()
                let entry = try reviewEntry(db, body: "synced", day: "2025-05-01")
                _ = try await SyncEngine(provider: remote, database: db, backendFingerprint: "review").syncNow()
                try reviewEdit(db, entry.id, body: "本地未同步的新内容")
                _ = try await SyncEngine(provider: remote, database: db, backendFingerprint: "review").pullYear(2025)
                let after = try #require(try db.entryDAO.entry(id: entry.id))
                #expect(after.body == "本地未同步的新内容")
                #expect(after.dirty)
            }
        }

        @Test("R3 拉取期间保存的输入进入冲突副本")
        func pullPreservesConcurrentEdit() async throws {
            try await TestIsolation.withIsolatedDefaults { _ in
                let remote = MockRemoteStorageProvider()
                let a = try AppDatabase.makeInMemory()
                let b = try AppDatabase.makeInMemory()
                let entry = try reviewEntry(a, body: "v1", day: "2026-09-01")
                _ = try await SyncEngine(provider: remote, database: a, backendFingerprint: "review").syncNow()
                _ = try await SyncEngine(provider: remote, database: b, backendFingerprint: "review").syncNow()
                try reviewEdit(b, entry.id, body: "B 的远端修改")
                _ = try await SyncEngine(provider: remote, database: b, backendFingerprint: "review").syncNow()

                let hooked = ReviewHookedRemote(remote)
                var fired = false
                hooked.onGet = { path in
                    guard !fired, path.hasPrefix("/Wuyan/entries/"), path.contains(entry.id.uuidString) else { return }
                    fired = true
                    try reviewEdit(a, entry.id, body: "A 用户在同步进行中刚打的字")
                }
                let report = try await SyncEngine(provider: hooked, database: a, backendFingerprint: "review").syncNow()
                let after = try #require(try a.entryDAO.entry(id: entry.id))
                let copies = try a.entryDAO.conflictCopies()
                #expect(fired)
                #expect(after.body == "A 用户在同步进行中刚打的字" || copies.contains { $0.envelope.entry.body == "A 用户在同步进行中刚打的字" })
                #expect(report.conflicts.contains(entry.id))
            }
        }

        @Test("R4 带旧版本保存不能复活已移除条目")
        func removedEntryCannotBeResurrected() throws {
            let db = try AppDatabase.makeInMemory()
            let entry = try reviewEntry(db, body: "x", day: "2024-01-02")
            let loaded = try #require(try db.entryDAO.entry(id: entry.id))
            try db.entryDAO.removeArchivedLocal(id: entry.id)
            var editorCopy = loaded
            editorCopy.body = "归档后继续输入"
            #expect(throws: EntrySaveError.self) {
                try db.entryDAO.save(editorCopy, expectedContentHash: loaded.contentHash)
            }
            #expect(try db.entryDAO.entry(id: entry.id) == nil)
        }

        @Test("R5 WebDAV list 归一化 base path")
        func webDAVHrefIsLogicalPath() async throws {
            ReviewStubURLProtocol.requests = []
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ReviewStubURLProtocol.self]
            let session = URLSession(configuration: config)
            let provider = WebDAVProvider(baseURL: URL(string: "https://nas.local:5006/dav")!, username: "u", password: "p", session: session)
            let items = try await provider.list("/Wuyan/.sync/")
            let file = try #require(items.first { !$0.isDirectory })
            #expect(file.path == "/Wuyan/.sync/dev.state")
            _ = try await provider.get(file.path)
            #expect(ReviewStubURLProtocol.requests.last?.url?.path == "/dav/Wuyan/.sync/dev.state")
        }
    }
}

private final class ReviewStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let body: Data
        let status: Int
        if request.httpMethod == "PROPFIND" {
            status = 207
            body = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
              <D:response><D:href>/dav/Wuyan/.sync/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
              <D:response><D:href>/dav/Wuyan/.sync/dev.state</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>2</D:getcontentlength></D:prop></D:propstat></D:response>
            </D:multistatus>
            """.utf8)
        } else {
            status = request.url?.path == "/dav/Wuyan/.sync/dev.state" ? 200 : 404
            body = Data("{}".utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
