import Foundation
import GRDB

/// A separate debug app identity is required before any production store opens.
enum DevelopmentPreview {
    static var isEnabled: Bool {
        #if DEBUG
        Bundle.main.bundleIdentifier == "com.wuyan.development-preview"
        #else
        false
        #endif
    }

    #if DEBUG
    @MainActor
    static func makeState() throws -> AppState {
        precondition(isEnabled)
        guard let path = Bundle.main.object(forInfoDictionaryKey: "WuyanPreviewDataDirectory") as? String,
              path.hasPrefix("/") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // UserDefaults.standard is isolated by the preview bundle identifier.
        // Reuse test seams only in this DEBUG bootstrap; never in release builds.
        SecureSettings.injectKeychainForTesting(Keychain(service: "com.wuyan.development-preview"))
        LocalMediaStore.injectMediaRootForTesting(root)
        LocalMediaStore.injectCachesSourceForTesting(root.appendingPathComponent("legacy-caches"))
        ProviderFactory.injectAIProviderForTesting { nil }
        for key in [SettingKey.syncAutoSyncEnabled, SettingKey.aiEnabled, SettingKey.aiRitual,
                    SettingKey.metadataEnabled, SettingKey.reminderEnabled] {
            UserDefaults.standard.set(false, forKey: key)
        }
        AppSettings.setOnboardingCompleted(true)
        AppMigrationRunner.run()

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let database = try AppDatabase(writer: DatabaseQueue(
            path: root.appendingPathComponent("Preview.sqlite").path,
            configuration: configuration
        ))
        let entryID = UUID(uuidString: "B9435C6A-F4B8-45CD-A844-9A69F84A0001")!
        if try database.writer.read({ try Entry.fetchCount($0) }) == 0 {
            var growth = Board.builtIn[2]
            growth.babyBirthday = DayKey.date(from: "2018-08-20")
            try database.boardDAO.save(growth)
            let date = Date()
            try database.entryDAO.save(Entry(
                id: entryID, boardId: growth.id, dayDate: date.dayKey, journalDate: date,
                title: "第一次自己整理书包",
                body: "晚饭后，你把明天要用的书一本一本放进书包。\n\n我想帮忙的时候，你说：“明天的事情，我自己准备。”于是我坐在旁边，看你把最后一支铅笔装好。\n\n8 岁的你，又学会了照顾自己一点点。",
                tags: ["成长", "日常"], weather: Weather(condition: "局部多云", tempC: 22),
                isDraft: false
            ))
            try database.entryDAO.save(Entry(
                boardId: Board.builtIn[0].id, dayDate: date.dayKey, journalDate: date,
                title: "有花的普通一天", body: "散步，买花，和家人一起吃晚饭。", isDraft: false
            ))
            try database.dayNoteDAO.upsert(DayNote(
                date: date.dayKey, rawSummary: "一起整理书包",
                poeticLine: "留住一个小小的成长", mood: 4
            ))
        }
        let state = AppState(database: database)
        state.selectedEntryId = entryID
        return state
    }
    #endif
}
