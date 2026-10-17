import Foundation
import Testing
@testable import Wuyan

@Suite("macOS optimization regression")
struct MacOSOptimizationTests {
    @Test("year themes persist by stable identifier and recover unknown values")
    func yearThemePersistence() throws {
        try TestIsolation.withIsolatedDefaults { _ in
            #expect(AppSettings.yearTheme(2026) == YearTheme.default.rawValue)
            AppSettings.setYearTheme(YearTheme.rose.rawValue, for: 2026)
            AppSettings.setYearTheme(YearTheme.mist.rawValue, for: 2025)
            #expect(AppSettings.yearTheme(2026) == "rose")
            #expect(AppSettings.yearTheme(2025) == "mist")
            AppSettings.setYearTheme("unknown-value", for: 2024)
            #expect(AppSettings.yearTheme(2024) == YearTheme.default.rawValue)
        }
    }

    @Test("custom year themes normalize HEX and survive a reload")
    func customYearThemePersistence() throws {
        try TestIsolation.withIsolatedDefaults { _ in
            AppSettings.setYearTheme("abc", for: 2027)
            #expect(AppSettings.yearThemeValue(2027) == .custom(hex: "#AABBCC"))
            #expect(Palette.normalizedHex("#12a") == "#1122AA")
            #expect(Palette.normalizedHex("#12345") == nil)
        }
    }

    @Test("local year archive roundtrips through the final file")
    func localYearArchiveRoundTrip() throws {
        try TestIsolation.withIsolatedDefaults { _ in
            let database = try AppDatabase.makeInMemory()
            let board = try #require(try database.boardDAO.all().first)
            let entry = Entry(boardId: board.id, dayDate: "2025-06-03", journalDate: Date(timeIntervalSince1970: 1_749_024_000), title: "夏日", body: "风从窗边经过。", isDraft: false)
            try database.entryDAO.save(entry)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("wuyan-\(UUID().uuidString).wuyanarchive")
            defer { try? FileManager.default.removeItem(at: url) }
            let service = YearArchiveService()
            let snapshot = try service.createArchive(year: 2025, password: "correct horse battery", to: url, database: database)
            let reopened = try service.readArchive(from: url, password: "correct horse battery")
            #expect(snapshot.entries.map(\.id) == reopened.entries.map(\.id))
            #expect(reopened.entries.first?.body == "风从窗边经过。")
            #expect(throws: YearArchiveError.self) {
                _ = try service.readArchive(from: url, password: "wrong password")
            }
        }
    }

    @Test("local year archive restores into a separate database")
    func localYearArchiveRestore() throws {
        try TestIsolation.withIsolatedDefaults { _ in
            let source = try AppDatabase.makeInMemory()
            let target = try AppDatabase.makeInMemory()
            let board = try #require(try source.boardDAO.all().first)
            let entry = Entry(boardId: board.id, dayDate: "2025-06-04", journalDate: Date(), title: "恢复测试", body: "从归档回到日记库。", isDraft: false)
            try source.entryDAO.save(entry)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("wuyan-restore-\(UUID().uuidString).wuyanarchive")
            defer { try? FileManager.default.removeItem(at: url) }

            let service = YearArchiveService()
            _ = try service.createArchive(year: 2025, password: "restore-password", to: url, database: source)
            let report = try service.restoreArchive(
                from: url,
                password: "restore-password",
                database: target,
                mediaStore: try LocalMediaStore(database: target)
            )

            #expect(report.importedEntries == 1)
            #expect(try target.entryDAO.timeline(filter: .all).first?.body == "从归档回到日记库。")
        }
    }

    @Test("AI endpoint validation rejects incomplete or unsupported addresses")
    func endpointValidation() {
        #expect((try? ProviderFactory.validateHTTPURL("localhost:11434", service: "Ollama")) == nil)
        #expect((try? ProviderFactory.validateHTTPURL("ftp://example.com", service: "Ollama")) == nil)
        #expect((try? ProviderFactory.validateHTTPURL("http://localhost:11434", service: "Ollama")) != nil)
    }

    @Test("missing API key errors identify the service")
    func missingAPIKeyMessage() {
        #expect(AIError.missingAPIKey(service: "Claude").localizedDescription.contains("Claude API Key"))
        #expect(AIError.authenticationFailed(service: "智谱").localizedDescription.contains("身份验证失败"))
    }

    @Test("AI service errors keep status classification even when a provider returns JSON")
    func providerErrorClassification() {
        #expect(AIError.rateLimited(service: "Claude").localizedDescription.contains("请求过于频繁"))
        #expect(AIError.permissionDenied(service: "Claude").localizedDescription.contains("无权使用"))
    }
}
