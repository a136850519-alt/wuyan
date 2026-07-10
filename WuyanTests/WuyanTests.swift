import XCTest
@testable import Wuyan

final class WuyanTests: XCTestCase {
    func testDayKeyRollsOverAtThreeAM() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let beforeThree = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 18, hour: 2, minute: 59)))
        let atThree = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 18, hour: 3)))

        XCTAssertEqual(beforeThree.dayKey, "2026-06-17")
        XCTAssertEqual(atThree.dayKey, "2026-06-18")
    }

    func testBuiltInBoardsAreCreatedOnce() throws {
        let db = try AppDatabase.makeInMemory()
        let boards = try db.boardDAO.all()

        XCTAssertEqual(boards.map(\.name), ["五年", "日常唠叨", "宝贝成长记录"])
        XCTAssertEqual(boards.map(\.kind), [.fiveYear, .freeform, .growth])

        try db.boardDAO.ensureBuiltInBoards()
        XCTAssertEqual(try db.boardDAO.all().count, 3)
    }

    func testDayNoteUpsertReplacesSameDay() throws {
        let db = try AppDatabase.makeInMemory()
        let first = DayNote(date: "2026-06-17", rawSummary: "今天下雨", poeticLine: "今天下雨")
        let second = DayNote(date: "2026-06-17", rawSummary: "雨停了", poeticLine: "雨停了")

        try db.dayNoteDAO.upsert(first)
        try db.dayNoteDAO.upsert(second)

        let fetched = try XCTUnwrap(db.dayNoteDAO.note(dayKey: "2026-06-17"))
        XCTAssertEqual(fetched.rawSummary, "雨停了")
        XCTAssertEqual(fetched.poeticLine, "雨停了")
    }

    func testEntrySaveRefreshesHashDirtyAndSoftDeleteHidesFromTimeline() throws {
        let db = try AppDatabase.makeInMemory()
        let board = try XCTUnwrap(db.boardDAO.all().first)
        let note = DayNote(date: "2026-06-17", rawSummary: "起笔", poeticLine: "起笔")
        try db.dayNoteDAO.upsert(note)

        var entry = try db.entryDAO.create(boardId: board.id, dayNote: note)
        let firstHash = entry.contentHash
        entry.title = "今日"
        entry.body = "写了一段文字"
        entry.tags = ["家", "雨"]
        try db.entryDAO.save(entry)

        let saved = try XCTUnwrap(db.entryDAO.entry(id: entry.id))
        XCTAssertNotEqual(saved.contentHash, firstHash)
        XCTAssertTrue(saved.dirty)
        XCTAssertFalse(saved.isDraft)
        XCTAssertEqual(try db.entryDAO.timeline(filter: .all).count, 1)

        try db.entryDAO.softDelete(id: entry.id)
        XCTAssertEqual(try db.entryDAO.timeline(filter: .all).count, 0)
        XCTAssertTrue(try XCTUnwrap(db.entryDAO.entry(id: entry.id)).deleted)
    }

    func testContentHashIsStableAcrossTagOrderAndWhitespace() {
        let first = Hashing.entryContentHash(
            title: " 今日 ",
            body: " 正文\n",
            tags: ["雨", "家"],
            mood: 4,
            weather: Weather(condition: "rain", tempC: 18),
            location: GeoPlace(lat: 30, lon: 120, placeName: "杭州"),
            mediaIds: []
        )
        let second = Hashing.entryContentHash(
            title: "今日",
            body: "正文",
            tags: ["家", "雨"],
            mood: 4,
            weather: Weather(condition: "rain", tempC: 18),
            location: GeoPlace(lat: 30, lon: 120, placeName: "杭州"),
            mediaIds: []
        )

        XCTAssertEqual(first, second)
    }
}
