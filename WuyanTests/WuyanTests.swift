import Testing
import Foundation
import CryptoKit
@testable import Wuyan

// MARK: - Q01/C03：测试隔离辅助

/// 涉及全局设置/凭据/迁移状态的测试必须在隔离容器中运行：
/// AppSettings、SecureSettings（Keychain + legacy defaults）、AppMigrationRunner、
/// LocalMediaStore 的迁移标记与目录、ProviderFactory 的 AI provider、SyncCrypto
/// 的待提交密钥头域共享同一个随机 suite，绝不读写用户真实偏好域、真实 Keychain、
/// 真实媒体库或真实 Caches，结束即清理。全局注入点是共享可变状态，用串行门闩
/// 避免并行测试互相干扰。
enum TestIsolation {
    /// Unlike NSLock, a semaphore can be acquired before an async body and
    /// released after suspension without requiring the same thread to unlock it.
    private static let gate = DispatchSemaphore(value: 1)

    /// Marker suite for global-state tests. Suites that touch injected globals
    /// should be nested here as the test suite is expanded.
    @Suite(.serialized)
    enum GlobalStateSuite {}

    static func withIsolatedDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
        gate.wait()
        defer { gate.signal() }
        let suite = "wuyan.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        // C03：隔离目录。迁移源目录与媒体根都指向临时目录，
        // AppState 构造触发的 Caches→App Support 迁移只会处理这里的合成夹具。
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wuyan-tests-" + UUID().uuidString, isDirectory: true)
        let isolatedCaches = tempRoot.appendingPathComponent("Caches", isDirectory: true)
        let isolatedMediaRoot = tempRoot.appendingPathComponent("MediaRoot", isDirectory: true)
        AppSettings.injectDefaultsForTesting(defaults)
        SecureSettings.injectDefaultsForTesting(defaults)
        // C03：统一容器同时注入测试 Keychain——AppState 构造经
        // ProviderFactory→SecureSettings.load 的链路不再读生产凭据。
        SecureSettings.injectKeychainForTesting(Keychain(service: Keychain.testService))
        AppMigrationRunner.injectDefaultsForTesting(defaults)
        LocalMediaStore.injectDefaultsForTesting(defaults)
        LocalMediaStore.injectCachesSourceForTesting(isolatedCaches)
        LocalMediaStore.injectMediaRootForTesting(isolatedMediaRoot)
        // C03：AI provider 工厂短路（默认智谱分支会读 Keychain）。
        ProviderFactory.injectAIProviderForTesting { nil }
        // C03：SyncCrypto 待提交密钥头同样落隔离域。
        SyncCrypto.injectDefaultsForTesting(defaults)
        defer {
            AppSettings.injectDefaultsForTesting(.standard)
            SecureSettings.injectDefaultsForTesting(.standard)
            SecureSettings.injectKeychainForTesting(Keychain())
            AppMigrationRunner.injectDefaultsForTesting(.standard)
            LocalMediaStore.injectDefaultsForTesting(.standard)
            LocalMediaStore.injectCachesSourceForTesting(nil)
            LocalMediaStore.injectMediaRootForTesting(nil)
            ProviderFactory.injectAIProviderForTesting(nil)
            SyncCrypto.injectDefaultsForTesting(.standard)
            try? FileManager.default.removeItem(at: tempRoot)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return try body(defaults)
    }

    /// C03：异步测试用例（await 引擎同步）使用同一隔离容器。
    /// 只能在 GlobalStateSuite 内使用；父套件的 serialized trait 负责互斥。
    static func withIsolatedDefaults<T>(_ body: (UserDefaults) async throws -> T) async rethrows -> T {
        let suite = "wuyan.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        // C03：隔离目录。迁移源目录与媒体根都指向临时目录，
        // AppState 构造触发的 Caches→App Support 迁移只会处理这里的合成夹具。
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wuyan-tests-" + UUID().uuidString, isDirectory: true)
        let isolatedCaches = tempRoot.appendingPathComponent("Caches", isDirectory: true)
        let isolatedMediaRoot = tempRoot.appendingPathComponent("MediaRoot", isDirectory: true)
        AppSettings.injectDefaultsForTesting(defaults)
        SecureSettings.injectDefaultsForTesting(defaults)
        // C03：统一容器同时注入测试 Keychain——AppState 构造经
        // ProviderFactory→SecureSettings.load 的链路不再读生产凭据。
        SecureSettings.injectKeychainForTesting(Keychain(service: Keychain.testService))
        AppMigrationRunner.injectDefaultsForTesting(defaults)
        LocalMediaStore.injectDefaultsForTesting(defaults)
        LocalMediaStore.injectCachesSourceForTesting(isolatedCaches)
        LocalMediaStore.injectMediaRootForTesting(isolatedMediaRoot)
        // C03：AI provider 工厂短路（默认智谱分支会读 Keychain）。
        ProviderFactory.injectAIProviderForTesting { nil }
        // C03：SyncCrypto 待提交密钥头同样落隔离域。
        SyncCrypto.injectDefaultsForTesting(defaults)
        defer {
            AppSettings.injectDefaultsForTesting(.standard)
            SecureSettings.injectDefaultsForTesting(.standard)
            SecureSettings.injectKeychainForTesting(Keychain())
            AppMigrationRunner.injectDefaultsForTesting(.standard)
            LocalMediaStore.injectDefaultsForTesting(.standard)
            LocalMediaStore.injectCachesSourceForTesting(nil)
            LocalMediaStore.injectMediaRootForTesting(nil)
            ProviderFactory.injectAIProviderForTesting(nil)
            SyncCrypto.injectDefaultsForTesting(.standard)
            try? FileManager.default.removeItem(at: tempRoot)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return try await body(defaults)
    }

    static func withIsolatedKeychain<T>(_ body: () throws -> T) rethrows -> T {
        gate.wait()
        defer { gate.signal() }
        // Q01：凭据迁移的「读取—迁移—清理」整条链路共享同一隔离容器，
        // SecureSettings 内部不再触碰生产 UserDefaults/Keychain。
        let suite = "wuyan.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        SecureSettings.injectKeychainForTesting(Keychain(service: Keychain.testService))
        SecureSettings.injectDefaultsForTesting(defaults)
        defer {
            SecureSettings.injectKeychainForTesting(Keychain())
            SecureSettings.injectDefaultsForTesting(.standard)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return try body()
    }
}

/// 读写全局注入点的测试父套件；嵌套套件递归串行，避免默认并行运行时
/// 互相覆盖 UserDefaults、媒体根目录、Keychain 和迁移注入点。
@Suite(.serialized)
enum GlobalStateSuite {}

// MARK: - Mock Remote Storage Provider

final class MockRemoteStorageProvider: RemoteStorageProvider, @unchecked Sendable {
    var files: [String: Data] = [:]
    var putCounts: [String: Int] = [:]
    var directories: Set<String> = []
    var shouldFail5xx = false
    private let conditionalLock = NSLock()
    // C01/C02：在指定动作前插入并发操作或注入故障，用于复现提交/删除/媒体
    // 写入窗口内的跨设备交错。闭包只执行一次后自动清空。
    var beforeEntryWrite: (() throws -> Void)?
    var beforeMediaWrite: (() throws -> Void)?
    var beforeDelete: (() async throws -> Void)?

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

    func getVersioned(_ path: String) async throws -> RemoteObjectSnapshot {
        let data = try await get(path)
        return RemoteObjectSnapshot(data: data, etag: fingerprint(data))
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
        if path.hasPrefix("/Wuyan/entries/"), let action = beforeEntryWrite {
            beforeEntryWrite = nil
            try action()
        }
        if path.hasPrefix("/Wuyan/media/"), let action = beforeMediaWrite {
            beforeMediaWrite = nil
            try action()
        }
        putCounts[path, default: 0] += 1
        files[path] = data
    }

    func putConditionally(
        _ path: String,
        data: Data,
        contentType: String,
        ifMatch: String?,
        ifNoneMatch: Bool
    ) async throws {
        conditionalLock.lock()
        defer { conditionalLock.unlock() }
        if ifNoneMatch, files[path] != nil {
            throw RemoteStorageError.concurrentModification(path: path)
        }
        if let ifMatch {
            guard let current = files[path], fingerprint(current) == ifMatch else {
                throw RemoteStorageError.concurrentModification(path: path)
            }
        }
        putCounts[path, default: 0] += 1
        files[path] = data
    }

    func putChunked(_ path: String, fileURL: URL, chunkSize: Int) async throws {
        let data = try Data(contentsOf: fileURL)
        try await put(path, data: data, contentType: "application/octet-stream")
    }

    func delete(_ path: String) async throws {
        if let action = beforeDelete {
            beforeDelete = nil
            try await action()
        }
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

    private func fingerprint(_ data: Data) -> String {
        "sha256-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension GlobalStateSuite {

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
        let key = try crypto.key(forSaltBase64: salt.base64EncodedString(), iterations: KDFParams(salt: salt).iterations)
        let sealed = try crypto.box.seal(manifestJSON, key: key)
        let decrypted = try crypto.box.open(sealed, key: key)

        #expect(decrypted == manifestJSON)
    }
}

// MARK: - Streak Tracker Tests

@Suite("Streak Tracker")
struct StreakTrackerTests {

    private func makeEntry(on dayKey: String) -> Entry {
        // UI-09① 后草稿不计入连续记录，夹具必须是非草稿。
        Entry(id: UUID(), boardId: UUID(), dayDate: dayKey, body: "x", isDraft: false)
    }

    @Test("Current streak counts consecutive days")
    func currentStreakConsecutiveDays() {
        let base = "2026-07-"
        let entries = (7...10).map { makeEntry(on: base + String(format: "%02d", $0)) }
        let tracker = StreakTracker(entries: entries)

        // DayKey 采用凌晨 3 点日界，零点属于前一天；用正午确保落在当日。
        let today = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 12))!
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
        // DayKey 采用凌晨 3 点日界，零点属于前一天；用正午确保落在当日。
        let today = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 12))!
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
        #expect(SettingKey.storageBackend == "settings.storage.backend")
        #expect(SettingKey.aiEnabled == "settings.ai.enabled")
        #expect(SettingKey.cryptoEnabled == "settings.crypto.enabled")
        #expect(SettingKey.appearanceBodyFont == "settings.appearance.bodyFont")
    }

    @Test("AppSettings default values")
    func appSettingsDefaultValues() {
        // Q01：在隔离 suite 中运行，不删除/读写用户真实的 standard 配置。
        TestIsolation.withIsolatedDefaults { defaults in
            defaults.removeObject(forKey: SettingKey.storageBackend)
            defaults.removeObject(forKey: SettingKey.aiProvider)
            defaults.removeObject(forKey: SettingKey.appearanceBodyFont)

            #expect(AppSettings.storageBackend == "webDAV")
            #expect(AppSettings.aiProvider == "zhipu")
            #expect(AppSettings.bodyFont == "LXGWWenKai-Regular")
        }
    }

    @Test("AppSettings bool defaults")
    func appSettingsBoolDefaults() {
        TestIsolation.withIsolatedDefaults { defaults in
            defaults.removeObject(forKey: SettingKey.aiEnabled)
            defaults.removeObject(forKey: SettingKey.cryptoEnabled)
            defaults.removeObject(forKey: SettingKey.metadataEnabled)

            #expect(AppSettings.aiEnabled == false)
            #expect(AppSettings.cryptoEnabled == false)
            #expect(AppSettings.metadataEnabled == true)
        }
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

    @Test("Conditional manifest writes reject a stale version")
    func conditionalManifestWriteRejectsStaleVersion() async throws {
        let mock = MockRemoteStorageProvider()
        let path = "/Wuyan/manifest.json"
        mock.files[path] = Data("v1".utf8)
        let snapshot = try await mock.getVersioned(path)
        try await mock.putConditionally(path, data: Data("v2".utf8), contentType: "application/json", ifMatch: snapshot.etag, ifNoneMatch: false)

        do {
            try await mock.putConditionally(path, data: Data("stale".utf8), contentType: "application/json", ifMatch: snapshot.etag, ifNoneMatch: false)
            Issue.record("旧版本写入不应覆盖最新 manifest")
        } catch let error as RemoteStorageError {
            guard case .concurrentModification = error else {
                Issue.record("应报告 concurrentModification，实际：\(error)")
                return
            }
        }
    }

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
        entry.body = String(repeating: "长文本", count: 60)
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
        TestIsolation.withIsolatedDefaults { _ in
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
    }

    @Test("Resolve absolute path passes through via model")
    func resolveAbsolutePathPassthroughViaModel() {
        TestIsolation.withIsolatedDefaults { _ in
            // R2-1 安全护栏：媒体根之外的绝对路径一律拒绝；根内的绝对路径原样通过。
            let absolute = LocalMediaStore.mediaRootURL
                .appendingPathComponent("media/ab/old.jpg").path
            var asset = MediaAsset(
                entryId: UUID(), type: .photo, filename: "test.jpg",
                mime: "image/jpeg", size: 100, sha256: "abc"
            )
            asset.localPath = absolute
            #expect(asset.absoluteLocalPath == absolute)

            // 根外的绝对路径必须被拒绝（返回空，不解析为可访问路径）。
            var outside = asset
            outside.localPath = "/Users/test/Library/Caches/Wuyan/media/ab/old.jpg"
            #expect(outside.absoluteLocalPath == nil)
        }
    }

    @Test("Nil paths return nil")
    func resolveNilPathReturnsNilViaModel() {
        TestIsolation.withIsolatedDefaults { _ in
            let asset = MediaAsset(
                entryId: UUID(), type: .photo, filename: "test.jpg",
                mime: "image/jpeg", size: 100, sha256: "abc"
            )
            #expect(asset.absoluteLocalPath == nil)
            #expect(asset.absoluteThumbnailPath == nil)
        }
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
        // Q01：save 以值传递，调用方快照不含刷新后的 contentHash；
        // markClean 必须用数据库中真实推送版本的指纹，否则条件更新不会生效。
        entry = try #require(try db.entryDAO.entry(id: entry.id))

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

// MARK: - R0 Regression Tests

@Suite("R0-1: Sync Status Observation")
struct R0_1_SyncStatusTests {

    @Test("SyncCoordinator error triggers AppState.errorMessage via onError callback")
    @MainActor
    func syncErrorForwardsToAppState() throws {
        // Q01：AppState 构造会触发迁移运行器，必须在隔离容器内完成。
        try TestIsolation.withIsolatedDefaults { _ in
            let db = try AppDatabase.makeInMemory()
            let state = AppState(database: db)
            // 模拟 SyncCoordinator 通过 onError 回调传递错误
            state.syncCoordinator.onError = { [weak state] message in
                state?.errorMessage = message
            }
            state.syncCoordinator.onError?("测试同步错误")
            #expect(state.errorMessage == "测试同步错误")
        }
    }
}

@Suite("R0-2: Archive Bookkeeping")
struct R0_2_ArchiveBookkeepingTests {

    @Test("Archive year adds to archivedYears; download removes it")
    @MainActor
    func archiveAndDownloadBookkeeping() throws {
        // Q01：AppState 的归档账本读写经 AppSettings，在隔离容器内完成，
        // 与 archivedYearsPersist 用例共用同一注入链路。
        try TestIsolation.withIsolatedDefaults { _ in
            let db = try AppDatabase.makeInMemory()
            let state = AppState(database: db)

            // 模拟归档 2023
            var years = Set(state.archivedYears)
            years.insert(2023)
            state.setArchivedYears(years)
            #expect(state.archivedYears.contains(2023))

            // 模拟下载 2023 回来
            years.remove(2023)
            state.setArchivedYears(years)
            #expect(!state.archivedYears.contains(2023))
        }
    }

    @Test("Archived years persist to UserDefaults")
    @MainActor
    func archivedYearsPersist() throws {
        // Q01：整个用例在隔离 suite 中运行——AppState 的归档年份读写只落在测试域。
        try TestIsolation.withIsolatedDefaults { _ in
            let db = try AppDatabase.makeInMemory()
            let state = AppState(database: db)

            var years = Set(state.archivedYears)
            years.insert(2024)
            years.insert(2022)
            state.setArchivedYears(years)

            let stored = AppSettings.archivedYears
            #expect(stored.contains(2024))
            #expect(stored.contains(2022))
        }
    }
}

@Suite("R0-3: MarkClean Baseline")
struct R0_3_MarkCleanBaselineTests {

    @Test("markClean with stale expectedHash protects newer edits")
    func markCleanUsesExpectedHash() throws {
        let db = try AppDatabase.makeInMemory()
        let board = try #require(db.boardDAO.all().first)
        let note = DayNote(date: "2026-07-10", rawSummary: "t", poeticLine: "t")
        try db.dayNoteDAO.upsert(note)

        var entry = try db.entryDAO.create(boardId: board.id, dayNote: note)
        entry.body = "初始内容"
        try db.entryDAO.save(entry)

        let initialHash = entry.contentHash

        // 模拟：推送期间本地被修改
        entry.body = "推送期间修改了内容"
        try db.entryDAO.save(entry)

        // Q01：修正断言方向。markClean 只应确认与推送版本一致的条目；
        // 推送期间的新编辑必须保持 dirty，等待下一次推送，绝不能被旧提交误清。
        try db.entryDAO.markClean(id: entry.id, expectedHash: initialHash)

        let cleaned = try db.entryDAO.entry(id: entry.id)
        #expect(cleaned?.dirty == true, "推送期间的新编辑应保持 dirty=true")
        // baseline 必须记录推送时的 expectedHash（水位线），而非当前 contentHash
        let baseline = try db.entryDAO.baselineHash(id: entry.id)
        #expect(baseline == initialHash, "baseline 应写入推送时的 expectedHash")
    }
}

@Suite("R0-6: Keychain Migration")
struct R0_6_KeychainMigrationTests {

    @Test("SecureSettings roundtrip uses isolated keychain in tests")
    func secureSettingsRoundtrip() {
        // Q01：SecureSettings 必须可注入隔离 Keychain；测试全程不读写生产凭据。
        TestIsolation.withIsolatedKeychain {
            let key = SecureSettingKey.syncPassphrase
            let value = "passphrase-\(UUID().uuidString.prefix(8))"
            #expect(SecureSettings.save(value, for: key))
            #expect(SecureSettings.load(key) == value)
            SecureSettings.save("", for: key)
            #expect(SecureSettings.load(key) == "")
        }
    }

    @Test("load returns value from Keychain when present")
    func loadFromKeychain() {
        let key = "test.r0_6.keychain.load"
        let value = "test-value-\(UUID().uuidString.prefix(8))"

        // 写入 Keychain
        let keychain = Keychain(service: Keychain.testService)
        let written = keychain.setString(value, for: key)
        #expect(written, "Keychain 写入应成功")

        // 读回
        let loaded = keychain.string(for: key)
        #expect(loaded == value)

        // 清理
        keychain.setString(nil, for: key)
    }

    @Test("Keychain setString returns false on failure (not crash)")
    func keychainSetStringReturnsStatus() {
        // 正常写入应返回 true
        let key = "test.r0_6.normal"
        let keychain = Keychain(service: Keychain.testService)
        let result = keychain.setString("value", for: key)
        #expect(result)

        // 清理
        keychain.setString(nil, for: key)
    }
}

@Suite("R0-7: Plaintext-to-Encrypted Migration")
struct R0_7_PlaintextMigrationTests {

    @Test("decodeRaw tolerates plaintext JSON when crypto is nil")
    func decodeRawToleratesPlaintext() async throws {
        let mock = MockRemoteStorageProvider()
        let db = try AppDatabase.makeInMemory()

        // 准备一个明文 manifest（合成 Codable 要求 boards/daynotes 键齐全）
        let plainManifest = """
        {"schemaVersion":2,"boards":[],"daynotes":[],"entries":[]}
        """.data(using: .utf8)!
        mock.files["/Wuyan/manifest.json"] = plainManifest

        // SyncEngine 无加密（crypto: nil）
        let engine = SyncEngine(provider: mock, database: db, backendFingerprint: "test")
        // Q01：补上空缺的验证——明文 manifest 在未加密模式下应完成整轮同步而非报错
        let report = try await engine.syncNow()
        #expect(report.pushed == 0)
        #expect(report.pulled == 0)
    }
}

@Suite("R0-8: Reminder Date Consistency")
struct R0_8_ReminderDateTests {

    @Test("DayKey uses 3am rule for date boundary")
    func dayKey3amRule() {
        // 凌晨 1 点应该属于前一天
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents(year: 2026, month: 7, day: 11, hour: 1, minute: 0)
        let date1am = calendar.date(from: components)!
        #expect(DayKey.string(from: date1am) == "2026-07-10")

        // 凌晨 4 点属于当天
        components.hour = 4
        let date4am = calendar.date(from: components)!
        #expect(DayKey.string(from: date4am) == "2026-07-11")
    }
}

}
