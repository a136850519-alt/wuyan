import Foundation
import Testing
@testable import Wuyan

@Suite("V3-15: Permanent purge records", .serialized)
struct V315PurgeRecordTests {
    private func makeEngine(_ db: AppDatabase, _ remote: MockRemoteStorageProvider, fingerprint: String) -> SyncEngine {
        SyncEngine(
            provider: remote,
            database: db,
            backendFingerprint: fingerprint,
            deletedRetention: 0
        )
    }

    private func seed(_ db: AppDatabase, body: String = "baseline") throws -> Entry {
        let board = try #require(try db.boardDAO.all().first)
        let entry = Entry(boardId: board.id, dayDate: "2026-09-20", body: body, isDraft: false)
        try db.entryDAO.save(entry)
        return try #require(try db.entryDAO.entry(id: entry.id))
    }

    private func manifest(_ remote: MockRemoteStorageProvider) throws -> Manifest {
        try JSONDecoder.wuyan.decode(Manifest.self, from: try #require(remote.files[SyncPaths.manifest]))
    }

    private func establishPair(
        _ dbA: AppDatabase,
        _ dbB: AppDatabase,
        _ remote: MockRemoteStorageProvider,
        fingerprint: String
    ) async throws -> Entry {
        let entry = try seed(dbA)
        _ = try await makeEngine(dbA, remote, fingerprint: fingerprint).syncNow()
        _ = try await makeEngine(dbB, remote, fingerprint: fingerprint).syncNow()
        return try #require(try dbB.entryDAO.entry(id: entry.id))
    }

    private func purgeOnA(
        _ dbA: AppDatabase,
        _ remote: MockRemoteStorageProvider,
        id: UUID,
        fingerprint: String
    ) async throws {
        try dbA.entryDAO.permanentlyDelete(id: id)
        _ = try await makeEngine(dbA, remote, fingerprint: fingerprint).syncNow()
        // 第二轮验证清除记录仍然阻止空后端/旧墓碑路径复活。
        _ = try await makeEngine(dbA, remote, fingerprint: fingerprint).syncNow()
    }

    @Test("expired deletion moves a clean offline copy to trash without PUT")
    func cleanOfflineCopyIsPurged() async throws {
        try await TestIsolation.withIsolatedDefaults { _ in
            let dbA = try AppDatabase.makeInMemory()
            let dbB = try AppDatabase.makeInMemory()
            let remote = MockRemoteStorageProvider()
            let fingerprint = "v315-clean"
            let entry = try await establishPair(dbA, dbB, remote, fingerprint: fingerprint)
            try await purgeOnA(dbA, remote, id: entry.id, fingerprint: fingerprint)

            let report = try await makeEngine(dbB, remote, fingerprint: fingerprint).syncNow()
            let final = try #require(try dbB.entryDAO.entry(id: entry.id))
            let finalManifest = try manifest(remote)
            #expect(final.deleted)
            #expect(!final.dirty)
            #expect(finalManifest.entries.allSatisfy { $0.id != entry.id || $0.deleted })
            #expect(finalManifest.purged?.contains { $0.id == entry.id } == true)
            #expect(report.purgedToTrash == 1)
            let entryPath = try #require(finalManifest.purged?.first { $0.id == entry.id })
            _ = entryPath
            #expect(remote.putCounts.values.reduce(0, +) > 0)
            #expect(remote.putCounts.filter { $0.key.hasPrefix("/Wuyan/entries/") }.values.reduce(0, +) == 1)
        }
    }

    @Test("offline edits are preserved as a conflict before purge")
    func changedOfflineCopyGetsConflict() async throws {
        try await TestIsolation.withIsolatedDefaults { _ in
            let dbA = try AppDatabase.makeInMemory()
            let dbB = try AppDatabase.makeInMemory()
            let remote = MockRemoteStorageProvider()
            let fingerprint = "v315-conflict"
            var entry = try await establishPair(dbA, dbB, remote, fingerprint: fingerprint)
            entry.body = "edited while offline"
            try dbB.entryDAO.save(entry)
            try await purgeOnA(dbA, remote, id: entry.id, fingerprint: fingerprint)

            let report = try await makeEngine(dbB, remote, fingerprint: fingerprint).syncNow()
            let final = try #require(try dbB.entryDAO.entry(id: entry.id))
            #expect(final.deleted)
            #expect(report.conflicts.contains(entry.id))
            #expect(try dbB.entryDAO.hasConflictCopy(id: entry.id))
            #expect(try manifest(remote).purged?.contains { $0.id == entry.id } == true)
        }
    }

    @Test("restoring a purged entry explicitly republishes it")
    func explicitRestoreRepublishes() async throws {
        try await TestIsolation.withIsolatedDefaults { _ in
            let dbA = try AppDatabase.makeInMemory()
            let dbB = try AppDatabase.makeInMemory()
            let remote = MockRemoteStorageProvider()
            let fingerprint = "v315-restore"
            let entry = try await establishPair(dbA, dbB, remote, fingerprint: fingerprint)
            try await purgeOnA(dbA, remote, id: entry.id, fingerprint: fingerprint)
            _ = try await makeEngine(dbB, remote, fingerprint: fingerprint).syncNow()

            try dbB.entryDAO.restore(id: entry.id)
            _ = try await makeEngine(dbB, remote, fingerprint: fingerprint).syncNow()
            let restoredManifest = try manifest(remote)
            #expect(restoredManifest.entries.contains { $0.id == entry.id && !$0.deleted })
            #expect(restoredManifest.purged?.contains { $0.id == entry.id } != true)

            _ = try await makeEngine(dbA, remote, fingerprint: fingerprint).syncNow()
            #expect(try dbA.entryDAO.entry(id: entry.id)?.deleted == false)
        }
    }

    @Test("local purge table repairs a purged field lost by an old client")
    func oldClientCannotErasePurgeRecord() async throws {
        try await TestIsolation.withIsolatedDefaults { _ in
            let dbA = try AppDatabase.makeInMemory()
            let remote = MockRemoteStorageProvider()
            let fingerprint = "v315-old-client"
            let entry = try seed(dbA)
            _ = try await makeEngine(dbA, remote, fingerprint: fingerprint).syncNow()
            try await purgeOnA(dbA, remote, id: entry.id, fingerprint: fingerprint)

            var object = try JSONSerialization.jsonObject(with: try #require(remote.files[SyncPaths.manifest])) as! [String: Any]
            object.removeValue(forKey: "purged")
            remote.files[SyncPaths.manifest] = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            _ = try await makeEngine(dbA, remote, fingerprint: fingerprint).syncNow()

            #expect(try manifest(remote).purged?.contains { $0.id == entry.id } == true)
        }
    }

    @Test("purged-only manifest is not mistaken for an empty backend")
    func purgedOnlyManifestDoesNotBootstrap() async throws {
        try await TestIsolation.withIsolatedDefaults { _ in
            let db = try AppDatabase.makeInMemory()
            let remote = MockRemoteStorageProvider()
            let fingerprint = "v315-no-bootstrap"
            let entry = try seed(db)
            try db.entryDAO.markClean(id: entry.id, expectedHash: entry.contentHash)
            let purge = PurgedEntry(id: entry.id, deletedAt: Date(timeIntervalSinceNow: -3600))
            var remoteOnly = Manifest(entries: [], purged: [purge])
            remoteOnly.revision = SyncEngine.computeRevision(entries: [], daynotes: [], boards: [], purged: [purge])
            remote.files[SyncPaths.manifest] = try JSONEncoder.wuyan.encode(remoteOnly)

            let report = try await makeEngine(db, remote, fingerprint: fingerprint).syncNow()
            #expect(report.purgedToTrash == 1)
            #expect(try manifest(remote).entries.isEmpty)
            #expect(remote.putCounts.filter { $0.key.hasPrefix("/Wuyan/entries/") }.isEmpty)
        }
    }

    @Test("revision remains backward compatible without purges")
    func revisionCompatibility() {
        let empty = SyncEngine.computeRevision(entries: [], daynotes: [], boards: [], purged: [])
        #expect(empty == "sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let id = UUID()
        let changed = SyncEngine.computeRevision(
            entries: [], daynotes: [], boards: [], purged: [PurgedEntry(id: id, deletedAt: Date(timeIntervalSince1970: 1))]
        )
        #expect(changed != empty)
    }

    @Test("normalizePurges deduplicates and applies resurrection rules")
    func normalizePurgesRules() throws {
        let board = UUID()
        let deletedID = UUID()
        let staleID = UUID()
        let restoredID = UUID()
        let deletedAt = Date(timeIntervalSince1970: 100)
        var manifest = Manifest(
            entries: [
                ManifestEntry(id: deletedID, boardId: board, dayDate: "2026-01-01", path: "d", updatedAt: Date(timeIntervalSince1970: 90), hash: "d", deleted: true),
                ManifestEntry(id: staleID, boardId: board, dayDate: "2026-01-01", path: "s", updatedAt: Date(timeIntervalSince1970: 90), hash: "s", deleted: false),
                ManifestEntry(id: restoredID, boardId: board, dayDate: "2026-01-01", path: "r", updatedAt: Date(timeIntervalSince1970: 101), hash: "r", deleted: false)
            ],
            purged: [
                PurgedEntry(id: deletedID, deletedAt: deletedAt),
                PurgedEntry(id: staleID, deletedAt: deletedAt),
                PurgedEntry(id: restoredID, deletedAt: deletedAt),
                PurgedEntry(id: deletedID, deletedAt: Date(timeIntervalSince1970: 99))
            ]
        )
        SyncEngine.normalizePurges(&manifest)
        #expect(manifest.entries.contains { $0.id == deletedID } == false)
        #expect(manifest.entries.contains { $0.id == staleID } == false)
        #expect(manifest.entries.contains { $0.id == restoredID })
        #expect(manifest.purged?.count == 2)
        #expect(manifest.purged?.first { $0.id == deletedID }?.deletedAt == deletedAt)
        #expect(manifest.purged?.contains { $0.id == restoredID } == false)
    }
}
