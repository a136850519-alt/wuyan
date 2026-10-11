import Foundation
import Security
import Testing
@testable import Wuyan

extension GlobalStateSuite {
    @Suite("Protocol guards")
    struct ProtocolGuardTests {
        @Test("unknown manifest capabilities stop synchronization before writes")
        func unknownManifestFeatureIsRejected() async throws {
            try await TestIsolation.withIsolatedDefaults { _ in
                let remote = MockRemoteStorageProvider()
                let manifest = Manifest(requiredFeatures: ["future-daynote-format"])
                remote.files[SyncPaths.manifest] = try JSONEncoder.wuyan.encode(manifest)
                let database = try AppDatabase.makeInMemory()

                do {
                    _ = try await SyncEngine(provider: remote, database: database, backendFingerprint: "protocol-guard").syncNow()
                    Issue.record("unknown manifest features must stop synchronization")
                } catch let error as SyncError {
                    guard case let .unsupportedFeatures(features) = error else {
                        Issue.record("unexpected sync error: \(error)")
                        return
                    }
                    #expect(features == ["future-daynote-format"])
                }
                #expect(remote.putCounts.isEmpty)
                #expect(remote.directories.isEmpty)
            }
        }

        @Test("WebDAV collection URLs retain a trailing slash")
        func collectionURLRetainsTrailingSlash() throws {
            let provider = WebDAVProvider(baseURL: URL(string: "https://nas.local:5006/dav")!)
            #expect(try provider.resolvedURL(for: "/WuyanSync/").absoluteString == "https://nas.local:5006/dav/WuyanSync/")
            #expect(try provider.resolvedURL(for: "/WuyanSync/manifest.json").absoluteString == "https://nas.local:5006/dav/WuyanSync/manifest.json")
        }

        @Test("unavailable keychain credentials keep the diary lock enabled")
        func unavailableCredentialsFailClosed() {
            TestIsolation.withIsolatedDefaults { _ in
                AppSettings.setDiaryPasswordEnabled(true)
                SecureSettings.injectKeychainForTesting(
                    Keychain(readOverride: { _ in .unavailable(errSecInteractionNotAllowed) })
                )
                #expect(DiaryLockStore.isEnabled)
                if case .unavailable = DiaryLockStore.credentialState {
                    // Expected: the app must remain locked until credentials can be read.
                } else {
                    Issue.record("an unavailable keychain must be distinguishable from a missing credential")
                }
            }
        }

        @Test("diary unlock failures use progressive shared cooldowns")
        func diaryUnlockThrottleEscalates() {
            var throttle = DiaryUnlockThrottle()
            let now = Date(timeIntervalSince1970: 1_000)
            for _ in 0..<4 { #expect(throttle.recordFailure(at: now) == 0) }
            #expect(throttle.recordFailure(at: now) == 30)
            #expect(throttle.remainingSeconds(at: now.addingTimeInterval(1)) == 29)
            #expect(throttle.recordFailure(at: now.addingTimeInterval(30)) == 60)
            #expect(throttle.recordFailure(at: now.addingTimeInterval(90)) == 300)
            throttle.reset()
            #expect(throttle.failedAttempts == 0)
            #expect(throttle.remainingSeconds(at: now) == 0)
        }
    }
}
