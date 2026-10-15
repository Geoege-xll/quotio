import Foundation
import SQLite3

/// 技能元数据的窄接口：所有字符串均使用 SQLITE_TRANSIENT 复制绑定，
/// SQL 执行失败必须向上传递，不能把磁盘满、损坏数据库等情况包装成操作成功。
nonisolated final class WorkspaceSkillDatabase: @unchecked Sendable {
    private let handle: OpaquePointer

    init(path: String, create: Bool = false, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开技能数据库"
            if let db { sqlite3_close(db) }
            throw WorkspaceSkillError.database(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, _ values: [String?] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    func rows(_ sql: String, _ values: [String?] = []) throws -> [[String: String]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [[String: String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw error() }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let text = sqlite3_column_text(statement, index) else { continue }
                row[String(cString: sqlite3_column_name(statement, index))] = String(cString: text)
            }
            result.append(row)
        }
    }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ values: [String?]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error()
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            if let value {
                status = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            } else {
                status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw error()
            }
        }
        return statement
    }

    private func error() -> WorkspaceSkillError {
        .database(String(cString: sqlite3_errmsg(handle)))
    }
}

public nonisolated enum WorkspaceSkillError: LocalizedError {
    case database(String)
    case invalidPath(String)
    case conflict(String)
    case invalidRepository(String)
    case requestFailed(String)
    case busy(String)
    case notPrepared
    case incompleteOperation(String)

    public var errorDescription: String? {
        switch self {
        case .database(let detail): return "技能数据库操作失败：\(detail)"
        case .invalidPath(let path): return "技能路径不安全或格式无效：\(path)"
        case .conflict(let path): return "存在独立目录、其他来源链接或同名技能，已保留原内容：\(path)"
        case .invalidRepository(let detail): return "无法确定技能的完整仓库目录：\(detail)"
        case .requestFailed(let detail): return "技能下载失败：\(detail)"
        case .busy(let name): return "技能 \(name) 正在操作，请完成后重试"
        case .notPrepared: return "技能存储尚未初始化，请重新刷新技能页面"
        case .incompleteOperation(let detail): return "技能操作未完成：\(detail)"
        }
    }
}
