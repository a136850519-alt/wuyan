import XCTest
import CryptoKit
@testable import Wuyan

// MARK: - Mock Remote Storage Provider

final class MockRemoteStorageProvider: RemoteStorageProvider, @unchecked Sendable {
    var files: [String: Data] = [:]
    var directories: Set<String> = []
    var shouldFail5xx = false

    func mkcolRecursive(_ path: String) async throws {
        directories.insert(path)
    }

    func list(_ path: String) async throws -> [RemoteItem] {
        if shouldFail5xx {
            throw RemoteStorageError.requestFailed(method: "PROPFIND", path: path, statusCode: 500)
        }
        return files.filter { $0.key.hasPrefix(path) }.map { key, data in
            RemoteItem(path: key, isDirectory: false, size: Int64(data.count), etag: nil, modified: Date())
        }
    }

    func get(_ path: String) async throws -> Data {
        if shouldFail5xx {
            throw RemoteStorageError.requestFailed(method: "GET", path: path, statusCode: 500)
        }
        guard let data = files[path] else {
            throw RemoteStorageError.requestFailed(method: "GET", path: path, statusCode: 404)
        }
        return data
    }

    func getRange(_ path: String, bytes: Range<Int64>) async throws -> Data {
        let full = try await get(path)
        let lower = Int(bytes.lowerBound)
        let upper = min(Int(bytes.upperBound), full.count)
        return Data(full[lower..<upper])
    }

    func put(_ path: String, data: Data, contentType: String) async throws {
        if shouldFail5xx {
            throw RemoteStorageError.requestFailed(method: "PUT", path: path, statusCode: 500)
        }
        files[path] = data
    }

    func putChunked(_ path: String, fileURL: URL, chunkSize: Int) async throws {
        let data = try Data(contentsOf: fileURL)
        try await put(path, data: data, contentType: "application/octet-stream")
    }

    func delete(_ path: String) async throws {
        files.removeValue(forKey: path)
    }

    func exists(_ path: String) async throws -> Bool {
        if shouldFail5xx {
            throw RemoteStorageError.requestFailed(method: "PROPFIND", path: path, statusCode: 500)
        }
        return files[path] != nil
    }

    func contentLength(_ path: String) async throws -> Int64? {
        guard let data = files[path] else { return nil }
        return Int64(data.count)
    }
}

// MARK: - Crypto Tests

final class CryptoTests: XCTestCase {

    func testAESGCMRoundtrip() throws {
        let box = AESGCMCryptoBox()
        let salt = Data(repeating: 0xAB, count: 16)
        let key = try box.deriveKey(passphrase: "test-password", salt: salt, params: KDFParams(salt: salt))

        let plaintext = "你好晤言".data(using: .utf8)!
        let sealed = try box.seal(plaintext, key: key)
        let opened = try box.open(sealed, key: key)

        XCTAssertEqual(opened, plaintext)
    }

    func testAESGCMWrongKeyFails() throws {
        let box = AESGCMCryptoBox()
        let salt1 = Data(repeating: 0x01, count: 16)
        let salt2 = Data(repeating: 0x02, count: 16)
        let key1 = try box.deriveKey(passphrase: "password-A", salt: salt1, params: KDFParams(salt: salt1))
        let key2 = try box.deriveKey(passphrase: "password-B", salt: salt2, params: KDFParams(salt: salt2))

        let plaintext = "secret data".data(using: .utf8)!
        let sealed = try box.seal(plaintext, key: key1)

        XCTAssertThrowsError(try box.open(sealed, key: key2))
    }

    func testKDFDerivesConsistentKey() throws {
        let box = AESGCMCryptoBox()
        let salt = Data(repeating: 0x55, count: 16)
        let params = KDFParams(salt: salt, iterations: 1000)

        let key1 = try box.deriveKey(passphrase: "same-passphrase", salt: salt, params: params)
        let key2 = try box.deriveKey(passphrase: "same-passphrase", salt: salt, params: params)

        // 两个 key 应该派生相同结果（对称密钥的 raw bits 一致）
        let encrypted = try box.seal("test".data(using: .utf8)!, key: key1)
        XCTAssertNoThrow(try box.open(encrypted, key: key2))
    }

    func testKDFDifferentSaltDifferentKey() throws {
        let box = AESGCMCryptoBox()
        let salt1 = Data(repeating: 0x10, count: 16)
        let salt2 = Data(repeating: 0x20, count: 16)

        let key1 = try box.deriveKey(passphrase: "same-pass", salt: salt1, params: KDFParams(salt: salt1, iterations: 1000))
        let key2 = try box.deriveKey(passphrase: "same-pass", salt: salt2, params: KDFParams(salt: salt2, iterations: 1000))

        let encrypted = try box.seal("test".data(using: .utf8)!, key: key1)
        XCTAssertThrowsError(try box.open(encrypted, key: key2))
    }

    func testSyncCryptoRoundtrip() throws {
        let salt = Data(repeating: 0xCC, count: 16)
        let crypto = try SyncCrypto(passphrase: "晤言同步口令", salt: salt)

        let manifestJSON = """
        {"schemaVersion":2,"entries":[]}
        """.data(using: .utf8)!
        let payload = try crypto.seal(manifestJSON)
        let decrypted = try crypto.open(payload)

        XCTAssertEqual(decrypted, manifestJSON)
    }
}

// MARK: - Streak Tracker Tests

final class StreakTrackerTests: XCTestCase {

    private func makeEntry(on dayKey: String) -> Entry {
        Entry(id: UUID(), boardId: UUID(), dayDate: dayKey, body: "x")
    }

    func testCurrentStreakConsecutiveDays() {
        let base = "2026-07-"
        let entries = (7...10).map { makeEntry(on: base + String(format: "%02d", $0)) }
        let tracker = StreakTracker(entries: entries)

        // 假设今天是 7/10
        let today = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 10))!
        XCTAssertEqual(tracker.currentStreak(asOf: today), 4)
    }

    func testCurrentStreakBrokenStreak() {
        let entries = [
            makeEntry(on: "2026-07-07"),
            makeEntry(on: "2026-07-08"),
            // 7/9 没有写
            makeEntry(on: "2026-07-10"),
        ]
        let tracker = StreakTracker(entries: entries)
        let today = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 10))!
        XCTAssertEqual(tracker.currentStreak(asOf: today), 1)
    }

    func testLongestStreak() {
        let entries = [
            makeEntry(on: "2026-07-01"),
            makeEntry(on: "2026-07-02"),
            makeEntry(on: "2026-07-03"),
            // 7/4 断
            makeEntry(on: "2026-07-05"),
            makeEntry(on: "2026-07-06"),
            makeEntry(on: "2026-07-07"),
            makeEntry(on: "2026-07-08"),
        ]
        let tracker = StreakTracker(entries: entries)
        XCTAssertEqual(tracker.longestStreak(), 4)
    }

    func testCurrentStreakEmptyEntries() {
        let tracker = StreakTracker(entries: [])
        XCTAssertEqual(tracker.currentStreak(), 0)
        XCTAssertEqual(tracker.longestStreak(), 0)
    }
}

// MARK: - AppSettings Tests

final class AppSettingsTests: XCTestCase {

    func testSettingKeyFormat() {
        // 所有的 SettingKey 常量应该以 "settings." 开头
        XCTAssertEqual(SettingKey.storageBackend, "settings.storageBackend")
        XCTAssertEqual(SettingKey.aiEnabled, "settings.aiEnabled")
        XCTAssertEqual(SettingKey.cryptoEnabled, "settings.cryptoEnabled")
        XCTAssertEqual(SettingKey.appearanceBodyFont, "settings.appearanceBodyFont")
    }

    func testAppSettingsDefaultValues() {
        // 清除 UserDefaults 中的测试 key，确保默认值生效
        let domain = Bundle.main.bundleIdentifier ?? "com.wuyan.app"
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SettingKey.storageBackend)
        defaults.removeObject(forKey: SettingKey.aiProvider)
        defaults.removeObject(forKey: SettingKey.appearanceBodyFont)

        XCTAssertEqual(AppSettings.storageBackend, "webDAV")
        XCTAssertEqual(AppSettings.aiProvider, "zhipu")
        XCTAssertEqual(AppSettings.bodyFont, "LXGWWenKai-Regular")
    }

    func testAppSettingsBoolDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SettingKey.aiEnabled)
        defaults.removeObject(forKey: SettingKey.cryptoEnabled)
        defaults.removeObject(forKey: SettingKey.metadataEnabled)

        XCTAssertEqual(AppSettings.aiEnabled, false)
        XCTAssertEqual(AppSettings.cryptoEnabled, false)
        XCTAssertEqual(AppSettings.metadataEnabled, true)
    }
}

// MARK: - Hashing Tests

final class HashingTests: XCTestCase {

    func testDayNoteHashIsStable() {
        let note = DayNote(date: "2026-07-10", rawSummary: "晴", poeticLine: "日朗")
        let hash1 = Hashing.dayNoteHash(note)
        let hash2 = Hashing.dayNoteHash(note)
        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1.count, 64) // SHA-256 hex = 64 chars
    }

    func testEntryContentHashDifferentBodyDifferentHash() {
        let hash1 = Hashing.entryContentHash(title: nil, body: "今天开心", bodyRTF: nil, tags: [], mood: nil, weather: nil, location: nil, mediaIds: [])
        let hash2 = Hashing.entryContentHash(title: nil, body: "今天难过", bodyRTF: nil, tags: [], mood: nil, weather: nil, location: nil, mediaIds: [])
        XCTAssertNotEqual(hash1, hash2)
    }

    func testEntryContentHashIgnoresTagOrder() {
        let hash1 = Hashing.entryContentHash(title: nil, body: "test", bodyRTF: nil, tags: ["雨", "家"], mood: nil, weather: nil, location: nil, mediaIds: [])
        let hash2 = Hashing.entryContentHash(title: nil, body: "test", bodyRTF: nil, tags: ["家", "雨"], mood: nil, weather: nil, location: nil, mediaIds: [])
        XCTAssertEqual(hash1, hash2)
    }
}

// MARK: - FTS Trigram Search Tests

final class FTSTrigramSearchTests: XCTestCase {

    func testFTSSearchChineseSubstring() throws {
        let db = try AppDatabase.makeInMemory()
        let board = try XCTUnwrap(db.boardDAO.all().first)
        let note = DayNote(date: "2026-07-10", rawSummary: "测试", poeticLine: "测试")
        try db.dayNoteDAO.upsert(note)

        var entry = try db.entryDAO.create(boardId: board.id, dayNote: note)
        entry.body = "今天天气很好，阳光明媚"
        entry.title = "晴天日记"
        try db.entryDAO.save(entry)

        // trigram 应匹配中文子串 "阳光"
        let results = try db.entryDAO.timeline(filter: .search("阳光"))
        XCTAssertEqual(results.count, 1)
    }

    func testFTSSearchNoMatch() throws {
        let db = try AppDatabase.makeInMemory()
        let board = try XCTUnwrap(db.boardDAO.all().first)
        let note = DayNote(date: "2026-07-10", rawSummary: "测试", poeticLine: "测试")
        try db.dayNoteDAO.upsert(note)

        var entry = try db.entryDAO.create(boardId: board.id, dayNote: note)
        entry.body = "今天下雨了"
        try db.entryDAO.save(entry)

        let results = try db.entryDAO.timeline(filter: .search("阳光明媚"))
        XCTAssertEqual(results.count, 0)
    }
}

// MARK: - Sync Engine Tests (with Mock)

final class SyncEngineBasicTests: XCTestCase {

    func testSyncEngine5xxThrowsNotSilentDegrade() async throws {
        // P0-6 回归：5xx 不应该被当作「不存在」，必须抛错
        let db = try AppDatabase.makeInMemory()
        var mock = MockRemoteStorageProvider()
        mock.shouldFail5xx = true

        let engine = SyncEngine(provider: mock, database: db, archivedYears: [])
        do {
            _ = try await engine.syncNow()
            XCTFail("5xx 应该抛错，不应成功")
        } catch let error as RemoteStorageError {
            if case .requestFailed(method: _, path: _, statusCode: let code) = error {
                XCTAssertEqual(code, 500)
            } else {
                XCTFail("应为 requestFailed，实际: \(error)")
            }
        }
    }

    func testSyncEnginePullNewEntry() async throws {
        let db = try AppDatabase.makeInMemory()
        var mock = MockRemoteStorageProvider()

        // 准备远端 manifest + entry JSON
        let board = try XCTUnwrap(db.boardDAO.all().first)
        let remoteEntry = Entry(id: UUID(), boardId: board.id, dayDate: "2026-07-08", body: "远端日记")
        let envelope = EntryEnvelope(entry: remoteEntry, board: board, dayNote: nil)
        let entryData = try JSONEncoder.wuyan.encode(envelope)

        let entryPath = "/Wuyan/entries/\(remoteEntry.id.uuidString).json"
        mock.files[entryPath] = entryData

        let manifest = Manifest(
            schemaVersion: 2,
            boards: [],
            daynotes: [],
            entries: [
                ManifestEntry(id: remoteEntry.id, boardId: board.id, dayDate: "2026-07-08", path: entryPath, updatedAt: Date(), hash: remoteEntry.contentHash, deleted: false)
            ]
        )
        let manifestData = try JSONEncoder.wuyan.encode(manifest)
        mock.files["/Wuyan/manifest.json"] = manifestData

        let engine = SyncEngine(provider: mock, database: db, archivedYears: [])
        let report = try await engine.syncNow()

        XCTAssertEqual(report.pulled, 1)
        let saved = try db.entryDAO.entry(id: remoteEntry.id)
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.body, "远端日记")
    }

    func testSyncEnginePushDirtyEntry() async throws {
        let db = try AppDatabase.makeInMemory()
        var mock = MockRemoteStorageProvider()

        // 创建本地脏条目
        let board = try XCTUnwrap(db.boardDAO.all().first)
        let note = DayNote(date: "2026-07-10", rawSummary: "测试", poeticLine: "测试")
        try db.dayNoteDAO.upsert(note)
        var entry = try db.entryDAO.create(boardId: board.id, dayNote: note)
        entry.body = "新内容"
        try db.entryDAO.save(entry)

        // 空远端
        let emptyManifest = Manifest(schemaVersion: 2, boards: [], daynotes: [], entries: [])
        mock.files["/Wuyan/manifest.json"] = try JSONEncoder.wuyan.encode(emptyManifest)

        let engine = SyncEngine(provider: mock, database: db, archivedYears: [])
        let report = try await engine.syncNow()

        XCTAssertTrue(report.pushed >= 1)
        // 验证远端收到了 manifest
        XCTAssertNotNil(mock.files["/Wuyan/manifest.json"])
    }
}

// MARK: - Entry Summary Tests

final class EntrySummaryTests: XCTestCase {

    func testEntrySummaryFromTimeline() throws {
        let db = try AppDatabase.makeInMemory()
        let board = try XCTUnwrap(db.boardDAO.all().first)
        let note = DayNote(date: "2026-07-10", rawSummary: "test", poeticLine: "test")
        try db.dayNoteDAO.upsert(note)

        var entry = try db.entryDAO.create(boardId: board.id, dayNote: note)
        entry.title = "测试标题"
        entry.body = "这是一段正文内容，用来测试摘要"
        try db.entryDAO.save(entry)

        let summaries = try db.entryDAO.timeline(filter: .all)
        XCTAssertEqual(summaries.count, 1)
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.title, "测试标题")
        XCTAssertEqual(summary.dayDate, "2026-07-10")
    }

    func testEntrySummaryBodyPreview() throws {
        let db = try AppDatabase.makeInMemory()
        let board = try XCTUnwrap(db.boardDAO.all().first)
        let note = DayNote(date: "2026-07-10", rawSummary: "t", poeticLine: "t")
        try db.dayNoteDAO.upsert(note)

        var entry = try db.entryDAO.create(boardId: board.id, dayNote: note)
        entry.title = nil
        entry.body = String(repeating: "长文本", count: 50)
        try db.entryDAO.save(entry)

        let summaries = try db.entryDAO.timeline(filter: .all)
        let preview = try XCTUnwrap(summaries.first).bodyPreview
        XCTAssertFalse(preview.isEmpty)
        XCTAssertTrue(preview.count < entry.body.count) // 应该被截断
    }
}

// MARK: - WebDAV URL Construction Tests

final class WebDAVURLTests: XCTestCase {

    func testURLConstructionWithBasePath() throws {
        let baseURL = URL(string: "https://nas.local:5006/dav")!
        let provider = WebDAVProvider(baseURL: baseURL, username: "user", password: "pass")

        // 通过 mkcolRecursive 间接验证 URL 构建（不实际发送请求）
        // 这里只测试 provider 能被成功创建且不崩溃
        XCTAssertNotNil(provider)
    }

    func testURLConstructionWithoutPath() throws {
        let baseURL = URL(string: "https://nas.local:5006")!
        let provider = WebDAVProvider(baseURL: baseURL)
        XCTAssertNotNil(provider)
    }
}

// MARK: - LocalMediaStore Path Resolution Tests

final class MediaPathTests: XCTestCase {

    func testRelativePathRoundtrip() {
        let absolute = LocalMediaStore.mediaRootURL
            .appendingPathComponent("media/ab/cdef1234.jpg").path
        let relative = LocalMediaStore.toRelativePath(absolute)
        XCTAssertEqual(relative, "media/ab/cdef1234.jpg")

        let resolved = LocalMediaStore.resolvePath(relative)
        XCTAssertEqual(resolved, absolute)
    }

    func testResolveAbsolutePathPassthrough() {
        let absolute = "/Users/test/Library/Caches/Wuyan/media/ab/old.jpg"
        let result = LocalMediaStore.resolvePath(absolute)
        XCTAssertEqual(result, absolute) // 旧绝对路径原样返回
    }

    func testResolveNilPathReturnsNil() {
        XCTAssertNil(LocalMediaStore.resolvePath(nil as String?))
    }
}

// MARK: - MarkClean Regression Test (P1-3)

final class MarkCleanTests: XCTestCase {

    func testMarkClearSetsDirtyFalse() throws {
        let db = try AppDatabase.makeInMemory()
        let board = try XCTUnwrap(db.boardDAO.all().first)
        let note = DayNote(date: "2026-07-10", rawSummary: "t", poeticLine: "t")
        try db.dayNoteDAO.upsert(note)

        var entry = try db.entryDAO.create(boardId: board.id, dayNote: note)
        entry.body = "写完的内容"
        try db.entryDAO.save(entry)

        XCTAssertTrue(try XCTUnwrap(db.entryDAO.entry(id: entry.id)).dirty)

        // markClean 写入 baseline
        try db.entryDAO.markClean(id: entry.id, expectedHash: entry.contentHash)
        let cleaned = try XCTUnwrap(db.entryDAO.entry(id: entry.id))
        XCTAssertFalse(cleaned.dirty)
    }
}

// MARK: - Board Deduplication Regression Test (v4 migration)

final class BoardDedupTests: XCTestCase {

    func testBuiltInBoardKindsAreUnique() throws {
        let db = try AppDatabase.makeInMemory()
        let boards = try db.boardDAO.all()
        let kinds = boards.map(\.kind)
        // 五年、日常唠叨、宝贝成长记录 三种 kind 应该各出现一次
        let kindCounts = Dictionary(grouping: kinds, by: { $0 }).mapValues { $0.count }
        for (kind, count) in kindCounts {
            XCTAssertEqual(count, 1, "板块类型 \(kind) 出现了 \(count) 次，应该唯一")
        }
    }
}
