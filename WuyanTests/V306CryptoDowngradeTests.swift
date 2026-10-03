import CryptoKit
import Foundation
import Testing
@testable import Wuyan

extension GlobalStateSuite {
@Suite("V3-06: Crypto downgrade protection")
struct V306CryptoDowngradeTests {
    private func seededEntry(_ db: AppDatabase) throws -> Entry {
        let board = try #require(try db.boardDAO.all().first)
        let entry = Entry(boardId: board.id, dayDate: "2026-09-30", body: "加密正文", isDraft: false)
        try db.entryDAO.save(entry)
        return try #require(try db.entryDAO.entry(id: entry.id))
    }

    private func decryptManifest(_ data: Data, with crypto: SyncCrypto) throws -> Manifest {
        let container = try JSONDecoder.wuyan.decode(ManifestContainer.self, from: data)
        try crypto.unlock(with: try #require(container.crypto))
        let payload = try #require(container.payloadCiphertextBase64)
        let ciphertext = try #require(Data(base64Encoded: payload))
        let plain = try crypto.box.open(ciphertext, key: try crypto.dekForKeyId(container.crypto?.keyId))
        return try JSONDecoder.wuyan.decode(Manifest.self, from: plain)
    }

    @Test("加密后远端对象被替换为明文时拒绝拉取")
    func plaintextObjectIsRejectedAfterEncryptionEstablished() async throws {
        try await TestIsolation.withIsolatedDefaults { _ in
            let remote = MockRemoteStorageProvider()
            let dbA = try AppDatabase.makeInMemory()
            let entry = try seededEntry(dbA)
            _ = try await SyncEngine(provider: remote, database: dbA, backendFingerprint: "v306-object").syncNow()

            let crypto = SyncCrypto(passphrase: "v306-pass", persistenceKey: "v306-object.pending")
            _ = try await SyncEngine(provider: remote, database: dbA, crypto: crypto, backendFingerprint: "v306-object").syncNow()
            let manifest = try decryptManifest(try #require(remote.files[SyncPaths.manifest]), with: crypto)
            let item = try #require(manifest.entries.first { $0.id == entry.id })
            let board = try #require(try dbA.boardDAO.board(id: entry.boardId))
            let plainEnvelope = try JSONEncoder.wuyan.encode(EntryEnvelope(entry: entry, board: board, dayNote: nil))
            remote.files[item.path] = plainEnvelope

            let dbB = try AppDatabase.makeInMemory()
            let cryptoB = SyncCrypto(passphrase: "v306-pass", persistenceKey: "v306-object.b")
            do {
                _ = try await SyncEngine(provider: remote, database: dbB, crypto: cryptoB, backendFingerprint: "v306-object").syncNow()
                Issue.record("已建立加密的远端对象不应接受明文替换")
            } catch let error as SyncError {
                guard case .decryptFailed = error else { Issue.record("应为 decryptFailed，实际：\(error)"); return }
            }
            #expect(try dbB.entryDAO.entry(id: entry.id) == nil)
        }
    }

    @Test("加密后远端 manifest 被替换为明文时拒绝写回")
    func plaintextManifestIsRejectedAfterEncryptionEstablished() async throws {
        try await TestIsolation.withIsolatedDefaults { _ in
            let remote = MockRemoteStorageProvider()
            let db = try AppDatabase.makeInMemory()
            _ = try seededEntry(db)
            let crypto = SyncCrypto(passphrase: "v306-manifest", persistenceKey: "v306-manifest.pending")
            _ = try await SyncEngine(provider: remote, database: db, crypto: crypto, backendFingerprint: "v306-manifest").syncNow()
            let encrypted = try #require(remote.files[SyncPaths.manifest])
            let manifest = try decryptManifest(encrypted, with: crypto)
            remote.files[SyncPaths.manifest] = try JSONEncoder.wuyan.encode(manifest)

            do {
                _ = try await SyncEngine(provider: remote, database: db, crypto: crypto, backendFingerprint: "v306-manifest").syncNow()
                Issue.record("已建立加密的远端 manifest 不应接受明文替换")
            } catch let error as SyncError {
                guard case let .decryptFailed(reason) = error else { Issue.record("应为 decryptFailed，实际：\(error)"); return }
                #expect(reason.contains("远端索引变成了明文"))
            }
        }
    }
}
}
