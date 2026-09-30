import Testing
import Foundation
import CryptoKit
@testable import Wuyan

// MARK: - R4-01：缺失对象巡检的缩略图补传回归
//
// 对照《晤言第四次验收报告》(2026-09-27) R4-01：巡检原先先查原图远端是否存在，
// 原图存在即 continue，缩略图检查只能在「原图也缺失且补传成功」的分支执行，
// 导致只缺缩略图时永远补不回。修复后原图与缩略图分开检查；本地原件缺失
// （懒下载设备只缓存了缩略图）也不再阻断缩略图处理。

@Suite("R4-01: Missing-object audit repairs thumbnails independently")
struct R401ThumbnailAuditTests {

    private struct Fixture {
        let asset: MediaAsset
        let original: Data
        let thumbnail: Data

        var sha256: String {
            SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        }
        var mediaPath: String {
            SyncPaths.mediaPath(sha256: sha256, filename: asset.filename)
        }
        var encryptedMediaPath: String {
            SyncPaths.encryptedMediaPath(sha256: sha256, filename: asset.filename)
        }
        var thumbnailPath: String {
            SyncPaths.thumbnailPath(sha256: sha256)
        }
        var originalURL: URL {
            LocalMediaStore.mediaRootURL.appendingPathComponent(asset.localPath ?? "")
        }
    }

    /// 夹具：日记 + 一份媒体资产，本地原图与缩略图都写在隔离媒体根内。
    private func seededFixture(_ db: AppDatabase, body: String) throws -> Fixture {
        let board = try #require(try db.boardDAO.all().first)
        var entry = Entry(boardId: board.id, dayDate: "2026-09-26", body: body, isDraft: false)
        try db.entryDAO.save(entry)

        let original = Data("synthetic r401 original \(body)".utf8)
        let thumbnail = Data("synthetic r401 thumbnail \(body)".utf8)
        let bucket = LocalMediaStore.mediaRootURL.appendingPathComponent("media/r4", isDirectory: true)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        try original.write(to: bucket.appendingPathComponent("r401-original.jpg"))
        try thumbnail.write(to: bucket.appendingPathComponent("r401-thumb.jpg"))

        let asset = MediaAsset(
            entryId: entry.id, type: .photo, filename: "r401-original.jpg",
            mime: "image/jpeg", size: Int64(original.count),
            sha256: SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined(),
            thumbnailPath: "media/r4/r401-thumb.jpg",
            localPath: "media/r4/r401-original.jpg"
        )
        try db.mediaAssetDAO.save(asset)
        entry.mediaIds = [asset.id]
        try db.entryDAO.save(entry)
        return Fixture(asset: asset, original: original, thumbnail: thumbnail)
    }

    private func decryptPayload(_ data: Data, crypto: SyncCrypto) throws -> Data {
        let payload = try JSONDecoder.wuyan.decode(EncryptedPayload.self, from: data)
        let ciphertext = try #require(Data(base64Encoded: payload.ciphertextBase64))
        return try crypto.box.open(ciphertext, key: try crypto.dekForKeyId(payload.keyId))
    }

    /// 主复现（明文）：远端原图完好、仅缩略图丢失，巡检必须单独补回缩略图；
    /// 对象齐全时巡检必须是零操作，不得每轮重复上传。
    @Test("Thumbnail-only loss is repaired in plaintext mode")
    func thumbnailOnlyLossPlaintext() async throws {
        try await TestIsolation.withIsolatedDefaults { _ in
            let db = try AppDatabase.makeInMemory()
            let remote = MockRemoteStorageProvider()
            let fixture = try seededFixture(db, body: "thumb-only")
            let engine = SyncEngine(
                provider: remote, database: db,
                backendFingerprint: "r401-plain", missingObjectAuditInterval: 0
            )
            _ = try await engine.syncNow()
            #expect(remote.files[fixture.mediaPath] == fixture.original, "初次同步后原图必须已上传")
            #expect(remote.files[fixture.thumbnailPath] == fixture.thumbnail, "初次同步后缩略图必须已上传")

            // 对象齐全：巡检一轮不得产生任何补传。
            let idle = try await engine.syncNow()
            #expect(idle.repaired == 0, "对象齐全时巡检必须是零操作")

            // 仅缩略图远端丢失：下一轮巡检必须单独补回，且只补这一个对象。
            remote.files[fixture.thumbnailPath] = nil
            let report = try await engine.syncNow()
            #expect(remote.files[fixture.mediaPath] == fixture.original, "原图对象不受影响")
            #expect(remote.files[fixture.thumbnailPath] == fixture.thumbnail, "仅缩略图缺失时巡检必须补回缩略图")
            #expect(report.repaired == 1, "只应补传缩略图一个对象")
        }
    }

    /// 加密模式：补回的缩略图必须是加密负载，解开内容与本地一致；
    /// 原图密文对象不受影响。
    @Test("Thumbnail-only loss is repaired in encrypted mode")
    func thumbnailOnlyLossEncrypted() async throws {
        try await TestIsolation.withIsolatedDefaults { _ in
            let db = try AppDatabase.makeInMemory()
            let remote = MockRemoteStorageProvider()
            let fixture = try seededFixture(db, body: "thumb-only-enc")
            let crypto = SyncCrypto(passphrase: "r401-passphrase", persistenceKey: "r401.pending.enc")
            let engine = SyncEngine(
                provider: remote, database: db, crypto: crypto,
                backendFingerprint: "r401-enc", missingObjectAuditInterval: 0
            )
            _ = try await engine.syncNow()
            #expect(remote.files[fixture.encryptedMediaPath] != nil, "初次同步后原图密文必须已上传")
            #expect(
                try decryptPayload(try #require(remote.files[fixture.thumbnailPath]), crypto: crypto)
                    == fixture.thumbnail,
                "初次上传的缩略图必须是加密负载"
            )

            remote.files[fixture.thumbnailPath] = nil
            let report = try await engine.syncNow()
            #expect(
                try decryptPayload(try #require(remote.files[fixture.thumbnailPath]), crypto: crypto)
                    == fixture.thumbnail,
                "加密模式下仅缩略图缺失也必须补回，且仍为加密负载"
            )
            #expect(report.repaired == 1)
            #expect(
                try decryptPayload(try #require(remote.files[fixture.encryptedMediaPath]), crypto: crypto)
                    == fixture.original,
                "原图密文对象不受影响"
            )
        }
    }

    /// 对照场景：原图与缩略图同时缺失仍要一起补回（修复不得破坏原行为）。
    @Test("Original and thumbnail missing together are still repaired")
    func bothMissingRepairedTogether() async throws {
        try await TestIsolation.withIsolatedDefaults { _ in
            let db = try AppDatabase.makeInMemory()
            let remote = MockRemoteStorageProvider()
            let fixture = try seededFixture(db, body: "both-missing")
            let engine = SyncEngine(
                provider: remote, database: db,
                backendFingerprint: "r401-both", missingObjectAuditInterval: 0
            )
            _ = try await engine.syncNow()

            remote.files[fixture.mediaPath] = nil
            remote.files[fixture.thumbnailPath] = nil
            let report = try await engine.syncNow()
            #expect(remote.files[fixture.mediaPath] == fixture.original, "原图必须补回")
            #expect(remote.files[fixture.thumbnailPath] == fixture.thumbnail, "缩略图必须一起补回")
            #expect(report.repaired == 2)
        }
    }

    /// 本地只缓存缩略图（原件懒下载后被清理）：不得因本地原件缺失而报错或
    /// 跳过缩略图，远端缩略图仍须从本地缩略图补回。
    @Test("Thumbnail-only local cache still repairs remote thumbnail")
    func thumbnailOnlyLocalCache() async throws {
        try await TestIsolation.withIsolatedDefaults { _ in
            let db = try AppDatabase.makeInMemory()
            let remote = MockRemoteStorageProvider()
            let fixture = try seededFixture(db, body: "thumb-cache")
            let engine = SyncEngine(
                provider: remote, database: db,
                backendFingerprint: "r401-cache", missingObjectAuditInterval: 0
            )
            _ = try await engine.syncNow()

            // 模拟原件清理：删除本地原图文件，资产记录与本地缩略图保留。
            try FileManager.default.removeItem(at: fixture.originalURL)
            remote.files[fixture.thumbnailPath] = nil
            let report = try await engine.syncNow()
            #expect(remote.files[fixture.mediaPath] == fixture.original, "远端原图仍应完好")
            #expect(remote.files[fixture.thumbnailPath] == fixture.thumbnail, "本地只有缩略图时也必须补回远端缩略图")
            #expect(report.repaired == 1)
        }
    }
}
