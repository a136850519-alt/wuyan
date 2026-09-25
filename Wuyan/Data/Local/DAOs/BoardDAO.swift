import Foundation
import GRDB

public protocol BoardRepository {
    func all() throws -> [Board]
    func save(_ board: Board) throws
    func delete(id: UUID) throws
}

public enum BoardError: LocalizedError {
    case cannotDeleteNonEmptyBoard

    public var errorDescription: String? {
        switch self {
        case .cannotDeleteNonEmptyBoard:
            return "这个板块里还有日记，先迁移或删除条目后再删除板块。"
        }
    }
}

public struct BoardDAO: BoardRepository {
    let writer: DatabaseWriter

    public func all() throws -> [Board] {
        try writer.read { db in
            try Board
                .filter(Board.Columns.deletedAt == nil)
                .order(Board.Columns.sortOrder.asc, Board.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    /// 同步清单需要同时看到活动板块和删除墓碑。
    func allIncludingDeleted() throws -> [Board] {
        try writer.read { db in
            try Board
                .order(Board.Columns.sortOrder.asc, Board.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    public func board(id: UUID) throws -> Board? {
        try writer.read { db in
            try Board.fetchOne(db, key: id.uuidString)
        }
    }

    public func save(_ board: Board) throws {
        var board = board
        board.updatedAt = Date()
        try saveRemote(board)
    }

    /// 保存已经带有远端版本时间的板块，不刷新 updatedAt。
    func saveRemote(_ board: Board) throws {
        try writer.write { db in
            try board.save(db)
        }
    }

    public func delete(id: UUID) throws {
        try writer.write { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM entry WHERE boardId = ? AND deleted = 0",
                arguments: [id.uuidString]
            ) ?? 0
            guard count == 0 else { throw BoardError.cannotDeleteNonEmptyBoard }
            guard var board = try Board.fetchOne(db, key: id.uuidString) else { return }
            board.deletedAt = Date()
            board.updatedAt = Date()
            try board.update(db)
        }
    }

    func hasActiveEntries(id: UUID) throws -> Bool {
        try writer.read { db in
            (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM entry WHERE boardId = ? AND deleted = 0",
                arguments: [id.uuidString]
            ) ?? 0) > 0
        }
    }

    public func ensureBuiltInBoards() throws {
        try writer.write { db in
            // 按 kind 幂等：只补齐本地缺失的内置板块，不再用「表为空」作为唯一判据。
            // 否则同步把 board 拉回后表非空，但某 kind 缺失时也不会被补上；
            // 而 kind 存在时即使 id 不同也不会重复插入（靠 stableID 保持身份一致）。
            for board in Board.builtIn {
                if var existing = try Board.fetchOne(db, key: board.id.uuidString), existing.deletedAt != nil {
                    existing.deletedAt = nil
                    existing.updatedAt = Date()
                    try existing.update(db)
                    continue
                }
                let exists = try Board
                    .filter(Board.Columns.kind == board.kind.rawValue)
                    .filter(Board.Columns.deletedAt == nil)
                    .fetchCount(db) > 0
                if !exists {
                    try board.insert(db)
                }
            }
        }
    }
}
