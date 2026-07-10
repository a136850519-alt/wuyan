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
            _ = try Board.deleteOne(db, key: id.uuidString)
        }
    }

    public func ensureBuiltInBoards() throws {
        try writer.write { db in
            // 按 kind 幂等：只补齐本地缺失的内置板块，不再用「表为空」作为唯一判据。
            // 否则同步把 board 拉回后表非空，但某 kind 缺失时也不会被补上；
            // 而 kind 存在时即使 id 不同也不会重复插入（靠 stableID 保持身份一致）。
            for board in Board.builtIn {
                let exists = try Board
                    .filter(Board.Columns.kind == board.kind.rawValue)
                    .fetchCount(db) > 0
                if !exists {
                    try board.insert(db)
                }
            }
        }
    }
}
