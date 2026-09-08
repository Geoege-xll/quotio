import Foundation
import SQLite3
import Darwin

/// SQLite 连接仅由 UsageLedger actor 调用，不跨线程共享句柄，也不创建第二个 CPA 消费者。
/// 请求明细长期保存；查询在数据库侧筛选和聚合，UI 只接收当前页，避免全量历史常驻内存。
nonisolated final class CPAUsageEventStore {
    enum StoreError: Error { case unavailable, queryFailed, malformedRecord }
    private let sql: AnalyticsDatabase
    private var database: OpaquePointer?
    private var schemaReady = false
    private enum Value {
        case text(String), number(Double), integer(Int), blob(Data), null
        /// 保留查询层现有 Int 接口，实际绑定统一交给共享数据库基础设施。
        var databaseValue: AnalyticsDatabase.Value {
            switch self {
            case .text(let value): .text(value)
            case .number(let value): .real(value)
            case .integer(let value): .integer(Int64(value))
            case .blob(let value): .blob(value)
            case .null: .null
            }
        }
    }

    init(url: URL) { sql = AnalyticsDatabase(url: url) }

    private func openDatabase() throws {
        guard !schemaReady else { return }
        database = try sql.connection()
        try sql.transaction {
            try execute("""
                CREATE TABLE IF NOT EXISTS cpa_events (
                    id TEXT PRIMARY KEY, ts REAL NOT NULL, provider TEXT COLLATE NOCASE NOT NULL,
                    model TEXT COLLATE NOCASE NOT NULL, source_id TEXT, key_id TEXT, key_label TEXT,
                    outcome TEXT NOT NULL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
                    reasoning_tokens INTEGER NOT NULL, cached_tokens INTEGER NOT NULL,
                    cache_read INTEGER, cache_write INTEGER, total_tokens INTEGER NOT NULL,
                    latency REAL, ttft REAL, generation_tokens REAL, generation_ms REAL, payload BLOB NOT NULL,
                    ledger_day REAL
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS cpa_events_time ON cpa_events(ts DESC, id)")
            try execute("CREATE INDEX IF NOT EXISTS cpa_events_provider_model ON cpa_events(provider, model, ts)")
            try execute("CREATE INDEX IF NOT EXISTS cpa_events_source ON cpa_events(source_id, ts)")
            try execute("CREATE INDEX IF NOT EXISTS cpa_events_key ON cpa_events(key_id, ts)")
            try execute("CREATE INDEX IF NOT EXISTS cpa_events_ledger_day ON cpa_events(provider, model, ledger_day)")
            try execute("CREATE TABLE IF NOT EXISTS cpa_metadata (key TEXT PRIMARY KEY, value REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS cpa_legacy_dedup_ids (id TEXT PRIMARY KEY)")
            try execute("""
                CREATE TABLE IF NOT EXISTS cpa_model_prices (
                    model TEXT COLLATE NOCASE PRIMARY KEY, input REAL NOT NULL, output REAL NOT NULL,
                    cache_read REAL, cache_write REAL
                )
                """)
            // 每个日桶独立成行；历史基线和可重建汇总分表，不能将整份旧 JSON 当成 BLOB 保存。
            for table in ["cpa_daily_buckets", "cpa_historical_buckets"] {
                try execute("""
                    CREATE TABLE IF NOT EXISTS \(table) (
                        id TEXT PRIMARY KEY, day REAL NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
                        requests INTEGER NOT NULL, failures INTEGER NOT NULL, input_tokens INTEGER NOT NULL,
                        output_tokens INTEGER NOT NULL, cached_tokens INTEGER NOT NULL, reasoning_tokens INTEGER NOT NULL,
                        total_tokens INTEGER NOT NULL, latency_total REAL NOT NULL, latency_samples INTEGER NOT NULL
                    )
                    """)
            }
        }
        schemaReady = true
    }

    /// 事件、日桶和采集水位在同一事务内提交，失败时全部回滚；没有 JSON 待同步区。
    /// 返回本批实际变化的日桶，调用方只替换这些行，空心跳不重新加载全年汇总。
    @discardableResult
    func ingest(_ events: [CPAUsageEvent], collectedAt: Date, calendar: Calendar = .current) throws -> [UsageBucket] {
        try openDatabase()
        // CPA 每两秒轮询一次，空心跳只需更新调用方的内存采集时间。
        // 首次及每分钟保留持久化检查点，避免共享 WAL 在空闲时仍持续写盘和同步。
        if events.isEmpty, let last = try metadataDate("last_collected"),
           collectedAt.timeIntervalSince(last) < 60 { return [] }
        return try sql.transaction {
            var changed = Set<String>()
            let statement = try prepare(Self.insertEventSQL)
            defer { sqlite3_finalize(statement) }
            for event in events {
                try Task.checkCancellation()
                // 旧日账本的去重哈希没有对应明细时，仍需拒绝已经被历史基线覆盖的重放。
                if try sql.scalarInt("SELECT 1 FROM cpa_legacy_dedup_ids WHERE id=?", [.text(event.id)]) != nil { continue }
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                let day = event.ledgerDay ?? calendar.startOfDay(for: event.timestamp)
                try bind(eventValues(event, day: day), to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.queryFailed }
                guard sql.changes > 0 else { continue }
                var delta = UsageBucket(day: day, provider: event.provider, model: event.model)
                delta.requests = 1; delta.failures = event.outcome == .success ? 0 : 1
                delta.inputTokens = event.tokens.input; delta.outputTokens = event.tokens.output
                delta.cachedTokens = event.tokens.cached; delta.reasoningTokens = event.tokens.reasoning
                delta.totalTokens = event.tokens.total
                delta.latencyTotal = event.latency ?? 0; delta.latencySamples = event.latency == nil ? 0 : 1
                try addBucket(delta, table: "cpa_daily_buckets")
                changed.insert(delta.id)
            }
            try execute("INSERT OR IGNORE INTO cpa_metadata(key,value) VALUES('collection_started',?)", [.number(collectedAt.timeIntervalSince1970)])
            try execute("""
                INSERT INTO cpa_metadata(key,value) VALUES('last_collected',?)
                ON CONFLICT(key) DO UPDATE SET value=MAX(value,excluded.value)
                """, [.number(collectedAt.timeIntervalSince1970)])
            return try changed.sorted().flatMap { id in
                try readBuckets(table: "cpa_daily_buckets", matching: id)
            }
        }
    }

    private static let insertEventSQL = """
        INSERT OR IGNORE INTO cpa_events
        (id,ts,provider,model,source_id,key_id,key_label,outcome,input_tokens,output_tokens,
         reasoning_tokens,cached_tokens,cache_read,cache_write,total_tokens,latency,ttft,
         generation_tokens,generation_ms,payload,ledger_day)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """

    private func eventValues(_ event: CPAUsageEvent, day: Date?) throws -> [Value] {
        let duration = event.generationMilliseconds
        return [
            .text(event.id), .number(event.timestamp.timeIntervalSince1970), .text(event.provider), .text(event.model),
            event.context.sourceID.map(Value.text) ?? .null,
            event.context.apiKeyID.map(Value.text) ?? .null,
            event.context.apiKeyLabel.map(Value.text) ?? .null,
            .text(event.outcome.rawValue), .integer(event.tokens.input), .integer(event.tokens.output),
            .integer(event.tokens.reasoning), .integer(event.tokens.cached),
            event.context.cacheRead.map(Value.integer) ?? .null,
            event.context.cacheWrite.map(Value.integer) ?? .null,
            .integer(event.tokens.total), event.latency.map(Value.number) ?? .null,
            event.context.ttft.map(Value.number) ?? .null,
            duration.map { _ in Value.number(Double(event.tokens.output)) } ?? .null,
            duration.map(Value.number) ?? .null, .blob(try JSONEncoder().encode(event)),
            day.map { .number($0.timeIntervalSince1970) } ?? .null
        ]
    }

    /// 旧 JSON 和旧明细库只在此入口读取一次，迁移标记与所有导入行一起提交。
    /// 不删除或改写旧文件；迁移成功后它们只是备份，后续查询不再依赖它们。
    func migrateLegacyStorage(ledgerURL: URL?, eventURL: URL?, calendar: Calendar) throws {
        try openDatabase()
        let migration = "cpa-unified-storage-v1"
        guard try !sql.hasMigration(migration) else { return }
        var legacy: UsageLedgerSnapshot?
        if let ledgerURL {
            try AnalyticsDatabase.validate(ledgerURL)
            if FileManager.default.fileExists(atPath: ledgerURL.path) {
                let value = try JSONDecoder().decode(UsageLedgerSnapshot.self, from: Data(contentsOf: ledgerURL))
                guard value.version == 1 else { throw UsageLedger.LedgerError.unsupportedVersion }
                legacy = value
            }
        }
        try sql.transaction {
            // 多个实例首次恢复时可能已在等待写锁期间被另一连接迁移，锁内再次检查。
            guard try !sql.hasMigration(migration) else { return }
            if let eventURL { try importLegacyDatabase(eventURL) }
            if let legacy {
                // 待同步区里的 UUID 在旧 JSON 提交时已经固定，先按 ID 补齐事件再扣减历史。
                // 不能先导入旧去重窗口，否则其中的哈希会阻止这批有效明细被恢复。
                for event in legacy.pendingEvents ?? [] {
                    try execute(Self.insertEventSQL, eventValues(event, day: event.ledgerDay))
                }
                let history = try unindexedBuckets(legacy.buckets, calendar: calendar)
                for bucket in history { try addBucket(bucket, table: "cpa_historical_buckets") }
                for id in legacy.recentRecordIDs {
                    try execute("INSERT OR IGNORE INTO cpa_legacy_dedup_ids(id) VALUES(?)", [.text(id)])
                }
                if let first = legacy.firstCollectedAt { try mergeMetadata("collection_started", date: first, earliest: true) }
                if let last = legacy.lastCollectedAt {
                    try mergeMetadata("last_collected", date: last, earliest: false)
                    try execute("INSERT OR REPLACE INTO cpa_metadata(key,value) VALUES('history_collected',?)", [.number(last.timeIntervalSince1970)])
                }
            }
            // 旧 JSON 未覆盖的索引事件也必须进入日汇总。已有归属保持原值，只有确实缺失的
            // 旧行按当前注入日历补齐；不能把所有事件重新按启动时区分桶。
            let missing = try sql.query("SELECT id,ts FROM cpa_events WHERE ledger_day IS NULL") { statement in
                (String(cString: sqlite3_column_text(statement, 0)), sqlite3_column_double(statement, 1))
            }
            for (id, timestamp) in missing {
                let day = calendar.startOfDay(for: Date(timeIntervalSince1970: timestamp))
                try execute("UPDATE cpa_events SET ledger_day=? WHERE id=?", [.number(day.timeIntervalSince1970), .text(id)])
            }
            try execute("DELETE FROM cpa_daily_buckets")
            for bucket in try readBuckets(table: "cpa_historical_buckets") { try addBucket(bucket, table: "cpa_daily_buckets") }
            let grouped = try sql.query("""
                SELECT ledger_day,provider,model,COUNT(*),SUM(outcome!='success'),SUM(input_tokens),SUM(output_tokens),
                       SUM(cached_tokens),SUM(reasoning_tokens),SUM(total_tokens),COALESCE(SUM(latency),0),COUNT(latency)
                FROM cpa_events GROUP BY ledger_day,provider COLLATE BINARY,model COLLATE BINARY
                """) { statement in
                    self.bucket(statement, startColumn: 0)
                }
            for bucket in grouped { try addBucket(bucket, table: "cpa_daily_buckets") }
            // 只有旧 SQL、没有旧日账本的安装，也应恢复“已采集”状态；旧库缺元数据时
            // 只回退到已有事件时间边界，不虚构明细或用迁移当天冒充历史采集日期。
            if try metadataDate("collection_started") == nil {
                let boundaries = try sql.query("SELECT MIN(ts),MAX(ts) FROM cpa_events HAVING COUNT(*)>0") {
                    (Date(timeIntervalSince1970: sqlite3_column_double($0, 0)),
                     Date(timeIntervalSince1970: sqlite3_column_double($0, 1)))
                }
                if let (first, last) = boundaries.first {
                    try mergeMetadata("collection_started", date: first, earliest: true)
                    try mergeMetadata("last_collected", date: last, earliest: false)
                }
            }
            if try metadataDate("last_collected") == nil {
                // 旧库可能只保存 collection_started，仍须优先采用最新已有事件时间，
                // 不能把多日历史的“最后采集”回退到首次启动时刻。
                if let latest = try sql.query("SELECT MAX(ts) FROM cpa_events HAVING COUNT(*)>0", map: {
                    Date(timeIntervalSince1970: sqlite3_column_double($0, 0))
                }).first {
                    try mergeMetadata("last_collected", date: latest, earliest: false)
                } else if let first = try metadataDate("collection_started") {
                    try mergeMetadata("last_collected", date: first, earliest: false)
                }
            }
            try sql.markMigration(migration)
        }
    }

    func ledgerSnapshot() throws -> UsageLedgerSnapshot {
        try openDatabase()
        var snapshot = UsageLedgerSnapshot()
        snapshot.buckets = try readBuckets(table: "cpa_daily_buckets")
        snapshot.firstCollectedAt = try metadataDate("collection_started")
        snapshot.lastCollectedAt = try metadataDate("last_collected")
        // 旧去重集合由数据库查询，不再复制到每次发布的 UI 快照。
        return snapshot
    }

    func historicalSnapshot() throws -> (buckets: [UsageBucket], collectedAt: Date?) {
        try openDatabase()
        return (try readBuckets(table: "cpa_historical_buckets"), try metadataDate("history_collected"))
    }

    private func metadataDate(_ key: String) throws -> Date? {
        try sql.query("SELECT value FROM cpa_metadata WHERE key=?", [.text(key)]) {
            Date(timeIntervalSince1970: sqlite3_column_double($0, 0))
        }.first
    }

    private func mergeMetadata(_ key: String, date: Date, earliest: Bool) throws {
        let function = earliest ? "MIN" : "MAX"
        try execute("INSERT INTO cpa_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=\(function)(value,excluded.value)",
                    [.text(key), .number(date.timeIntervalSince1970)])
    }

    /// 日桶使用确定的复合身份，数值列可直接累加；表名只来自本文件常量，不接受用户输入。
    private func addBucket(_ value: UsageBucket, table: String) throws {
        try execute("""
            INSERT INTO \(table)(id,day,provider,model,requests,failures,input_tokens,output_tokens,cached_tokens,
                                reasoning_tokens,total_tokens,latency_total,latency_samples)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                requests=requests+excluded.requests, failures=failures+excluded.failures,
                input_tokens=input_tokens+excluded.input_tokens, output_tokens=output_tokens+excluded.output_tokens,
                cached_tokens=cached_tokens+excluded.cached_tokens, reasoning_tokens=reasoning_tokens+excluded.reasoning_tokens,
                total_tokens=total_tokens+excluded.total_tokens, latency_total=latency_total+excluded.latency_total,
                latency_samples=latency_samples+excluded.latency_samples
            """, [.text(value.id), .number(value.day.timeIntervalSince1970), .text(value.provider), .text(value.model),
                  .integer(value.requests), .integer(value.failures), .integer(value.inputTokens), .integer(value.outputTokens),
                  .integer(value.cachedTokens), .integer(value.reasoningTokens), .integer(value.totalTokens),
                  .number(value.latencyTotal), .integer(value.latencySamples)])
    }

    private func readBuckets(table: String, matching id: String? = nil) throws -> [UsageBucket] {
        let suffix = id == nil ? " ORDER BY id" : " WHERE id=?"
        return try sql.query("""
            SELECT day,provider,model,requests,failures,input_tokens,output_tokens,cached_tokens,
                   reasoning_tokens,total_tokens,latency_total,latency_samples FROM \(table)
            """ + suffix, id.map { [.text($0)] } ?? []) { self.bucket($0, startColumn: 0) }
    }

    private func bucket(_ statement: OpaquePointer, startColumn: Int32) -> UsageBucket {
        func count(_ offset: Int32) -> Int { Int(sqlite3_column_int64(statement, startColumn + offset)) }
        var value = UsageBucket(day: Date(timeIntervalSince1970: sqlite3_column_double(statement, startColumn)),
                                provider: text(statement, column: startColumn + 1) ?? "",
                                model: text(statement, column: startColumn + 2) ?? "")
        value.requests = count(3); value.failures = count(4)
        value.inputTokens = count(5); value.outputTokens = count(6)
        value.cachedTokens = count(7); value.reasoningTokens = count(8); value.totalTokens = count(9)
        value.latencyTotal = sqlite3_column_double(statement, startColumn + 10); value.latencySamples = count(11)
        return value
    }

    /// 旧 SQLite 以 READONLY + NOFOLLOW 打开，不升级其 schema、不修改其日志模式。
    /// 逐行绑定迁移既保留数值列和价格，也避免一次解码全部历史事件 payload。
    private func importLegacyDatabase(_ url: URL) throws {
        try AnalyticsDatabase.validate(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let physical = realpath(url.path, nil) else { throw StoreError.unavailable }
        defer { free(physical) }
        var old: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let result = sqlite3_open_v2(physical, &old, flags, nil)
        guard result == SQLITE_OK, let old else {
            if let old { sqlite3_close(old) }
            throw StoreError.queryFailed
        }
        defer { sqlite3_close(old) }
        sqlite3_busy_timeout(old, 5_000)
        guard sqlite3_exec(old, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw StoreError.queryFailed }
        defer { sqlite3_exec(old, "ROLLBACK", nil, nil, nil) }
        func rows(_ query: String, visit: (OpaquePointer) throws -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(old, query, -1, &statement, nil) == SQLITE_OK, let statement else { throw StoreError.queryFailed }
            defer { sqlite3_finalize(statement) }
            while true {
                try Task.checkCancellation()
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW else { throw StoreError.queryFailed }
                try visit(statement)
            }
        }
        var tables = Set<String>()
        try rows("SELECT name FROM sqlite_master WHERE type='table'") { row in
            if let name = text(row, column: 0) { tables.insert(name) }
        }
        if tables.contains("events") {
            var columns = Set<String>()
            try rows("PRAGMA table_info(events)") { row in
                if let name = text(row, column: 1) { columns.insert(name) }
            }
            let day = columns.contains("ledger_day") ? "ledger_day" : "NULL"
            let insertion = try prepare(Self.insertEventSQL)
            defer { sqlite3_finalize(insertion) }
            try rows("""
                SELECT id,ts,provider,model,source_id,key_id,key_label,outcome,input_tokens,output_tokens,
                       reasoning_tokens,cached_tokens,cache_read,cache_write,total_tokens,latency,ttft,
                       generation_tokens,generation_ms,payload,\(day) FROM events
                """) { row in
                    var values: [Value] = []
                    for column: Int32 in 0..<21 {
                        switch sqlite3_column_type(row, column) {
                        case SQLITE_INTEGER: values.append(.integer(Int(sqlite3_column_int64(row, column))))
                        case SQLITE_FLOAT: values.append(.number(sqlite3_column_double(row, column)))
                        case SQLITE_TEXT: values.append(.text(text(row, column: column) ?? ""))
                        case SQLITE_BLOB:
                            let count = Int(sqlite3_column_bytes(row, column))
                            guard count > 0, let bytes = sqlite3_column_blob(row, column) else { throw StoreError.malformedRecord }
                            values.append(.blob(Data(bytes: bytes, count: count)))
                        default: values.append(.null)
                        }
                    }
                    sqlite3_reset(insertion); sqlite3_clear_bindings(insertion)
                    try bind(values, to: insertion)
                    guard sqlite3_step(insertion) == SQLITE_DONE else { throw StoreError.queryFailed }
                }
        }
        if tables.contains("model_prices") {
            try rows("SELECT model,input,output,cache_read,cache_write FROM model_prices") { row in
                func number(_ column: Int32) -> Value {
                    sqlite3_column_type(row, column) == SQLITE_NULL ? .null : .number(sqlite3_column_double(row, column))
                }
                try execute("INSERT OR IGNORE INTO cpa_model_prices(model,input,output,cache_read,cache_write) VALUES(?,?,?,?,?)",
                            [.text(text(row, column: 0) ?? ""), number(1), number(2), number(3), number(4)])
            }
        }
        if tables.contains("metadata") {
            try rows("SELECT value FROM metadata WHERE key='collection_started'") { row in
                let date = Date(timeIntervalSince1970: sqlite3_column_double(row, 0))
                try mergeMetadata("collection_started", date: date, earliest: true)
            }
        }
    }

    func query(_ query: CPAUsageQuery, includeEvents: Bool = true) throws -> CPAUsageEventPage {
        try openDatabase()
        try Task.checkCancellation()
        // 长查询可被 SwiftUI task 取消，避免用户快速切换筛选后旧查询持续占用采集 actor。
        sqlite3_progress_handler(database, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        let filter = filters(query, timeOnly: false)
        let metricsSQL = """
            SELECT COUNT(*),
                COALESCE(SUM(outcome='success'),0), COALESCE(SUM(outcome='failed'),0), COALESCE(SUM(outcome='canceled'),0),
                COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(reasoning_tokens),0),
                COALESCE(SUM(cached_tokens),0), COALESCE(SUM(total_tokens),0),
                COALESCE(SUM(cache_read),0), COUNT(cache_read), COALESCE(SUM(cache_write),0), COUNT(cache_write),
                COALESCE(SUM(latency),0), COUNT(latency), COALESCE(SUM(ttft),0), COUNT(ttft),
                COALESCE(SUM(generation_tokens),0), COALESCE(SUM(generation_ms),0), COUNT(generation_ms), MIN(ts), MAX(ts)
            FROM cpa_events
            """ + filter.sql
        let summary = try prepare(metricsSQL)
        defer { sqlite3_finalize(summary) }
        try bind(filter.values, to: summary)
        guard sqlite3_step(summary) == SQLITE_ROW else { throw StoreError.queryFailed }
        func integer(_ column: Int32) -> Int { Int(sqlite3_column_int64(summary, column)) }
        func number(_ column: Int32) -> Double { sqlite3_column_double(summary, column) }
        var metrics = CPAUsageEventMetrics()
        metrics.requests = integer(0); metrics.successes = integer(1); metrics.failures = integer(2); metrics.canceled = integer(3)
        metrics.input = integer(4); metrics.output = integer(5); metrics.reasoning = integer(6); metrics.cached = integer(7)
        metrics.tokens = integer(8); metrics.cacheRead = integer(9); metrics.cacheReadSamples = integer(10)
        metrics.cacheWrite = integer(11); metrics.cacheWriteSamples = integer(12)
        metrics.latencyTotal = number(13); metrics.latencySamples = integer(14)
        metrics.ttftTotal = number(15); metrics.ttftSamples = integer(16)
        metrics.generationTokens = number(17); metrics.generationMilliseconds = number(18); metrics.generationSamples = integer(19)
        // 起止边界分别回退到首末事件，兼容仅指定起点或终点的查询，与上游窗口公式一致。
        let start = query.start?.timeIntervalSince1970 ?? number(20)
        let end = query.end?.timeIntervalSince1970 ?? (metrics.requests > 0 ? number(21) : start)
        metrics.minutes = max(1, (end - start) / 60)

        let size = min(200, max(1, query.pageSize))
        let pages = max(1, metrics.requests / size + (metrics.requests % size == 0 ? 0 : 1))
        let page = min(pages, max(1, query.page))
        // 总览和价格页只需要聚合，不解码请求正文投影；LIMIT 0 保持同一筛选与指标实现。
        let statement = try prepare("SELECT payload FROM cpa_events" + filter.sql + " ORDER BY ts DESC,id DESC LIMIT ? OFFSET ?")
        defer { sqlite3_finalize(statement) }
        try bind(filter.values + [.integer(includeEvents ? size : 0), .integer((page - 1) * size)], to: statement)
        var events: [CPAUsageEvent] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw StoreError.queryFailed }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { throw StoreError.malformedRecord }
            events.append(try JSONDecoder().decode(CPAUsageEvent.self, from: Data(bytes: bytes, count: count)))
        }
        // 选项只受时间范围影响，与上游一致；选择某模型后不会让其他可切换选项消失。
        let providers = try options(column: "provider", query: query)
        let models = try options(column: "model", query: query)
        let sources = try options(column: "source_id", query: query)
        let keys = try options(column: "key_id", query: query)
        let metadata = try prepare("SELECT value FROM cpa_metadata WHERE key='collection_started'")
        defer { sqlite3_finalize(metadata) }
        let collected: Date?
        let metadataResult = sqlite3_step(metadata)
        if metadataResult == SQLITE_ROW { collected = Date(timeIntervalSince1970: sqlite3_column_double(metadata, 0)) }
        else if metadataResult == SQLITE_DONE { collected = nil }
        else { throw StoreError.queryFailed }
        // 只探测是否存在首行，不为区分空态执行一次全库 COUNT；与当前筛选结果分开。
        let hasStoredEvents = try sql.scalarInt("SELECT EXISTS(SELECT 1 FROM cpa_events LIMIT 1)") == 1
        return CPAUsageEventPage(events: events, metrics: metrics, providers: providers, models: models, sources: sources,
                                 apiKeys: keys, page: page, pageSize: size, totalPages: pages,
                                 collectionStartedAt: collected, hasStoredEvents: hasStoredEvents)
    }

    /// Sheet 打开时只查询全时间可选目录，不运行请求指标聚合，也不解码任何事件 payload。
    /// 与 query 中仍受当前时间窗约束的选项分开，草稿编辑不会改变已应用统计口径。
    func filterOptions() throws -> CPAUsageFilterOptions {
        try openDatabase()
        try Task.checkCancellation()
        sqlite3_progress_handler(database, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        let all = CPAUsageQuery()
        return try CPAUsageFilterOptions(providers: options(column: "provider", query: all),
            models: options(column: "model", query: all), sources: options(column: "source_id", query: all),
            apiKeys: options(column: "key_id", query: all))
    }

    private func options(column: String, query: CPAUsageQuery) throws -> [CPAUsageOption] {
        // column 只来自上述四个静态调用点，用户选择值全部通过参数绑定，不能拼接为 SQL。
        let filter = filters(query, timeOnly: true)
        let label = column == "key_id" ? ",MAX(key_label)" : ",NULL"
        let statement = try prepare("SELECT " + column + label + " FROM cpa_events" + filter.sql + " GROUP BY " + column + " ORDER BY " + column + " COLLATE NOCASE")
        defer { sqlite3_finalize(statement) }
        try bind(filter.values, to: statement)
        var values: [CPAUsageOption] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw StoreError.queryFailed }
            guard let value = text(statement, column: 0), !value.isEmpty else { continue }
            let title: String
            if column == "source_id" { title = "#" + value.prefix(12) }
            else if column == "key_id" { title = (text(statement, column: 1) ?? "Key") + " · #" + value.prefix(8) }
            else { title = value }
            values.append(CPAUsageOption(id: value, title: title))
        }
        return values
    }

    private func filters(_ query: CPAUsageQuery, timeOnly: Bool) -> (sql: String, values: [Value]) {
        var clauses: [String] = []
        var values: [Value] = []
        if let start = query.start { clauses.append("ts >= ?"); values.append(.number(start.timeIntervalSince1970)) }
        if let end = query.end { clauses.append("ts <= ?"); values.append(.number(end.timeIntervalSince1970)) }
        if !timeOnly {
            for (column, value) in [("provider", query.provider), ("model", query.model), ("source_id", query.source), ("key_id", query.apiKey)] where !value.isEmpty {
                if value == "__unknown__" {
                    clauses.append((column == "source_id" || column == "key_id") ? column + " IS NULL" : column + " = ''")
                }
                else { clauses.append(column + " = ? COLLATE NOCASE"); values.append(.text(value)) }
            }
            if query.outcome != .all { clauses.append("outcome = ?"); values.append(.text(query.outcome.rawValue)) }
        }
        return (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND "), values)
    }

    /// 一次 actor 调用完成同条件总览、趋势与当前分布维度；只返回有界图形数据。
    func dashboard(_ query: CPAUsageQuery, dimension: CPAUsageDimension,
                   metric: CPAUsageChartMetric, limit: Int, includesHistory: Bool = false) throws -> CPAUsageDashboardReport {
        let summary = try self.query(query, includeEvents: false)
        sqlite3_progress_handler(database, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        let filter = filters(query, timeOnly: false)
        let hourly = !includesHistory && (query.start.flatMap { start in query.end.map { $0.timeIntervalSince(start) <= 2 * 86400 } } ?? false)
        // 小时按绝对时间分桶以区分夏令时重复小时；日桶按本机日历日期对齐。
        let bucket = hourly ? "CAST(ts / 3600 AS INTEGER) * 3600"
            : "CAST(strftime('%s', date(ts,'unixepoch','localtime'),'utc') AS REAL)"
        let trendStatement = try prepare("SELECT " + bucket + ",COUNT(*),COALESCE(SUM(total_tokens),0) FROM cpa_events" + filter.sql + " GROUP BY 1 ORDER BY 1")
        defer { sqlite3_finalize(trendStatement) }
        try bind(filter.values, to: trendStatement)
        var points: [CPAUsageTrendPoint] = []
        while true {
            let result = sqlite3_step(trendStatement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw StoreError.queryFailed }
            points.append(CPAUsageTrendPoint(date: Date(timeIntervalSince1970: sqlite3_column_double(trendStatement, 0)),
                requests: Int(sqlite3_column_int64(trendStatement, 1)), tokens: Int(sqlite3_column_int64(trendStatement, 2))))
        }
        // 短范围补齐零点，不能把无请求时间段误画成持续流量；超长历史限制到 240 个绘制点。
        if let start = query.start, let end = query.end, end.timeIntervalSince(start) <= 366 * 86400 {
            let calendar = Calendar.current
            var date = hourly ? Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / 3600) * 3600)
                : calendar.startOfDay(for: start)
            let existing = Dictionary(uniqueKeysWithValues: points.map { ($0.date, $0) })
            var filled: [CPAUsageTrendPoint] = []
            while date <= end && filled.count < 2_000 {
                filled.append(existing[date] ?? CPAUsageTrendPoint(date: date, requests: 0, tokens: 0))
                guard let next = calendar.date(byAdding: hourly ? .hour : .day, value: 1, to: date), next > date else { break }
                date = next
            }
            points = filled
        }
        if points.count > 240 && !includesHistory {
            let stride = (points.count + 239) / 240
            var reduced: [CPAUsageTrendPoint] = []
            for offset in Swift.stride(from: 0, to: points.count, by: stride) {
                let slice = points[offset..<min(points.count, offset + stride)]
                reduced.append(CPAUsageTrendPoint(date: points[offset].date,
                    requests: slice.reduce(0) { $0 + $1.requests }, tokens: slice.reduce(0) { $0 + $1.tokens }))
            }
            points = reduced
        }
        let column: String
        switch dimension {
        case .model: column = "model"
        case .provider: column = "provider"
        case .source: column = "source_id"
        case .apiKey: column = "key_id"
        }
        // 模型筛选本身并不隐含提供商条件，上游分析也按模型名称合并所有提供商。
        let provider = "''"
        let group = column
        let order = metric == .tokens ? "SUM(total_tokens)" : "COUNT(*)"
        let boundedLimit = min(1_000, max(8, limit))
        let statement = try prepare("SELECT " + column + "," + provider + ",MAX(key_label),COUNT(*),COALESCE(SUM(total_tokens),0) FROM cpa_events"
            + filter.sql + " GROUP BY " + group + " ORDER BY " + order + " DESC," + group + " LIMIT ?")
        defer { sqlite3_finalize(statement) }
        // 合并日归档时先返回维度聚合行再排序截断，不能漏掉在新事件排行之外的历史大户。
        // 这里仍只读取分类汇总，不解码完整请求历史；最终返回给 UI 的数量维持原上限。
        try bind(filter.values + [.integer(includesHistory ? -1 : boundedLimit + 1)], to: statement)
        var rows: [CPAUsageCategory] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw StoreError.queryFailed }
            let raw = text(statement, column: 0) ?? ""
            let key = raw.isEmpty ? "__unknown__" : raw
            let title: String
            if raw.isEmpty { title = "" }
            else if dimension == .source { title = "#" + raw.prefix(12) }
            else if dimension == .apiKey { title = (text(statement, column: 2) ?? "Key") + " · #" + raw.prefix(8) }
            else { title = raw }
            rows.append(CPAUsageCategory(key: key, title: title, provider: text(statement, column: 1) ?? "",
                requests: Int(sqlite3_column_int64(statement, 3)), tokens: Int(sqlite3_column_int64(statement, 4))))
        }
        return CPAUsageDashboardReport(summary: summary, trend: points, hourly: hourly,
            categories: includesHistory ? rows : Array(rows.prefix(boundedLimit)), hasMoreCategories: rows.count > boundedLimit)
    }

    /// 仅在旧存储迁移时逐桶扣除已导入明细，得到永久历史基线；结果写入独立的数值表。
    /// 不改写用户旧账本，也不把一日的请求伪造为一条事件。
    func unindexedBuckets(_ buckets: [UsageBucket], calendar: Calendar) throws -> [UsageBucket] {
        guard !buckets.isEmpty else { return [] }
        try openDatabase()
        // 旧版事件没有日桶归属。临时集合保证同一事件最多扣减一次，即使不同时区
        // 保存的日桶绝对区间重叠，也不能从两个历史桶中重复减去请求和 Tokens。
        try execute("CREATE TEMP TABLE IF NOT EXISTS history_accounted_events (id TEXT PRIMARY KEY)")
        try execute("DELETE FROM history_accounted_events")
        defer { try? execute("DELETE FROM history_accounted_events") }
        let filter = """
            WHERE provider=? COLLATE BINARY AND model=? COLLATE BINARY
              AND (ledger_day=? OR (ledger_day IS NULL AND ts>=? AND ts<?))
              AND id NOT IN (SELECT id FROM history_accounted_events)
            """
        let statement = try prepare("""
            SELECT COUNT(*),COALESCE(SUM(outcome!='success'),0),
                COALESCE(SUM(input_tokens),0),COALESCE(SUM(output_tokens),0),
                COALESCE(SUM(cached_tokens),0),COALESCE(SUM(reasoning_tokens),0),
                COALESCE(SUM(total_tokens),0),COALESCE(SUM(latency),0),COUNT(latency)
            FROM cpa_events
            """ + " " + filter)
        defer { sqlite3_finalize(statement) }
        var history: [UsageBucket] = []
        for bucket in buckets.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            guard let end = calendar.date(byAdding: .day, value: 1, to: bucket.day) else { continue }
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            let values: [Value] = [.text(bucket.provider), .text(bucket.model), .number(bucket.day.timeIntervalSince1970),
                                   .number(bucket.day.timeIntervalSince1970), .number(end.timeIntervalSince1970)]
            try bind(values, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.queryFailed }
            func count(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
            var remainder = bucket
            remainder.requests = max(0, bucket.requests - count(0))
            // 迁移时把旧事件匹配到的原始日桶保存下来；后续重启改时区也不重新归属。
            // 先更新，再登记已扣减 ID，使原过滤条件仍能选中这批事件。
            try execute("UPDATE cpa_events SET ledger_day=? " + filter,
                        [.number(bucket.day.timeIntervalSince1970)] + values)
            // 即使当前桶已被完全覆盖，也必须登记已扣减 ID，避免继续命中后续重叠桶。
            try execute("INSERT OR IGNORE INTO history_accounted_events SELECT id FROM cpa_events " + filter, values)
            guard remainder.requests > 0 else { continue }
            remainder.failures = max(0, bucket.failures - count(1))
            remainder.inputTokens = max(0, bucket.inputTokens - count(2))
            remainder.outputTokens = max(0, bucket.outputTokens - count(3))
            remainder.cachedTokens = max(0, bucket.cachedTokens - count(4))
            remainder.reasoningTokens = max(0, bucket.reasoningTokens - count(5))
            remainder.totalTokens = max(0, bucket.totalTokens - count(6))
            remainder.latencyTotal = max(0, bucket.latencyTotal - sqlite3_column_double(statement, 7))
            remainder.latencySamples = max(0, bucket.latencySamples - count(8))
            history.append(remainder)
        }
        return history
    }

    /// 采用上游基础公式：非缓存输入、输出、缓存读、缓存写分别计价，推理不再次累加。
    /// 缺缓存拆分或对应单价的请求不计入已估算覆盖率，价格缺失不等于零费用。
    func pricing(_ query: CPAUsageQuery) throws -> CPAUsagePricingReport {
        let summary = try self.query(query, includeEvents: false)
        sqlite3_progress_handler(database, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        let filter = filters(query, timeOnly: false)
        let read = "COALESCE(e.cache_read,0)"
        let write = "COALESCE(e.cache_write,0)"
        let eligible = "p.model IS NOT NULL AND (e.cached_tokens=0 OR (e.cache_read IS NOT NULL AND e.cache_write IS NOT NULL)) AND (" + read + "=0 OR p.cache_read IS NOT NULL) AND (" + write + "=0 OR p.cache_write IS NOT NULL)"
        let cost = "(MAX(0,e.input_tokens-" + read + "-" + write + ")*p.input+e.output_tokens*p.output+" + read + "*COALESCE(p.cache_read,0)+" + write + "*COALESCE(p.cache_write,0))/1000000.0"
        // 筛选先在事件子查询执行，避免 model 字段与价格目录发生列名歧义。
        let statement = try prepare("""
            SELECT e.model,COUNT(*),COALESCE(SUM(e.total_tokens),0),
                SUM(CASE WHEN \(eligible) THEN 1 ELSE 0 END),
                SUM(CASE WHEN \(eligible) THEN \(cost) ELSE NULL END),
                p.input,p.output,p.cache_read,p.cache_write
            FROM (SELECT * FROM cpa_events\(filter.sql)) e
            LEFT JOIN cpa_model_prices p ON e.model=p.model COLLATE NOCASE
            GROUP BY e.model ORDER BY SUM(e.total_tokens) DESC,e.model
            """)
        defer { sqlite3_finalize(statement) }
        try bind(filter.values, to: statement)
        var rows: [CPAUsagePriceRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw StoreError.queryFailed }
            let name = text(statement, column: 0) ?? ""
            func optional(_ column: Int32) -> Double? {
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
            }
            let price = optional(5).map { CPAModelPrice(model: name, input: $0, output: sqlite3_column_double(statement, 6),
                                                       cacheRead: optional(7), cacheWrite: optional(8)) }
            rows.append(CPAUsagePriceRow(model: name, requests: Int(sqlite3_column_int64(statement, 1)),
                tokens: Int(sqlite3_column_int64(statement, 2)), pricedRequests: Int(sqlite3_column_int64(statement, 3)),
                estimatedCost: optional(4), price: price,
                hasPartialEstimate: sqlite3_column_int64(statement, 3) < sqlite3_column_int64(statement, 1)))
        }
        return CPAUsagePricingReport(summary: summary, rows: rows)
    }

    /// 历史模型可能没有任何事件行，因此不能只从事件 JOIN 的结果查找价格。
    /// 目录只包含小规模用户配置，按列读取并在 actor 内用于历史汇总估算。
    func modelPrices() throws -> [CPAModelPrice] {
        try openDatabase()
        return try sql.query("SELECT model,input,output,cache_read,cache_write FROM cpa_model_prices ORDER BY model") { row in
            func optional(_ column: Int32) -> Double? {
                sqlite3_column_type(row, column) == SQLITE_NULL ? nil : sqlite3_column_double(row, column)
            }
            return CPAModelPrice(model: self.text(row, column: 0) ?? "",
                input: sqlite3_column_double(row, 1), output: sqlite3_column_double(row, 2),
                cacheRead: optional(3), cacheWrite: optional(4))
        }
    }

    func savePrice(_ price: CPAModelPrice) throws {
        guard price.isValid else { throw StoreError.malformedRecord }
        try openDatabase()
        try execute("INSERT OR REPLACE INTO cpa_model_prices(model,input,output,cache_read,cache_write) VALUES(?,?,?,?,?)",
            [.text(price.model), .number(price.input), .number(price.output),
             price.cacheRead.map(Value.number) ?? .null, price.cacheWrite.map(Value.number) ?? .null])
    }

    private func prepare(_ statement: String) throws -> OpaquePointer {
        try sql.prepare(statement)
    }
    private func execute(_ statement: String, _ values: [Value] = []) throws {
        try sql.execute(statement, values.map(\.databaseValue))
    }
    private func bind(_ values: [Value], to statement: OpaquePointer) throws {
        try sql.bind(values.map(\.databaseValue), to: statement)
    }
    private func text(_ statement: OpaquePointer, column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
