import Foundation
import SQLite3

/// 展示只读取日/来源/模型汇总。日边界由 Foundation Calendar 决定，兼容夏令时、
/// 半小时时区和用户切换系统时区；不能简单用固定 86400 秒或当前时区偏移切分历史。
nonisolated extension ClientUsageSQLiteStore {
    func preparePresentationTables() throws {
        try database.execute("CREATE INDEX IF NOT EXISTS client_usage_records_time ON client_usage_records(scope,timestamp)")
        try database.execute("""
            CREATE TABLE IF NOT EXISTS client_usage_daily_summary (
                day REAL NOT NULL, source TEXT NOT NULL, model TEXT NOT NULL,
                requests INTEGER NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL,
                cached INTEGER NOT NULL, reasoning INTEGER NOT NULL, total INTEGER NOT NULL,
                reasoning_unknown INTEGER NOT NULL, PRIMARY KEY(day,source,model))
            """)
        try database.execute("CREATE TABLE IF NOT EXISTS client_usage_summary_metadata (id TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try database.execute("CREATE TABLE IF NOT EXISTS client_usage_summary_dirty (timestamp REAL PRIMARY KEY)")
        // 外层 UPSERT 的 DO UPDATE 会覆盖触发器中旧式 OR IGNORE 的冲突策略。
        // 队列去重必须使用明确的 ON CONFLICT DO NOTHING，才能重复标记同一自然日而不报唯一键错误。
        for operation in ["insert", "update", "delete"] {
            try database.execute("DROP TRIGGER IF EXISTS client_usage_summary_\(operation)")
        }
        try database.execute("""
            CREATE TRIGGER IF NOT EXISTS client_usage_summary_insert_v2 AFTER INSERT ON client_usage_records
            WHEN NEW.scope='ledger'
            BEGIN INSERT INTO client_usage_summary_dirty VALUES(NEW.timestamp) ON CONFLICT(timestamp) DO NOTHING; END
            """)
        try database.execute("""
            CREATE TRIGGER IF NOT EXISTS client_usage_summary_update_v2 AFTER UPDATE ON client_usage_records
            WHEN NEW.scope='ledger' OR OLD.scope='ledger'
            BEGIN
                INSERT INTO client_usage_summary_dirty SELECT OLD.timestamp WHERE OLD.scope='ledger' ON CONFLICT(timestamp) DO NOTHING;
                INSERT INTO client_usage_summary_dirty SELECT NEW.timestamp WHERE NEW.scope='ledger' ON CONFLICT(timestamp) DO NOTHING;
            END
            """)
        try database.execute("""
            CREATE TRIGGER IF NOT EXISTS client_usage_summary_delete_v2 AFTER DELETE ON client_usage_records
            WHEN OLD.scope='ledger'
            BEGIN INSERT INTO client_usage_summary_dirty VALUES(OLD.timestamp) ON CONFLICT(timestamp) DO NOTHING; END
            """)
    }

    func loadDisplay(calendar: Calendar) throws -> ClientUsageDisplaySnapshot {
        try prepare()
        try database.transaction {
            let key = "\(calendar.identifier)|\(calendar.timeZone.identifier)|\(calendar.locale?.identifier ?? "")|\(calendar.firstWeekday)|\(calendar.minimumDaysInFirstWeek)"
            if try database.scalarText("SELECT value FROM client_usage_summary_metadata WHERE id='calendar'") != key {
                try rebuildPresentation(calendar: calendar)
                try database.execute("INSERT OR REPLACE INTO client_usage_summary_metadata VALUES('calendar',?)", [.text(key)])
            } else {
                // 待更新队列按受影响的自然日消费，一天内有几万个修改也只执行一次 SQL 聚合。
                // 无事件变化时这里为空，切换页面、切换展示筛选均不读取历史事实表。
                while let timestamp = try database.query("SELECT timestamp FROM client_usage_summary_dirty ORDER BY timestamp LIMIT 1", map: {
                    sqlite3_column_double($0, 0)
                }).first {
                    try Task.checkCancellation()
                    let interval = try dayInterval(timestamp, calendar: calendar)
                    try rebuildDay(interval)
                    try database.execute("DELETE FROM client_usage_summary_dirty WHERE timestamp>=? AND timestamp<?",
                        [.real(interval.start.timeIntervalSince1970), .real(interval.end.timeIntervalSince1970)])
                }
            }
        }
        let buckets = try database.query("""
            SELECT day,source,model,requests,input,output,cached,reasoning,total
            FROM client_usage_daily_summary ORDER BY day,source,model
            """) { statement in
                guard let source = ClientUsageSource(rawValue: Self.text(statement, 1)) else {
                    throw ClientUsageEngine.ArchiveError.invalidArchive
                }
                return UsageBucket(day: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    provider: source.title, model: Self.text(statement, 2), requests: Int(sqlite3_column_int64(statement, 3)),
                    inputTokens: Int(sqlite3_column_int64(statement, 4)), outputTokens: Int(sqlite3_column_int64(statement, 5)),
                    cachedTokens: Int(sqlite3_column_int64(statement, 6)), reasoningTokens: Int(sqlite3_column_int64(statement, 7)),
                    totalTokens: Int(sqlite3_column_int64(statement, 8)))
            }.sorted { $0.id < $1.id }
        let unknownDays = try database.query("""
            SELECT day FROM client_usage_daily_summary WHERE source='pi' AND reasoning_unknown>0 GROUP BY day ORDER BY day
            """) { Date(timeIntervalSince1970: sqlite3_column_double($0, 0)) }
        return ClientUsageDisplaySnapshot(metadata: try ledgerMetadata(), buckets: buckets, reasoningUnknownDays: unknownDays)
    }

    /// 首次或用户改变日历时按索引逐日聚合，Swift 每轮仅接收当天的模型汇总。
    /// 跳过没有记录的日期，既不构造全部事件数组，也不会为跨越多年的稀疏账本逐天空查。
    private func rebuildPresentation(calendar: Calendar) throws {
        try database.execute("DELETE FROM client_usage_daily_summary")
        var lowerBound = -Double.greatestFiniteMagnitude
        while let timestamp = try database.query("SELECT MIN(timestamp) FROM client_usage_records WHERE scope='ledger' AND timestamp>=?",
            [.real(lowerBound)], map: { statement -> Double? in
                sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 0)
            }).first ?? nil {
            try Task.checkCancellation()
            let interval = try dayInterval(timestamp, calendar: calendar)
            try rebuildDay(interval)
            lowerBound = interval.end.timeIntervalSince1970
        }
        try database.execute("DELETE FROM client_usage_summary_dirty")
    }

    private func dayInterval(_ timestamp: Double, calendar: Calendar) throws -> DateInterval {
        guard timestamp.isFinite,
              let interval = calendar.dateInterval(of: .day, for: Date(timeIntervalSince1970: timestamp)),
              interval.duration > 0, interval.end.timeIntervalSince1970 > timestamp else {
            throw ClientUsageEngine.ArchiveError.invalidArchive
        }
        return interval
    }

    /// 受影响日直接从事实表重建，降低/删除/模型移动都能自然修正，避免手工累计出现漂移。
    /// 时间范围索引将扫描范围限制在一天；GROUP BY 和 SUM 留在 SQLite，不生成事件对象。
    private func rebuildDay(_ interval: DateInterval) throws {
        let lower = interval.start.timeIntervalSince1970, upper = interval.end.timeIntervalSince1970
        try database.execute("DELETE FROM client_usage_daily_summary WHERE day=?", [.real(lower)])
        try database.execute("""
            INSERT INTO client_usage_daily_summary
            SELECT ?,source,model,COUNT(*),SUM(input),SUM(output),SUM(cached),SUM(reasoning),SUM(total),
                SUM(CASE WHEN source='pi' AND reasoning_known IS NOT 1 THEN 1 ELSE 0 END)
            FROM client_usage_records
            WHERE scope='ledger' AND timestamp>=? AND timestamp<? GROUP BY source,model
            """, [.real(lower), .real(lower), .real(upper)])
    }
}
