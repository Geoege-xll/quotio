import Foundation
import SQLite3

/// 客户端用量唯一的持久化入口。事件、累计检查点、扫描游标均保存为可查询的标量列。
/// scope 明确区分扫描器已解析的输入和账本完成的投影：前者用于中断恢复，后者用于展示；
/// 两者位于同一数据库，扫描水位与对应输入在同一事务提交，不再依赖 JSON 补写。
/// 实例仅由所属 actor 串行使用；独立解析测试可在同步调用栈中短暂创建自己的连接。
nonisolated final class ClientUsageSQLiteStore {
    let database: AnalyticsDatabase
    private var prepared = false
    var lineCaches: [ClientUsageSource: ClaudeClientUsageReader.Cache] = [:]
    var codexCaches: [String: CodexUsageFileCache]?
    var openCodeCache: OpenCodeClientUsageCache?
    var openCodeLoaded = false

    init(databaseURL: URL) { database = AnalyticsDatabase(url: databaseURL) }

    /// cacheURL 仅指定旧索引的导入位置；新数据始终进入同目录派生的 SQLite。
    static func forCache(_ cacheURL: URL?) -> ClientUsageSQLiteStore? {
        cacheURL.map { ClientUsageSQLiteStore(databaseURL: AnalyticsDatabase.storeURL(forLegacyURL: $0)) }
    }

    func prepare() throws {
        guard !prepared else { return }
        try database.transaction {
            try database.execute("""
                CREATE TABLE IF NOT EXISTS client_usage_records (
                    scope TEXT NOT NULL, id TEXT NOT NULL, source TEXT NOT NULL, timestamp REAL NOT NULL,
                    model TEXT NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL, cached INTEGER NOT NULL,
                    reasoning INTEGER NOT NULL, total INTEGER NOT NULL, reasoning_known INTEGER,
                    PRIMARY KEY(scope,id))
                """)
            try database.execute("CREATE INDEX IF NOT EXISTS client_usage_records_query ON client_usage_records(scope,source,timestamp,model)")
            try database.execute("""
                CREATE TABLE IF NOT EXISTS client_usage_checkpoints (
                    scope TEXT NOT NULL, id TEXT NOT NULL, session_id TEXT NOT NULL, parent_id TEXT,
                    timestamp REAL NOT NULL, fork_date REAL, model TEXT NOT NULL, ordinal INTEGER NOT NULL,
                    has_errors INTEGER NOT NULL, cumulative_input INTEGER, cumulative_output INTEGER,
                    cumulative_cached INTEGER, cumulative_reasoning INTEGER, cumulative_total INTEGER,
                    last_input INTEGER, last_output INTEGER, last_cached INTEGER, last_reasoning INTEGER,
                    last_total INTEGER, PRIMARY KEY(scope,id))
                """)
            try database.execute("CREATE INDEX IF NOT EXISTS client_usage_checkpoints_session ON client_usage_checkpoints(scope,session_id,timestamp)")
            try database.execute("""
                CREATE TABLE IF NOT EXISTS client_usage_status (
                    source TEXT PRIMARY KEY, available INTEGER NOT NULL, has_errors INTEGER NOT NULL,
                    files_scanned INTEGER NOT NULL)
                """)
            try database.execute("CREATE TABLE IF NOT EXISTS client_usage_metadata (id TEXT PRIMARY KEY, value REAL)")
            try prepareScanTables()
            try prepareIncrementalLedgerTables()
        }
        prepared = true
    }

    /// 只有首次迁移读取旧账本，损坏归档阻止迁移并原样保留，不能被空统计覆盖。
    /// 迁移标记与每条历史记录一起提交，崩溃后可以安全重试。
    func loadLedger(legacyURL: URL) throws -> ClientUsageSnapshot {
        var value = try loadLedgerMetadata(legacyURL: legacyURL)
        // 仅供归档兼容、诊断和测试显式读取原始账本。生产展示调用 loadDisplay，
        // 不能让这里的全历史数组再进入 Engine 或 ViewModel 的常驻属性。
        value.records = try loadRecords(scope: "ledger")
        let checkpoints = try loadCheckpoints(scope: "ledger")
        value.codexCheckpoints = checkpoints.isEmpty ? nil : checkpoints
        return value
    }

    /// 恢复一次性旧归档后只读取来源状态和采集时间，不分配历史事件或检查点数组。
    func loadLedgerMetadata(legacyURL: URL) throws -> ClientUsageSnapshot {
        try prepare()
        let migration = "client-usage-ledger-v1"
        if try !database.hasMigration(migration) {
            try AnalyticsDatabase.validate(legacyURL)
            var legacy: ClientUsageSnapshot?
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                legacy = try JSONDecoder().decode(ClientUsageSnapshot.self, from: Data(contentsOf: legacyURL))
                guard let legacy, Self.valid(legacy) else { throw ClientUsageEngine.ArchiveError.invalidArchive }
            }
            try database.transaction {
                // 锁内再次检查，避免并行恢复的另一个实例覆盖已完成迁移后的新统计。
                guard try !database.hasMigration(migration) else { return }
                if let legacy { try saveLedger(legacy, previous: nil) }
                try database.markMigration(migration)
            }
        }
        return try ledgerMetadata()
    }

    func ledgerMetadata() throws -> ClientUsageSnapshot {
        let statuses = try database.query("""
            SELECT s.source,s.available,s.has_errors,s.files_scanned,d.read_errors,d.incomplete_sessions
            FROM client_usage_status s LEFT JOIN client_usage_status_details d ON d.source=s.source
            ORDER BY s.source
            """) { statement in
            guard let source = ClientUsageSource(rawValue: Self.text(statement, 0)) else {
                throw ClientUsageEngine.ArchiveError.invalidArchive
            }
            return ClientUsageStatus(source: source, available: sqlite3_column_int(statement, 1) != 0,
                                     hasErrors: sqlite3_column_int(statement, 2) != 0,
                                     filesScanned: Int(sqlite3_column_int64(statement, 3)),
                                     readErrors: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 4) != 0,
                                     incompleteSessionCount: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 5)))
        }
        let date = try database.query("SELECT value FROM client_usage_metadata WHERE id='collected_at'") {
            Date(timeIntervalSince1970: sqlite3_column_double($0, 0))
        }.first
        return ClientUsageSnapshot(statuses: statuses, collectedAt: date)
    }

    /// 只写入新建、修正或被重投影删除的行；不会每次刷新重编码整份历史。
    func saveLedger(_ snapshot: ClientUsageSnapshot, previous: ClientUsageSnapshot?) throws {
        try prepare()
        try database.transaction {
            try writeRecords(snapshot.records, previous: previous?.records ?? [], scope: "ledger")
            try writeCheckpoints(snapshot.codexCheckpoints ?? [], previous: previous?.codexCheckpoints ?? [], scope: "ledger")
            let oldStatuses = Dictionary((previous?.statuses ?? []).map { ($0.source, $0) }, uniquingKeysWith: { _, last in last })
            for status in snapshot.statuses where oldStatuses[status.source] != status {
                try saveStatus(status)
            }
            if let date = snapshot.collectedAt {
                try database.execute("INSERT OR REPLACE INTO client_usage_metadata VALUES('collected_at',?)", [.real(date.timeIntervalSince1970)])
            }
        }
    }

    /// 原聚合状态保留供旧归档使用，具体诊断单独保存，不改写事件、检查点或历史总量。
    /// 与调用方的扫描提交共用事务，保证重启后仍能区分读取失败和历史缺口。
    func saveStatus(_ status: ClientUsageStatus) throws {
        try database.execute("INSERT OR REPLACE INTO client_usage_status VALUES(?,?,?,?)", [
            .text(status.source.rawValue), Self.bool(status.available), Self.bool(status.hasErrors), Self.integer(status.filesScanned)])
        try database.execute("INSERT OR REPLACE INTO client_usage_status_details VALUES(?,?,?)", [
            .text(status.source.rawValue), status.readErrors.map(Self.bool) ?? .null,
            status.incompleteSessionCount.map(Self.integer) ?? .null])
    }

    static func valid(_ snapshot: ClientUsageSnapshot) -> Bool {
        snapshot.version == 1 && snapshot.records.allSatisfy { record in
            record.id.count == 64 && record.timestamp.timeIntervalSince1970.isFinite
                && [record.input, record.output, record.cached, record.reasoning].allSatisfy { $0 >= 0 && $0 <= 1_000_000_000_000 }
                && record.total >= 0 && record.total <= 2_000_000_000_000
        } && (snapshot.codexCheckpoints ?? []).allSatisfy { checkpoint in
            checkpoint.id.count == 64 && checkpoint.sessionID.count == 64
                && checkpoint.timestamp.timeIntervalSince1970.isFinite
                && [checkpoint.cumulative, checkpoint.last].compactMap { $0 }.allSatisfy { tokens in
                    [tokens.input, tokens.output, tokens.cached, tokens.reasoning, tokens.total]
                        .allSatisfy { $0 >= 0 && $0 <= 2_000_000_000_000 }
                }
        }
    }

    static let recordColumns = "id,source,timestamp,model,input,output,cached,reasoning,total,reasoning_known"
    static let checkpointColumns = "id,session_id,parent_id,timestamp,fork_date,model,ordinal,has_errors,cumulative_input,cumulative_output,cumulative_cached,cumulative_reasoning,cumulative_total,last_input,last_output,last_cached,last_reasoning,last_total"

    func loadRecords(scope: String) throws -> [ClientUsageRecord] {
        try database.query("SELECT \(Self.recordColumns) FROM client_usage_records WHERE scope=? ORDER BY id", [.text(scope)], map: Self.record)
    }
    func loadCheckpoints(scope: String) throws -> [CodexUsageCheckpoint] {
        try database.query("SELECT \(Self.checkpointColumns) FROM client_usage_checkpoints WHERE scope=? ORDER BY id", [.text(scope)], map: Self.checkpoint)
    }

    func writeRecords(_ records: [ClientUsageRecord], previous: [ClientUsageRecord], scope: String) throws {
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let changed = records.filter { old[$0.id] != $0 }
        // 使用真正的 UPDATE 让日汇总同时标记旧日期和新日期。REPLACE 的隐式删除不会
        // 默认触发 SQLite DELETE 触发器，跨日修正可能因此留下旧日期的过时汇总。
        let assignments = Self.recordColumns.split(separator: ",").filter { $0 != "id" }
            .map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        try writeRows("INSERT INTO client_usage_records(scope,\(Self.recordColumns)) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(scope,id) DO UPDATE SET \(assignments)",
                      rows: changed.map { [.text(scope)] + Self.values($0) })
        let retained = Set(records.map(\.id))
        for id in old.keys where !retained.contains(id) {
            try database.execute("DELETE FROM client_usage_records WHERE scope=? AND id=?", [.text(scope), .text(id)])
        }
    }
    func writeCheckpoints(_ checkpoints: [CodexUsageCheckpoint], previous: [CodexUsageCheckpoint], scope: String) throws {
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { $0.merging($1) })
        let changed = checkpoints.filter { old[$0.id] != $0 }
        try writeRows("INSERT OR REPLACE INTO client_usage_checkpoints(scope,\(Self.checkpointColumns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                      rows: changed.map { [.text(scope)] + Self.values($0) })
        let retained = Set(checkpoints.map(\.id))
        for id in old.keys where !retained.contains(id) {
            try database.execute("DELETE FROM client_usage_checkpoints WHERE scope=? AND id=?", [.text(scope), .text(id)])
        }
    }

    /// 一批增量复用预编译语句，避免每条事件重复解析 SQL；取消在行边界检查并交由外层事务回滚。
    func writeRows(_ sql: String, rows: [[AnalyticsDatabase.Value]]) throws {
        guard !rows.isEmpty else { return }
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try database.bind(row, to: statement)
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE else { throw AnalyticsDatabase.DatabaseError.sqlite(code, "客户端用量增量写入失败") }
        }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
    }
    static func bool(_ value: Bool) -> AnalyticsDatabase.Value { .integer(value ? 1 : 0) }
    static func integer(_ value: Int) -> AnalyticsDatabase.Value { .integer(Int64(value)) }
    static func optional(_ value: String?) -> AnalyticsDatabase.Value { value.map(AnalyticsDatabase.Value.text) ?? .null }
    static func optional(_ value: Date?) -> AnalyticsDatabase.Value { value.map { .real($0.timeIntervalSince1970) } ?? .null }

    static func record(_ statement: OpaquePointer) throws -> ClientUsageRecord {
        guard let source = ClientUsageSource(rawValue: text(statement, 1)) else { throw ClientUsageEngine.ArchiveError.invalidArchive }
        return ClientUsageRecord(hashedID: text(statement, 0), source: source,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), model: text(statement, 3),
            input: Int(sqlite3_column_int64(statement, 4)), output: Int(sqlite3_column_int64(statement, 5)),
            cached: Int(sqlite3_column_int64(statement, 6)), reasoning: Int(sqlite3_column_int64(statement, 7)),
            total: Int(sqlite3_column_int64(statement, 8)), hasReasoningBreakdown: sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 9) != 0)
    }
    static func values(_ record: ClientUsageRecord) -> [AnalyticsDatabase.Value] {
        [.text(record.id), .text(record.source.rawValue), .real(record.timestamp.timeIntervalSince1970), .text(record.model),
         integer(record.input), integer(record.output), integer(record.cached), integer(record.reasoning), integer(record.total),
         record.hasReasoningBreakdown.map(bool) ?? .null]
    }
    static func checkpoint(_ statement: OpaquePointer) -> CodexUsageCheckpoint {
        func tokens(_ column: Int32) -> CodexUsageCheckpoint.Tokens? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            return .init(input: Int(sqlite3_column_int64(statement, column)), output: Int(sqlite3_column_int64(statement, column + 1)),
                         cached: Int(sqlite3_column_int64(statement, column + 2)), reasoning: Int(sqlite3_column_int64(statement, column + 3)),
                         total: Int(sqlite3_column_int64(statement, column + 4)))
        }
        return CodexUsageCheckpoint(id: text(statement, 0), sessionID: text(statement, 1), parentSessionID: optionalText(statement, 2),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            forkDate: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            model: text(statement, 5), cumulative: tokens(8), last: tokens(13), ordinal: Int(sqlite3_column_int64(statement, 6)),
            hasErrors: sqlite3_column_int(statement, 7) != 0)
    }
    static func values(_ checkpoint: CodexUsageCheckpoint) -> [AnalyticsDatabase.Value] {
        func tokens(_ value: CodexUsageCheckpoint.Tokens?) -> [AnalyticsDatabase.Value] {
            guard let value else { return Array(repeating: .null, count: 5) }
            return [value.input, value.output, value.cached, value.reasoning, value.total].map(integer)
        }
        return [.text(checkpoint.id), .text(checkpoint.sessionID), optional(checkpoint.parentSessionID),
                .real(checkpoint.timestamp.timeIntervalSince1970), optional(checkpoint.forkDate), .text(checkpoint.model),
                integer(checkpoint.ordinal), bool(checkpoint.hasErrors)] + tokens(checkpoint.cumulative) + tokens(checkpoint.last)
    }
}
