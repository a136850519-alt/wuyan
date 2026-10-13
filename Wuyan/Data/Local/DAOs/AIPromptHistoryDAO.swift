import Foundation
import GRDB

/// A persisted set of the two writing prompts shown for one board and journal day.
/// Multiple rows may exist for a day because “换一组” is intentionally a new request;
/// the newest row is the set restored when the entry is opened again.
struct AIPromptHistory: Identifiable, Equatable, Sendable {
    let id: UUID
    let boardId: UUID
    let dayDate: String
    let prompts: [String]
    let createdAt: Date
}

struct AIPromptHistoryDAO {
    let writer: DatabaseWriter

    func current(boardId: UUID, dayDate: String) throws -> AIPromptHistory? {
        try writer.read { db in
            try Self.fetchOne(db: db, boardId: boardId, dayDate: dayDate)
        }
    }

    /// Returns prompts generated for this board during the supplied day-key range.
    /// The result is newest-first and keeps duplicates out so it can be used as a
    /// lightweight exclusion set for the next “换一组” request.
    func recentPrompts(boardId: UUID, since dayDate: String, through upperDayDate: String? = nil) throws -> [String] {
        try writer.read { db in
            var sql = "SELECT prompts FROM ai_prompt_history WHERE boardId = ? AND dayDate >= ?"
            var arguments: [DatabaseValueConvertible] = [boardId.uuidString, dayDate]
            if let upperDayDate {
                sql += " AND dayDate <= ?"
                arguments.append(upperDayDate)
            }
            sql += " ORDER BY createdAt DESC"
            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(arguments)
            )
            var seen = Set<String>()
            var result: [String] = []
            for row in rows {
                let payload: String = row["prompts"]
                guard let data = payload.data(using: .utf8),
                      let prompts = try? JSONDecoder.wuyan.decode([String].self, from: data) else { continue }
                for prompt in prompts where seen.insert(prompt).inserted {
                    result.append(prompt)
                }
            }
            return result
        }
    }

    /// Every exact prompt ever shown for this board. Kept separate from the
    /// rolling semantic window: an old prompt must never reappear verbatim,
    /// while angle/meaning similarity is only enforced for recent history.
    func allPrompts(boardId: UUID) throws -> [String] {
        try recentPrompts(boardId: boardId, since: "0000-01-01")
    }

    @discardableResult
    func save(boardId: UUID, dayDate: String, prompts: [String], createdAt: Date = Date()) throws -> AIPromptHistory {
        let normalized = prompts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard normalized.count == 2,
              Set(normalized.map({ $0.lowercased() })).count == 2 else {
            throw AIPromptHistoryError.invalidPromptCount
        }
        let id = UUID()
        let payload = RecordCoding.encode(normalized)
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO ai_prompt_history(id, boardId, dayDate, prompts, createdAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [id.uuidString, boardId.uuidString, dayDate, payload, createdAt]
            )
        }
        return AIPromptHistory(id: id, boardId: boardId, dayDate: dayDate, prompts: normalized, createdAt: createdAt)
    }

    func all(boardId: UUID? = nil) throws -> [AIPromptHistory] {
        try writer.read { db in
            var sql = "SELECT id, boardId, dayDate, prompts, createdAt FROM ai_prompt_history"
            var arguments = StatementArguments()
            if let boardId {
                sql += " WHERE boardId = ?"
                arguments += [boardId.uuidString]
            }
            sql += " ORDER BY createdAt DESC"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap(Self.decode)
        }
    }

    private static func fetchOne(db: Database, boardId: UUID, dayDate: String) throws -> AIPromptHistory? {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT id, boardId, dayDate, prompts, createdAt FROM ai_prompt_history WHERE boardId = ? AND dayDate = ? ORDER BY createdAt DESC LIMIT 1",
            arguments: [boardId.uuidString, dayDate]
        )
        return row.flatMap(Self.decode)
    }

    private static func decode(row: Row) -> AIPromptHistory? {
        let idString: String = row["id"]
        let boardString: String = row["boardId"]
        guard let id = UUID(uuidString: idString), let boardId = UUID(uuidString: boardString) else { return nil }
        let payload: String = row["prompts"]
        guard let data = payload.data(using: .utf8), let prompts = try? JSONDecoder.wuyan.decode([String].self, from: data) else { return nil }
        return AIPromptHistory(id: id, boardId: boardId, dayDate: row["dayDate"], prompts: prompts, createdAt: row["createdAt"])
    }
}

enum AIPromptHistoryError: LocalizedError {
    case invalidPromptCount

    var errorDescription: String? {
        "参考问题必须恰好有两条。"
    }
}
