import Foundation
import SQLite3
import Darwin

/// 统计模块共用的 SQLite 基础设施。每个业务 actor 独占自己的连接，连接之间只共享数据库文件。
/// 解析日志与构造统计在事务外进行；事务只提交有界增量，避免一个来源的扫描阻塞其他模块。
/// 本类不跨 actor 传递，也不依赖主线程；公开语句句柄仅供所属 actor 的同步查询使用。
nonisolated final class AnalyticsDatabase {
    enum Value {
        case text(String), integer(Int64), real(Double), blob(Data), null
    }
    enum DatabaseError: Error {
        case unsafePath, unavailable, sqlite(Int32, String)
    }

    let url: URL
    private var database: OpaquePointer?
    private var savepointID = 0
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) { self.url = url }
    deinit { if let database { sqlite3_close(database) } }

    /// 三个业务域使用同一生产数据库；显式提供临时 home 的测试保持完全隔离。
    static func defaultURL(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support/Quotio/Analytics/analytics.sqlite")
    }

    /// 兼容旧构造器的 JSON URL：生产目录收敛到同一库，独立测试目录使用旁边的隔离库。
    static func storeURL(forLegacyURL legacyURL: URL) -> URL {
        let directory = legacyURL.deletingLastPathComponent()
        if ["UsageStatistics", "ClientUsage", "CallAnalytics"].contains(directory.lastPathComponent),
           directory.deletingLastPathComponent().lastPathComponent == "Quotio" {
            return directory.deletingLastPathComponent().appendingPathComponent("Analytics/analytics.sqlite")
        }
        return directory.appendingPathComponent("analytics.sqlite")
    }

    /// 允许系统 /var、/tmp 别名，拒绝业务目录和目标文件上的符号链接。
    /// 此校验也用于一次性导入旧文件，不允许迁移读取任意链接目标。
    static func validate(_ url: URL) throws {
        var path = url
        while path.path != "/" {
            if path.path != "/var", path.path != "/tmp",
               (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw DatabaseError.unsafePath
            }
            path.deleteLastPathComponent()
        }
    }

    func connection() throws -> OpaquePointer {
        if let database { return database }
        try Task.checkCancellation()
        try Self.validate(url)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        // 先以私有权限建立空文件，再交给 SQLite，避免数据库首次创建短暂继承宽松权限。
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DatabaseError.unavailable }
        defer { Darwin.close(descriptor) }
        guard let physical = realpath(url.path, nil) else { throw DatabaseError.unavailable }
        defer { free(physical) }
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(physical, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard code == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw DatabaseError.sqlite(code, "无法打开统计数据库")
        }
        database = handle
        do {
            sqlite3_busy_timeout(handle, 5_000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
            // 按业务迁移标识分别记录，避免多个模块争用同一个 user_version。
            try execute("CREATE TABLE IF NOT EXISTS analytics_migrations (id TEXT PRIMARY KEY, completed_at REAL NOT NULL)")
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
        return handle
    }

    var changes: Int { database.map { Int(sqlite3_changes($0)) } ?? 0 }

    func prepare(_ sql: String) throws -> OpaquePointer {
        let handle = try connection()
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw failure(code) }
        return statement
    }

    func bind(_ values: [Value], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .text(let value): code = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .integer(let value): code = sqlite3_bind_int64(statement, index, value)
            case .real(let value): code = sqlite3_bind_double(statement, index, value)
            case .blob(let value):
                // 空 Data 必须保存为空 BLOB，不能因为空缓冲区指针为 nil 被 SQLite 解释成 NULL。
                if value.isEmpty { code = sqlite3_bind_zeroblob(statement, index, 0) }
                else { code = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) } }
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw failure(code) }
        }
    }

    func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        // PRAGMA 可能返回一行；持续 step 到 DONE，确保语句真正执行完成。
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw failure(code) }
        }
    }

    func query<T>(_ sql: String, _ values: [Value] = [], map: (OpaquePointer) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var result: [T] = []
        while true {
            try Task.checkCancellation()
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw failure(code) }
            result.append(try map(statement))
        }
    }

    func scalarInt(_ sql: String, _ values: [Value] = []) throws -> Int64? {
        try query(sql, values) { sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : sqlite3_column_int64($0, 0) }.first ?? nil
    }

    func scalarText(_ sql: String, _ values: [Value] = []) throws -> String? {
        try query(sql, values) { statement in
            sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }.first ?? nil
    }

    /// 增量事实、汇总、水位和迁移标记可在一个事务内提交；嵌套业务操作通过 savepoint 回滚。
    /// 闭包同步执行，不允许在持有写事务时等待文件扫描或网络。
    func transaction<T>(_ body: () throws -> T) throws -> T {
        let handle = try connection()
        let nested = sqlite3_get_autocommit(handle) == 0
        savepointID += 1
        let savepoint = "analytics_\(savepointID)"
        try execute(nested ? "SAVEPOINT \(savepoint)" : "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try Task.checkCancellation()
            try execute(nested ? "RELEASE SAVEPOINT \(savepoint)" : "COMMIT")
            return result
        } catch {
            if nested {
                try? execute("ROLLBACK TO SAVEPOINT \(savepoint)")
                try? execute("RELEASE SAVEPOINT \(savepoint)")
            } else { try? execute("ROLLBACK") }
            throw error
        }
    }

    func hasMigration(_ id: String) throws -> Bool {
        try scalarInt("SELECT 1 FROM analytics_migrations WHERE id=?", [.text(id)]) != nil
    }

    func markMigration(_ id: String) throws {
        try execute("INSERT OR IGNORE INTO analytics_migrations(id,completed_at) VALUES(?,?)",
                    [.text(id), .real(Date().timeIntervalSince1970)])
    }

    private func failure(_ code: Int32) -> DatabaseError {
        // 不输出 SQL 参数、文件路径或事件正文，只提供 SQLite 通用诊断信息。
        .sqlite(code, database.map { String(cString: sqlite3_errmsg($0)) } ?? "统计数据库不可用")
    }
}
