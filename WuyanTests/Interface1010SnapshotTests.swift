import AppKit
import SwiftUI
import CoreText
import Testing
@testable import Wuyan

extension GlobalStateSuite {
    @MainActor
    struct Interface1010SnapshotTests {
        /// Opt-in visual fixture: renders real SwiftUI with synthetic data in an
        /// offscreen test window. Never starts or installs the application.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["WUYAN_SNAPSHOT_DIR"] != nil))
        func nativeLayoutSnapshots() async throws {
            try await TestIsolation.withIsolatedDefaults { _ in
                AppSettings.setOnboardingCompleted(true)
                let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Wuyan/Resources/Fonts/LXGWWenKai-Regular.ttf")
                CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
                let originalAppearance = NSApplication.shared.appearance
                defer { NSApplication.shared.appearance = originalAppearance }
                let db = try AppDatabase.makeInMemory()
                var growth = Board.builtIn[2]
                growth.babyBirthday = DayKey.date(from: "2018-08-20")
                try db.boardDAO.save(growth)
                let date = DayKey.date(from: "2026-10-10")!.addingTimeInterval(19 * 3600)
                let entry = Entry(boardId: growth.id, journalDate: date, title: "第一次自己整理书包", body: "晚饭后，你把明天要用的书一本一本放进书包。\n\n我想帮忙的时候，你说：“明天的事情，我自己准备。”于是我坐在旁边，看你把最后一支铅笔装好。\n\n8 岁的你，又学会了照顾自己一点点。", weather: Weather(condition: "局部多云", tempC: 22))
                try db.entryDAO.save(entry)
                try db.entryDAO.save(Entry(boardId: Board.builtIn[0].id, journalDate: date, title: "有花的普通一天", body: "散步，买花，和家人一起吃晚饭。"))
                try db.dayNoteDAO.upsert(DayNote(date: entry.dayDate, rawSummary: "一起整理书包", poeticLine: "留住一个小小的成长", mood: 4))
                let state = AppState(database: db)
                state.selectedEntryId = entry.id
                let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WUYAN_SNAPSHOT_DIR"]!)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (name, scheme, width) in [("native-light", ColorScheme.light, 1440.0), ("native-dark", .dark, 1440.0), ("native-narrow", .light, 1050.0)] {
                    NSApplication.shared.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    let view = RootView().environmentObject(state).environment(\.colorScheme, scheme)
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 960), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    window.contentView = host
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 960)
                    try await Task.sleep(for: .milliseconds(350))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: directory.appendingPathComponent(name + ".png"))
                    window.close()
                }
            }
        }
    }
}
