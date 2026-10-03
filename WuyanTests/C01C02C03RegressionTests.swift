import Testing
import Foundation
import CryptoKit
import GRDB
@testable import Wuyan

// MARK: - C01/C02/C03 第三次验收整改回归
//
// 对照《晤言第三次整改验收报告》(2026-09-25)：
// - C01：延迟 GC 到期后不得删除刚被其它设备重新引用的正文；对象身份不复用后
//   「复核索引→删除」的竞争窗口被协议性关闭；被误删的当前对象须能被巡检自动补回。
// - C02：加密迁移中断后，另一台空库设备必须能凭远端索引里的迁移标记接续补完，
//   不能留下明文媒体原件。
// - C03：AppState 构造（真实迁移链路 + AI provider 链路）必须在统一隔离容器内
//   运行，绝不触碰真实 Caches、真实媒体库或生产 Keychain。

private let regressionGrace: TimeInterval = 48 * 3600

private func makeEngine(
    _ db: AppDatabase,
    _ remote: MockRemoteStorageProvider,
    fingerprint: String,
    crypto: SyncCrypto? = nil,
    orphanGrace: TimeInterval = regressionGrace,
    auditInterval: TimeInterval = 24 * 3600
) -> SyncEngine {
    SyncEngine(
        provider: remote,
        database: db,
        crypto: crypto,
        backendFingerprint: fingerprint,
        orphanGraceInterval: orphanGrace,
        missingObjectAuditInterval: auditInterval
    )
}

private func seededEntry(_ db: AppDatabase, body: String = "baseline", day: String = "2026-09-20") throws -> Entry {
    let board = try #require(try db.boardDAO.all().first)
    let entry = Entry(boardId: board.id, dayDate: day, body: body, isDraft: false)
    try db.entryDAO.save(entry)
    let saved = try #require(try db.entryDAO.entry(id: entry.id))
    return saved
}

private func remoteManifest(_ remote: MockRemoteStorageProvider) throws -> Manifest {
    let data = try #require(remote.files["/Wuyan/manifest.json"])
    return try JSONDecoder.wuyan.decode(Manifest.self, from: data)
}

private func shaHex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Suite("C01: Delayed GC object identity")
struct C01RegressionTests {

    /// C01 主复现：孤儿宽限期（生产默认 48h）已过，另一设备恰在 GC 删除前
    /// 「拉取新版本→恢复旧内容→推送」。恢复写入必须落在全新路径，
    /// GC 删除的旧路径不再被任何索引引用，当前正文完好。
    @Test("Aged delayed GC preserves concurrently restored object")
    func agedGCPreservesRestoredObject() async throws {
        let dbA = try AppDatabase.makeInMemory()
        let remote = MockRemoteStorageProvider()
        let fingerprint = "c01-aged"
        var original = try seededEntry(dbA)
        _ = try await makeEngine(dbA, remote, fingerprint: fingerprint).syncNow()
        let v0Path = try remoteManifest(remote).entries[0].path
        let v0 = original

        original.body = "version B"
        try dbA.entryDAO.save(original)
        _ = try await makeEngine(dbA, remote, fingerprint: fingerprint).syncNow()
        // 生产默认 48h 宽限期不变，仅把登记时间拨回 49h 前模拟时间经过。
        try await dbA.writer.write { db in
            try db.execute(
                sql: "UPDATE sync_orphan SET firstSeenAt = ? WHERE backend = ?",
                arguments: [Date().addingTimeInterval(-49 * 3600), fingerprint]
            )
        }

        let dbB = try AppDatabase.makeInMemory()
        var hookRan = false
        remote.beforeDelete = {
            hookRan = true
            _ = try await makeEngine(dbB, remote, fingerprint: "c01-aged-b").syncNow()
            let revert = v0
            try dbB.entryDAO.save(revert)
            _ = try await makeEngine(dbB, remote, fingerprint: "c01-aged-b").syncNow()
        }
        _ = try await makeEngine(dbA, remote, fingerprint: fingerprint).syncNow()

        #expect(hookRan, "交错动作必须在删除回调中真实发生")
        let item = try #require(try remoteManifest(remote).entries.first { $0.id == v0.id })
        // DB 的 Date 往返是毫秒精度，恢复重存的版本哈希不必与原 V0 相同；
        // 安全性在于：索引指向恢复后的正文、对象真实存在、路径不复用旧路径。
        #expect(item.path != v0Path, "恢复推送必须写入不复用的新对象路径")
        #expect(remote.files[item.path] != nil, "当前正文对象必须存在")
        #expect(remote.files[v0Path] == nil, "被 GC 的旧路径不应再被引用")
        let envelope = try JSONDecoder.wuyan.decode(
            EntryEnvelope.self, from: try #require(remote.files[item.path])
        )
        #expect(envelope.entry.body == v0.body, "索引最终指向的正文必须是恢复后的内容")
        #expect(envelope.entry.contentHash == item.hash, "索引哈希与正文哈希必须一致")
    }

    /// C01b：当前对象被误删（或因后端部分丢失缺失）后，普通同步的巡检必须
    /// 用本地一致副本自动补传，不依赖用户再次编辑。
    @Test("Missing-object audit repairs current object on next sync")
    func auditRepairsMissingObject() async throws {
        let db = try AppDatabase.makeInMemory()
        let remote = MockRemoteStorageProvider()
        let fingerprint = "c01-audit"
        let entry = try seededEntry(db)
        _ = try await makeEngine(db, remote, fingerprint: fingerprint).syncNow()
        let path = try remoteManifest(remote).entries[0].path
        #expect(remote.files[path] != nil)

        remote.files[path] = nil
        let report = try await makeEngine(db, remote, fingerprint: fingerprint, auditInterval: 0).syncNow()
        #expect(remote.files[path] != nil, "巡检应补回索引引用的正文对象")
        #expect(report.repaired >= 1)
        let body = try JSONDecoder.wuyan.decode(EntryEnvelope.self, from: remote.files[path]!)
        #expect(body.entry.body == entry.body)
    }

    /// 日札没有编辑时间戳：恢复旧内容后再次推送必须使用推送时刻令牌落到新路径，
    /// 被 GC 登记的旧路径永远不会被复用（C01 的日札侧协议）。
    @Test("Restored day note pushes to never-reused path")
    func restoredDayNoteUsesFreshPath() async throws {
        let db = try AppDatabase.makeInMemory()
        let remote = MockRemoteStorageProvider()
        let fingerprint = "c01-daynote"
        _ = try seededEntry(db)
        let base = DayNote(date: "2026-09-20", rawSummary: "base", poeticLine: "base")
        try db.dayNoteDAO.upsert(base)
        _ = try await makeEngine(db, remote, fingerprint: fingerprint, orphanGrace: 0).syncNow()
        let v0Path = try remoteManifest(remote).daynotes[0].path

        var edited = base
        edited.rawSummary = "edited"
        edited.poeticLine = "edited"
        try db.dayNoteDAO.upsert(edited)
        _ = try await makeEngine(db, remote, fingerprint: fingerprint, orphanGrace: 0).syncNow()
        #expect(try remoteManifest(remote).daynotes[0].path != v0Path)

        // 恢复为与 V0 完全相同的内容再推送：必须写新路径，且宽限期 0 的 GC
        // 只清理不再被引用的旧路径。
        var restored = base
        restored.rawSummary = "base"
        restored.poeticLine = "base"
        try db.dayNoteDAO.upsert(restored)
        _ = try await makeEngine(db, remote, fingerprint: fingerprint, orphanGrace: 0).syncNow()

        let item = try remoteManifest(remote).daynotes[0]
        #expect(item.hash == Hashing.dayNoteHash(base))
        #expect(item.path != v0Path, "恢复内容不得复用旧对象路径")
        #expect(remote.files[item.path] != nil, "当前日札对象必须存在")
        #expect(remote.files[v0Path] == nil, "未被引用的旧路径应被延迟 GC 清理")
    }
}

@Suite("C02: Remote-persisted crypto migration state")
struct C02RegressionTests {

    /// C02 主复现：明文同步后开启加密，迁移在第一份媒体密文写入处 503 中断；
    /// 不让原设备重试，只让另一台空库设备（持正确口令）接续——迁移标记已在
    /// 远端索引里，接续设备必须补完媒体/缩略图迁移并清除标记，不得留下明文原件。
    @Test("Another device completes interrupted media encryption")
    func anotherDeviceCompletesMigration() async throws {
        try await TestIsolation.withIsolatedDefaults { _ in
            let dbA = try AppDatabase.makeInMemory()
            let remote = MockRemoteStorageProvider()
            let fingerprint = "c02-owner"

            // 媒体夹具放在注入的隔离媒体根内（localPath 为相对路径）。
            let mediaRoot = LocalMediaStore.mediaRootURL
            let bucket = mediaRoot.appendingPathComponent("media/ab", isDirectory: true)
            try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
            let bytes = Data("synthetic unencrypted photo".utf8)
            let fileURL = bucket.appendingPathComponent("c02-media.jpg")
            try bytes.write(to: fileURL)
            let sha = shaHex(bytes)

            var entry = try seededEntry(dbA)
            let asset = MediaAsset(
                entryId: entry.id, type: .photo, filename: "c02-media.jpg",
                mime: "image/jpeg", size: Int64(bytes.count), sha256: sha,
                localPath: "media/ab/c02-media.jpg"
            )
            try dbA.mediaAssetDAO.save(asset)
            entry.mediaIds = [asset.id]
            try dbA.entryDAO.save(entry)
            _ = try await makeEngine(dbA, remote, fingerprint: fingerprint).syncNow()

            let plainPath = SyncPaths.mediaPath(sha256: sha, filename: asset.filename)
            let encPath = SyncPaths.encryptedMediaPath(sha256: sha, filename: asset.filename)
            #expect(remote.files[plainPath] != nil)

            // 开启加密：在第一份媒体密文 PUT 处注入 503，迁移中断。
            remote.beforeMediaWrite = {
                throw RemoteStorageError.requestFailed(method: "PUT", path: encPath, statusCode: 503)
            }
            let cryptoA = SyncCrypto(passphrase: "c02-passphrase", persistenceKey: "c02.pending.a")
            do {
                _ = try await makeEngine(dbA, remote, fingerprint: fingerprint, crypto: cryptoA).syncNow()
            } catch {}
            #expect(remote.files[plainPath] != nil, "中断后明文原件尚未迁移")
            #expect(remote.files[encPath] == nil)

            // 远端索引已加密且携带迁移标记（跨设备权威状态）。
            let container = try JSONDecoder.wuyan.decode(
                ManifestContainer.self, from: try #require(remote.files["/Wuyan/manifest.json"])
            )
            #expect(container.crypto?.wrappedDekBase64 != nil)
            try cryptoA.unlock(with: try #require(container.crypto))
            let interruptedCiphertext = try #require(Data(base64Encoded: container.payloadCiphertextBase64 ?? ""))
            let payload = try cryptoA.box.open(
                interruptedCiphertext,
                key: try cryptoA.dekForKeyId(container.crypto?.keyId)
            )
            let interrupted = try JSONDecoder.wuyan.decode(Manifest.self, from: payload)
            #expect(interrupted.migration?.direction == RemoteMigrationState.encrypt)

            // 另一台空库设备接续。
            let dbB = try AppDatabase.makeInMemory()
            let cryptoB = SyncCrypto(passphrase: "c02-passphrase", persistenceKey: "c02.pending.b")
            _ = try await makeEngine(dbB, remote, fingerprint: "c02-other", crypto: cryptoB).syncNow()

            #expect(remote.files[encPath] != nil, "接续设备必须补写密文媒体")
            let encrypted = try? JSONDecoder.wuyan.decode(EncryptedPayload.self, from: remote.files[encPath]!)
            #expect(encrypted?.ciphertextBase64 != nil, "密文媒体必须是加密负载格式")
            #expect(remote.files[plainPath] == nil, "迁移完成后不得残留明文原件")

            // 完成后远端标记清除，下一轮不再迁移。
            let finalContainer = try JSONDecoder.wuyan.decode(
                ManifestContainer.self, from: try #require(remote.files["/Wuyan/manifest.json"])
            )
            try cryptoB.unlock(with: try #require(finalContainer.crypto))
            let finalCiphertext = try #require(Data(base64Encoded: finalContainer.payloadCiphertextBase64 ?? ""))
            let finalPayload = try cryptoB.box.open(
                finalCiphertext,
                key: try cryptoB.dekForKeyId(finalContainer.crypto?.keyId)
            )
            let finalManifest = try JSONDecoder.wuyan.decode(Manifest.self, from: finalPayload)
            #expect(finalManifest.migration == nil, "迁移完成后必须清除远端迁移标记")
        }
    }
}

@Suite("C03: Unified test isolation for AppState construction")
struct C03RegressionTests {
    @Test("Rescue mode does not run media migration")
    func rescueModeSkipsMigration() async throws {
        try await TestIsolation.withIsolatedDefaults { defaults in
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("wuyan-c03-rescue-\(UUID().uuidString)", isDirectory: true)
            let fakeCaches = tempRoot.appendingPathComponent("Caches", isDirectory: true)
            let fakeMediaRoot = tempRoot.appendingPathComponent("MediaRoot", isDirectory: true)
            LocalMediaStore.injectCachesSourceForTesting(fakeCaches)
            LocalMediaStore.injectMediaRootForTesting(fakeMediaRoot)
            defer {
                LocalMediaStore.injectCachesSourceForTesting(nil)
                LocalMediaStore.injectMediaRootForTesting(nil)
                try? FileManager.default.removeItem(at: tempRoot)
            }
            let oldMedia = fakeCaches.appendingPathComponent("Wuyan/media", isDirectory: true)
            try FileManager.default.createDirectory(at: oldMedia, withIntermediateDirectories: true)
            let sentinel = oldMedia.appendingPathComponent("sentinel.jpg")
            try Data("sentinel".utf8).write(to: sentinel)

            let versionBefore = AppMigrationRunner.currentVersion
            let db = try AppDatabase.makeInMemory()
            await MainActor.run {
                _ = AppState(database: db, rescueMode: true)
            }

            #expect(FileManager.default.fileExists(atPath: sentinel.path))
            #expect(AppMigrationRunner.currentVersion == versionBefore)
            #expect(!defaults.bool(forKey: "wuyan.media.migratedFromCaches"))
        }
    }


    /// AppState 构造触发的完整链路（迁移源目录、媒体根、Keychain、AI provider）
    /// 全部走注入点；合成哨兵只会在临时目录之间移动，真实 Caches 不可达。
    @Test("AppState construction moves sentinel only inside injected containers")
    @MainActor
    func appStateConstructionIsIsolated() throws {
        let realCaches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        try TestIsolation.withIsolatedDefaults { defaults in
            // 容器默认注入的迁移源就不是真实 Caches。
            let effectiveSource = LocalMediaStore.currentCachesRoot(fileManager: .default)
            #expect(effectiveSource != realCaches, "隔离容器内的迁移源不得指向真实用户 Caches")

            // 用已知路径重新注入，放哨兵验证迁移只搬合成夹具。
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("wuyan-c03-\(UUID().uuidString)", isDirectory: true)
            let fakeCaches = tempRoot.appendingPathComponent("Caches", isDirectory: true)
            let fakeMediaRoot = tempRoot.appendingPathComponent("MediaRoot", isDirectory: true)
            LocalMediaStore.injectCachesSourceForTesting(fakeCaches)
            LocalMediaStore.injectMediaRootForTesting(fakeMediaRoot)
            defer {
                LocalMediaStore.injectCachesSourceForTesting(nil)
                LocalMediaStore.injectMediaRootForTesting(nil)
            }
            let oldMedia = fakeCaches.appendingPathComponent("Wuyan/media", isDirectory: true)
            try FileManager.default.createDirectory(at: oldMedia, withIntermediateDirectories: true)
            let sentinel = oldMedia.appendingPathComponent("sentinel.jpg")
            try Data("sentinel".utf8).write(to: sentinel)

            // AI provider 工厂被短路：默认智谱分支不再读生产 Keychain。
            #expect(ProviderFactory.makeAIProvider() == nil)

            let db = try AppDatabase.makeInMemory()
            _ = AppState(database: db)

            let newLocation = fakeMediaRoot.appendingPathComponent("media/sentinel.jpg")
            #expect(!FileManager.default.fileExists(atPath: sentinel.path), "哨兵应已被迁出旧目录")
            #expect(FileManager.default.fileExists(atPath: newLocation.path), "哨兵应落在注入的媒体根内")
            #expect(
                defaults.bool(forKey: "wuyan.media.migratedFromCaches"),
                "迁移完成标记必须写在隔离 defaults 中"
            )
            try? FileManager.default.removeItem(at: tempRoot)
        }
        // 容器结束后注入点恢复生产行为（真实 Caches）。
        #expect(LocalMediaStore.currentCachesRoot(fileManager: .default) == realCaches)
    }

    /// 普通测试容器内 SecureSettings 只接触测试 Keychain：写入读回全程隔离，
    /// 生产凭据域零读写。
    @Test("Unified container routes SecureSettings to test keychain")
    func unifiedContainerUsesTestKeychain() throws {
        try TestIsolation.withIsolatedDefaults { _ in
            let key = SecureSettingKey.zhipuAPIKey
            let value = "isolated-\(UUID().uuidString.prefix(8))"
            #expect(SecureSettings.save(value, for: key))
            #expect(SecureSettings.load(key) == value)
            SecureSettings.save("", for: key)
        }
    }
}
