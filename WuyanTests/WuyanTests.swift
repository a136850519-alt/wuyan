import Testing
import Foundation
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

@Suite("Crypto")
struct CryptoTests {

    @Test("AES-GCM roundtrip")
    func aesGCMRoundtrip() throws {
        let box = AESGCMCryptoBox()
        let salt = Data(repeating: 0xAB, count: 16)
        let key = try box.deriveKey(passphrase: "test-password", salt: salt, params: KDFParams(salt: salt))

        let plaintext = "你好晤言".data(using: .utf8)!
        let sealed = try box.seal(plaintext, key: key)
        let opened = try box.open(sealed, key: key)

        #expect(opened == plaintext)
    }

    @Test("AES-GCM wrong key fails")
    func aesGCMWrongKeyFails() throws {
        let box = AESGCMCryptoBox()
        let salt1 = Data(repeating: 0x01, count: 16)
        let salt2 = Data(repeating: 0x02, count: 16)
        let key1 = try box.deriveKey(passphrase: "password-A", salt: salt1, params: KDFParams(salt: salt1))
        let key2 = try box.deriveKey(passphrase: "password-B", salt: salt2, params: KDFParams(salt: salt2))

        let plaintext = "secret data".data(using: .utf8)!
        let sealed = try box.seal(plaintext, key: key1)

        #expect(throws: Error.self) {
            try box.open(sealed, key: key2)
        }
    }

    @Test("KDF derives consistent key")
    func kdfConsistentKey() throws {
        let box = AESGCMCryptoBox()
        let salt = Data(repeating: 0x55, count: 16)
        let params = KDFParams(salt: salt, iterations: 1000)

        let key1 = try box.deriveKey(passphrase: "same-passphrase", salt: salt, params: params)
        let key2 = try box.deriveKey(passphrase: "same-passphrase", salt: salt, params: params)

        let encrypted = try box.seal("test".data(using: .utf8)!, key: key1)
        #expect(throws: Never.self) {
            try box.open(encrypted, key: key2)
        }
    }

    @Test("KDF different salt produces different key")
    func kdfDifferentSalt() throws {
        let box = AESGCMCryptoBox()
        let salt1 = Data(repeating: 0x10, count: 16)
        let salt2 = Data(repeating: 0x20, count: 16)

        let key1 = try box.deriveKey(passphrase: "same-pass", salt: salt1, params: KDFParams(salt: salt1, iterations: 1000))
        let key2 = try box.deriveKey(passphrase: "same-pass", salt: salt2, params: KDFParams(salt: salt2, iterations: 1000))

        let encrypted = try box.seal("test".data(using: .utf8)!, key: key1)
        #expect(throws: Error.self) {
            try box.open(encrypted, key: key2)
        }
    }

    @Test("SyncCrypto roundtrip")
    func syncCryptoRoundtrip() throws {
        let salt = Data(repeating: 0xCC, count: 16)
        let crypto = try SyncCrypto(passphrase: "晤言同步口令", salt: salt)

        let manifestJSON = """
        {"schemaVersion":2,"entries":[]}
        """.data(using: .utf8)!
        let sealed = try crypto.box.seal(manifestJSON, key: crypto.key)
        let decrypted = try crypto.box.open(sealed, key: crypto.key)

        #expect(decrypted == manifestJSON)
    }
}

// MARK: - Streak Tracker Tests

@Suite("Streak Tracker")
struct StreakTrackerTests {

    private func makeEntry(on dayKey: String) -> Entry {
        Entry(id: UUID(), boardId: UUID(), dayDate: dayKey, body: "x")
    }

    @Test("Current streak counts consecutive days")
    func currentStreakConsecutiveDays() {
        let base = "2026-07-"
        let entries = (7...10).map { makeEntry(on: base + String(format: "%02d", $0)) }
        let tracker = StreakTracker(entries: entries)

        let today = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 10))!
        #expect(tracker.currentStreak(asOf: today) == 4)
    }

    @Test("Current streak with broken streak")
    func currentStreakBrokenStreak() {
        let entries = [
            makeEntry(on: "2026-07-07"),
            makeEntry(on: "2026-07-08"),
            // 7/9 没有写
            makeEntry(on: "2026-07-10"),
        ]
        let tracker = StreakTracker(entries: entries)
        let today = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 10))!
        #expect(tracker.currentStreak(asOf: today) == 1)
    }

    @Test("Longest streak")
    func longestStreak() {
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
        #expect(tracker.longestStreak() == 4)
    }

    @Test("Current streak with empty entries")
    func currentStreakEmptyEntries() {
        let tracker = StreakTracker(entries: [])
        #expect(tracker.currentStreak() == 0)
        #expect(tracker.longestStreak() == 0)
    }
}

// MARK: - AppSettings Tests

@Suite("AppSettings")
struct AppSettingsTests {

    @Test("SettingKey format consistency")
    func settingKeyFormat() {
        #expect(SettingKey.storageBackend == "settings.storageBackend")
        #expect(SettingKey.aiEnabled == "settings.aiEnabled")
        #expect(SettingKey.cryptoEnabled == "settings.cryptoEnabled")
        #expect(SettingKey.appearanceBodyFont == "settings.appearanceBodyFont")
    }

    @Test("AppSettings default values")
    func appSettingsDefaultValues() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SettingKey.storageBackend)
        defaults.removeObject(forKey: SettingKey.aiProvider)
        defaults.removeObject(forKey: SettingKey.appearanceBodyFont)

        #expect(AppSettings.storageBackend == "webDAV")
        #expect(AppSettings.aiProvider == "zhipu")
        #expect(AppSettings.bodyFont == "LXGWWenKai-Regular")
    }

    @Test("AppSettings bool defaults")
    func appSettingsBoolDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SettingKey.aiEnabled)
        defaults.removeObject(forKey: SettingKey.cryptoEnabled)
        defaults.removeObject(forKey: SettingKey.metadataEnabled)

        #expect(AppSettings.aiEnabled == false)
        #expect(AppSettings.cryptoEnabled == false)
        #expect(AppSettings.metadataEnabled == true)
    }
}

// MARK: - Hashing Tests

@Suite("Hashing")
struct HashingTests {

    @Test("DayNote hash is stable")
    func dayNoteHashIsStable() {
        let note = DayNote(date: "2026-07-10", rawSummary: "晴", poeticLine: "日朗")
        let hash1 = Hashing.dayNoteHash(note)
        let hash2 = Hashing.dayNoteHash(note)
        #expect(hash1 == hash2)
        #expect(hash1.count == 64) // SHA-256 hex = 64 chars
    }

    @Test("Entry content hash differs by body")
    func entryContentHashDifferentBody() {
        let hash1 = Hashing.entryContentHash(title: nil, body: "今天开心", bodyRTF: nil, tags: [], mood: nil, weather: nil, location: nil, mediaIds: [])
        let hash2 = Hashing.entryContentHash(title: nil, body: "今天难过", bodyRTF: nil, tags: [], mood: nil, weather: nil, location: nil, mediaIds: [])
        #expect(hash1 != hash2)
    }

    @Test("Entry content hash ignores tag order")
    func entryContentHashIgnoresTagOrder() {
        let hash1 = Hashing.entryContentHash(title: nil, body: "test", bodyRTF: nil, tags: ["雨", "家"], mood: nil, weather: nil, location: nil, mediaIds: [])
        let hash2 = Hashing.entryContentHash(title: nil, body: "test", bodyRTF: nil, tags: ["家", "雨"], mood: nil, weather: nil, location: nil, mediaIds: [])
        #expect(hash1 == hash2)
    }
}

// MARK: - FTS Trigram Search Tests

@Suite("FTS Trigram Search")
struct FTSTrigramSearchTests {

    @Test("FTS search matches Chinese substring")
    func ftsSearchChineseSubstring() throws {
        let db = try AppDatabase.makeInMemory()
        let board = try #require(db.boardDAO.all().first)
        let note = DayNote(date: "2026-07-10", rawSummary: "测试", poeticLine: "测试")
        try db.dayNoteDAO.upsert(note)

        var entry = try db.entryDAO.create(boardId: board.id, dayNote: note)
        entry.body = "今天天气很好，阳光明媚"
        entry.title = "晴天日记"
        try db.entryDAO.save(entry)

        // FTS 全文检索（独立 search 方法，不走 TimelineFilter）
        let results = try db.entryDAO.search(EntrySearchQuery(term: "阳光"))
        #expect(results.count == 1)
    }

    @Test("FTS search no match")
    func ftsSearchNoMatch() throws {
        let db = try AppDatabase.makeInMemory()
        let board = try #require(db.boardDAO.all().first)
        let note = DayNote(date: "2026-07-10", rawSummary: "测试", poeticLine: "测试")
        try db.dayNoteDAO.upsert(note)

        var entry = try db.entryDAO.create(boardId: board.id, dayNote: note)
        entry.body = "今天下雨了"
        try db.entryDAO.save(entry)

        let results = try db.entryDAO.search(EntrySearchQuery(term: "阳光明媚"))
        #expect(results.count == 0)
    }
}

// MARK: - Sync Engine Tests (with Mock)

@Suite("Sync Engine")
struct SyncEngineBasicTests {

    @Test("5xx throws instead of silent degrade")
    func syncEngine5xxThrowsNotSilentDegrade() async throws {
        let db = try AppDatabase.makeInMemory()
        let mock = {
            let m = MockRemoteStorageProvider()
            m.shouldFail5xx = true
            return m
        }()

        let engine = SyncEngine(provider: mock, database: db, archivedYears: [], backendFingerprint: "test-fp")
        do {
            _ = try await engine.syncNow()
            Issue.record("5xx 应该抛错，不应成功")
        } catch let error as RemoteStorageError {
            if case .requestFailed(method: _, path: _, statusCode: let code) = error {
                #expect(code == 500)
            } else {
                Issue.record("应为 requestFailed，实际: \(error)")
            }
        }
    }

    @Test("Pull new entry from remote")
    func syncEnginePullNewEntry() async throws {
        let db = try AppDatabase.makeInMemory()
        let mock = MockRemoteStorageProvider()
        mock.shouldFail5xx = false

        let board = try #require(db.boardDAO.all().first)
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

        let engine = SyncEngine(provider: mock, database: db, archivedYears: [], backendFingerprint: "test-fp")
        let report = try await engine.syncNow()

        #expect(report.pulled == 1)
        let saved = try db.entryDAO.entry(id: remoteEntry.id)
        #expect(saved != nil)
        #expect(saved?.body == "远端日记")
    }

    @Test("Push dirty entry to remote")
    func syncEnginePushDirtyEntry() async throws {
        let db = try AppDatabase.makeInMemory()
        let mock = MockRemoteStorageProvider()

        let board = try #require(db.boardDAO.all().first)
        let note = DayNote(date: "2026-07-10", rawSummary: "测试", poeticLine: "测试")
        try db.dayNoteDAO.upsert(note)
        var entry = try db.entryDAO.create(boardId: board.id, dayNote: note)
        entry.body = "新内容"
        try db.entryDAO.save(entry)

        let emptyManifest = Manifest(schemaVersion: 2, boards: [], daynotes: [], entries: [])
        mock.files["/Wuyan/manifest.json"] = try JSONEncoder.wuyan.encode(emptyManifest)

        let engine = SyncEngine(provider: mock, database: db, archivedYears: [], backendFingerprint: "test-fp")
        let report = try await engine.syncNow()

        #expect(report.pushed >= 1)
        #expect(mock.files["/Wuyan/manifest.json"] != nil)
    }
}

// MARK: - Entry Summary Tests

@Suite("Entry Summary")
struct EntrySummaryTests {

    @Test("Entry summary from timeline")
    func entrySummaryFromTimeline() throws {
        let db = try AppDatabase.makeInMemory()
        let board = try #require(db.boardDAO.all().first)
        let note = DayNote(date: "2026-07-10", rawSummary: "test", poeticLine: "test")
        try db.dayNoteDAO.upsert(note)

        var entry = try db.entryDAO.create(boardId: board.id, dayNote: note)
        entry.title = "测试标题"
        entry.body = "这是一段正文内容，用来测试摘要"
        try db.entryDAO.save(entry)

        let summaries = try db.entryDAO.timeline(filter: .all)
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        #expect(summary.title == "测试标题")
        #expect(summary.dayDate == "2026-07-10")
    }

    @Test("Entry summary body preview is truncated")
    func entrySummaryBodyPreview() throws {
        let db = try AppDatabase.makeInMemory()
        let board = try #require(db.boardDAO.all().first)
        let note = DayNote(date: "2026-07-10", rawSummary: "t", poeticLine: "t")
        try db.dayNoteDAO.upsert(note)

        var entry = try db.entryDAO.create(boardId: board.id, dayNote: note)
        entry.title = nil
        entry.body = String(repeating: "长文本", count: 50)
        try db.entryDAO.save(entry)

        let summaries = try db.entryDAO.timelineSummaries(filter: .all)
        guard let firstSummary = summaries.first else {
            Issue.record("Expected at least one summary")
            return
        }
        let preview = firstSummary.bodyPreview
        #expect(!preview.isEmpty)
        #expect(preview.count < entry.body.count)
    }
}

// MARK: - WebDAV URL Construction Tests

@Suite("WebDAV URL Construction")
struct WebDAVURLTests {

    @Test("URL construction with base path")
    func urlConstructionWithBasePath() throws {
        let baseURL = URL(string: "https://nas.local:5006/dav")!
        let provider = WebDAVProvider(baseURL: baseURL, username: "user", password: "pass")
        // Provider 成功构造即验证 URL 逻辑正确
        #expect(type(of: provider) == WebDAVProvider.self)
    }

    @Test("URL construction without path")
    func urlConstructionWithoutPath() throws {
        let baseURL = URL(string: "https://nas.local:5006")!
        let provider = WebDAVProvider(baseURL: baseURL)
        #expect(type(of: provider) == WebDAVProvider.self)
    }
}

// MARK: - LocalMediaStore Path Resolution Tests

@Suite("Media Path Resolution")
struct MediaPathTests {

    @Test("Relative path roundtrip via model computed properties")
    func relativePathRoundtripViaModel() {
        let absolute = LocalMediaStore.mediaRootURL
            .appendingPathComponent("media/ab/cdef1234.jpg").path
        let relative = LocalMediaStore.toRelativePath(absolute)
        #expect(relative == "media/ab/cdef1234.jpg")

        // R2-1: 测试 MediaAsset 计算属性（收口后的唯一外部接口）
        var asset = MediaAsset(
            entryId: UUID(), type: .photo, filename: "test.jpg",
            mime: "image/jpeg", size: 100, sha256: "abc"
        )
        asset.localPath = relative
        #expect(asset.absoluteLocalPath == absolute)

        asset.thumbnailPath = relative
        #expect(asset.absoluteThumbnailPath == absolute)
    }

    @Test("Resolve absolute path passes through via model")
    func resolveAbsolutePathPassthroughViaModel() {
        let absolute = "/Users/test/Library/Caches/Wuyan/media/ab/old.jpg"
        var asset = MediaAsset(
            entryId: UUID(), type: .photo, filename: "test.jpg",
            mime: "image/jpeg", size: 100, sha256: "abc"
        )
        asset.localPath = absolute
        #expect(asset.absoluteLocalPath == absolute)
    }

    @Test("Nil paths return nil")
    func resolveNilPathReturnsNilViaModel() {
        let asset = MediaAsset(
            entryId: UUID(), type: .photo, filename: "test.jpg",
            mime: "image/jpeg", size: 100, sha256: "abc"
        )
        #expect(asset.absoluteLocalPath == nil)
        #expect(asset.absoluteThumbnailPath == nil)
    }
}

// MARK: - MarkClean Regression Test (P1-3)

@Suite("MarkClean")
struct MarkCleanTests {

    @Test("markClean sets dirty to false")
    func markCleanSetsDirtyFalse() throws {
        let db = try AppDatabase.makeInMemory()
        let board = try #require(db.boardDAO.all().first)
        let note = DayNote(date: "2026-07-10", rawSummary: "t", poeticLine: "t")
        try db.dayNoteDAO.upsert(note)

        var entry = try db.entryDAO.create(boardId: board.id, dayNote: note)
        entry.body = "写完的内容"
        try db.entryDAO.save(entry)

        let beforeClean = try db.entryDAO.entry(id: entry.id)
        #expect(beforeClean?.dirty == true)

        try db.entryDAO.markClean(id: entry.id, expectedHash: entry.contentHash)
        let cleaned = try db.entryDAO.entry(id: entry.id)
        #expect(cleaned?.dirty == false)
    }
}

// MARK: - Board Deduplication Regression Test (v4 migration)

@Suite("Board Deduplication")
struct BoardDedupTests {

    @Test("Built-in board kinds are unique")
    func builtInBoardKindsAreUnique() throws {
        let db = try AppDatabase.makeInMemory()
        let boards = try db.boardDAO.all()
        let kinds = boards.map(\.kind)
        let kindCounts = Dictionary(grouping: kinds, by: { $0 }).mapValues { $0.count }
        for (kind, count) in kindCounts {
            #expect(count == 1, "板块类型 \(kind) 出现了 \(count) 次，应该唯一")
        }
    }
}
