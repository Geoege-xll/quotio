// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 保留 AIUsage 日摘要语义；Quotio 使用统一 SQLite 持久化高水位，不再写入独立 JSON 归档。
import Foundation
import SQLite3

/// 只持久化统计列和成功采集指纹，不保存会话正文、工具参数、原始调用 ID 或配置凭据。
/// 连接由 CallAnalyticsEngine actor 独占；JSON 仅作为一次性迁移输入，成功后退出读写流程。
nonisolated final class CallAnalyticsArchiveStore {
    private let legacyURL: URL
    private let database: AnalyticsDatabase
    private var isPrepared = false
    private static let migration = "call_analytics_json_v1"

    init(homeDirectory: String) {
        legacyURL = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support/Quotio/CallAnalytics/summary-v1.json")
        database = AnalyticsDatabase(url: AnalyticsDatabase.defaultURL(homeDirectory: homeDirectory))
    }

    func load() throws -> CallAnalyticsSnapshot {
        try prepare()
        return try readSnapshot()
    }

    /// 指纹只说明该来源最后一次完整扫描成功；部分失败或扫描中发生变化时不得复用。
    func successfulFingerprint(for source: CallSourceKind) throws -> String? {
        try prepare()
        return try database.scalarText("SELECT fingerprint FROM call_scan_checkpoint WHERE source=?", [.text(source.rawValue)])
    }

    /// 日高水位没有逐事件身份，无法可靠把旧日桶迁往另一个时区；因此固定首次采集时区。
    /// v6/v7 JSON 缺少该证据时保留原日期，未来采集沿用首次 SQL 运行的时区，不猜测旧日期。
    func aggregationTimeZone(preferred: TimeZone) throws -> TimeZone {
        try prepare()
        if let identifier = try database.scalarText("SELECT aggregation_timezone FROM call_meta WHERE id=1") {
            guard let zone = TimeZone(identifier: identifier) else { throw CallAnalyticsReadError.archive }
            return zone
        }
        try database.execute("""
            INSERT INTO call_meta(id,generated_at,schema_version,aggregation_timezone) VALUES(1,?,?,?)
            ON CONFLICT(id) DO UPDATE SET aggregation_timezone=COALESCE(call_meta.aggregation_timezone,excluded.aggregation_timezone)
            """, [.real(Date.distantPast.timeIntervalSince1970), .integer(Int64(CallAnalyticsSnapshot.currentSchemaVersion)), .text(preferred.identifier)])
        guard let identifier = try database.scalarText("SELECT aggregation_timezone FROM call_meta WHERE id=1"),
              let zone = TimeZone(identifier: identifier) else { throw CallAnalyticsReadError.archive }
        return zone
    }

    /// 输入仍是来源的完整日摘要，必须按高水位合并，不能作为新增调用直接累加。
    /// 汇总、最新状态和成功指纹在同一短事务提交；取消或失败会同时回滚。
    func merge(_ fresh: CallAnalyticsSnapshot, scannedSources: Set<CallSourceKind> = [],
               successfulFingerprints: [CallSourceKind: String] = [:]) throws -> CallAnalyticsSnapshot {
        try prepare()
        try database.transaction {
            try mergeEntries(fresh.entries)
            try mergeInvocations(fresh.agentInvocations)
            try saveMetadata(fresh)
            for source in scannedSources {
                // 失败扫描主动清除旧指纹，确保下次刷新会重试，不能被旧成功状态遮蔽。
                try database.execute("DELETE FROM call_scan_checkpoint WHERE source=?", [.text(source.rawValue)])
                if let fingerprint = successfulFingerprints[source] {
                    try database.execute("INSERT INTO call_scan_checkpoint(source,fingerprint) VALUES(?,?)",
                                         [.text(source.rawValue), .text(fingerprint)])
                }
            }
        }
        return try readSnapshot()
    }

    private func prepare() throws {
        guard !isPrepared else { return }
        try Task.checkCancellation()
        try database.execute("""
            CREATE TABLE IF NOT EXISTS call_daily (
                source TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
                server TEXT, agent TEXT, server_key TEXT NOT NULL, agent_key TEXT NOT NULL,
                day_key TEXT NOT NULL, count INTEGER NOT NULL, outcome_known INTEGER NOT NULL,
                success_count INTEGER NOT NULL, duration_samples INTEGER NOT NULL, duration_total REAL NOT NULL,
                PRIMARY KEY(source,kind,name,server_key,agent_key,day_key))
            """)
        try database.execute("CREATE INDEX IF NOT EXISTS call_daily_day_source ON call_daily(day_key,source)")
        try database.execute("""
            CREATE TABLE IF NOT EXISTS call_agent_daily (
                source TEXT NOT NULL, agent TEXT NOT NULL, day_key TEXT NOT NULL, count INTEGER NOT NULL,
                PRIMARY KEY(source,agent,day_key))
            """)
        try database.execute("CREATE TABLE IF NOT EXISTS call_inventory (kind TEXT NOT NULL, source TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY(kind,source,name))")
        try database.execute("""
            CREATE TABLE IF NOT EXISTS call_source_status (
                source TEXT PRIMARY KEY, available INTEGER NOT NULL, event_count INTEGER NOT NULL,
                files_scanned INTEGER NOT NULL, error_code TEXT)
            """)
        try database.execute("CREATE TABLE IF NOT EXISTS call_meta (id INTEGER PRIMARY KEY CHECK(id=1), generated_at REAL NOT NULL, schema_version INTEGER NOT NULL, aggregation_timezone TEXT)")
        try database.execute("CREATE TABLE IF NOT EXISTS call_scan_checkpoint (source TEXT PRIMARY KEY, fingerprint TEXT NOT NULL)")
        if try !database.hasMigration(Self.migration) {
            // 先解码再开始写事务；读取失败时不写迁移标记，也不修改原文件，后续可以安全重试。
            let legacy: CallAnalyticsSnapshot?
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                try AnalyticsDatabase.validate(legacyURL)
                let decoded = try JSONDecoder().decode(CallAnalyticsSnapshot.self, from: Data(contentsOf: legacyURL))
                guard (6...CallAnalyticsSnapshot.currentSchemaVersion).contains(decoded.schemaVersion) else {
                    throw CallAnalyticsReadError.archive
                }
                legacy = decoded
            } else { legacy = nil }
            try database.transaction {
                // 第二个实例可能已经完成迁移；事务内再检查可避免覆盖其更新后的状态。
                guard try !database.hasMigration(Self.migration) else { return }
                if let legacy {
                    try mergeEntries(legacy.entries)
                    try mergeInvocations(legacy.agentInvocations)
                    try saveMetadata(legacy)
                }
                try database.markMigration(Self.migration)
            }
        }
        isPrepared = true
    }

    private func mergeEntries(_ entries: [CallAnalyticsEntry]) throws {
        for entry in entries {
            try Task.checkCancellation()
            // 同数量时只接受结果与耗时覆盖均不减少的版本，保留既有未知信号的独立分母。
            // 日志清理后保留历史下界；日摘要不能证明新旧调用是否重叠，不能凭空生成明细。
            try database.execute("""
                INSERT INTO call_daily(source,kind,name,server,agent,server_key,agent_key,day_key,
                    count,outcome_known,success_count,duration_samples,duration_total)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(source,kind,name,server_key,agent_key,day_key) DO UPDATE SET
                    count=excluded.count, outcome_known=excluded.outcome_known,
                    success_count=excluded.success_count, duration_samples=excluded.duration_samples,
                    duration_total=excluded.duration_total
                WHERE excluded.count>call_daily.count OR (excluded.count=call_daily.count
                    AND excluded.outcome_known>=call_daily.outcome_known
                    AND excluded.duration_samples>=call_daily.duration_samples)
                """, [.text(entry.source.rawValue), .text(entry.kind.rawValue), .text(entry.name),
                        Self.optional(entry.server), Self.optional(entry.agent),
                        .text(Self.optionalKey(entry.server)), .text(Self.optionalKey(entry.agent)), .text(entry.dayKey),
                        .integer(Int64(entry.count)), .integer(Int64(entry.outcomeKnownCount)),
                        .integer(Int64(entry.successCount)), .integer(Int64(entry.durationSampleCount)), .real(entry.durationMsTotal)])
        }
    }

    /// v6 未定日总数仅保留未被已知日覆盖的余量；nil 永远不会被扫描日期或文件 mtime 代替。
    /// 按 agent 查询已有少量日行，避免为更新一个来源重新解码整份历史快照。
    private func mergeInvocations(_ fresh: [AgentInvocationCount]) throws {
        struct AgentKey: Hashable { let source: CallSourceKind; let agent: String }
        let groups = Dictionary(grouping: fresh) { AgentKey(source: $0.source, agent: $0.agent) }
        for (key, current) in groups {
            let previous = try database.query("SELECT day_key,count FROM call_agent_daily WHERE source=? AND agent=?",
                [.text(key.source.rawValue), .text(key.agent)]) { statement in
                    (day: Self.text(statement, 0), count: Int(sqlite3_column_int64(statement, 1)))
                }
            var days: [String: Int] = [:]
            for item in previous where !item.day.isEmpty { days[item.day] = max(0, item.count) }
            let dated = Dictionary(grouping: current.filter { $0.dayKey != nil }, by: { $0.dayKey! })
            for (day, values) in dated {
                days[day] = max(days[day] ?? 0, values.reduce(0) { $0 + max(0, $1.count) })
            }
            let minimum = max(previous.reduce(0) { $0 + max(0, $1.count) }, current.reduce(0) { $0 + max(0, $1.count) })
            let unknown = max(0, minimum - days.values.reduce(0, +))
            try database.execute("DELETE FROM call_agent_daily WHERE source=? AND agent=?", [.text(key.source.rawValue), .text(key.agent)])
            for (day, count) in days {
                try database.execute("INSERT INTO call_agent_daily(source,agent,day_key,count) VALUES(?,?,?,?)",
                    [.text(key.source.rawValue), .text(key.agent), .text(day), .integer(Int64(count))])
            }
            if unknown > 0 {
                try database.execute("INSERT INTO call_agent_daily(source,agent,day_key,count) VALUES(?,?,?,?)",
                    [.text(key.source.rawValue), .text(key.agent), .text(""), .integer(Int64(unknown))])
            }
        }
    }

    private func saveMetadata(_ snapshot: CallAnalyticsSnapshot) throws {
        try database.execute("DELETE FROM call_inventory")
        for (kind, items) in [("skill", snapshot.installedSkills), ("mcp", snapshot.installedMCPServers)] {
            for item in items {
                try database.execute("INSERT OR IGNORE INTO call_inventory(kind,source,name) VALUES(?,?,?)",
                    [.text(kind), .text(item.source.rawValue), .text(item.name)])
            }
        }
        for status in snapshot.sources {
            try database.execute("""
                INSERT INTO call_source_status(source,available,event_count,files_scanned,error_code) VALUES(?,?,?,?,?)
                ON CONFLICT(source) DO UPDATE SET available=excluded.available,event_count=excluded.event_count,
                    files_scanned=excluded.files_scanned,error_code=excluded.error_code
                """, [.text(status.source.rawValue), .integer(status.available ? 1 : 0), .integer(Int64(status.eventCount)),
                        .integer(Int64(status.filesScanned)), Self.optional(status.errorCode)])
        }
        try database.execute("""
            INSERT INTO call_meta(id,generated_at,schema_version,aggregation_timezone) VALUES(1,?,?,?)
            ON CONFLICT(id) DO UPDATE SET generated_at=excluded.generated_at,schema_version=excluded.schema_version,
                aggregation_timezone=COALESCE(call_meta.aggregation_timezone,excluded.aggregation_timezone)
            """, [.real(snapshot.generatedAt.timeIntervalSince1970), .integer(Int64(CallAnalyticsSnapshot.currentSchemaVersion)),
                    Self.optional(snapshot.aggregationTimeZoneIdentifier)])
    }

    private func readSnapshot() throws -> CallAnalyticsSnapshot {
        let generatedAt = try database.query("SELECT generated_at FROM call_meta WHERE id=1") {
            Date(timeIntervalSince1970: sqlite3_column_double($0, 0))
        }.first ?? .distantPast
        let entries = try database.query("""
            SELECT source,kind,name,server,agent,day_key,count,outcome_known,success_count,duration_samples,duration_total
            FROM call_daily ORDER BY day_key,source,kind,name,server_key,agent_key
            """) { statement in
                guard let source = CallSourceKind(rawValue: Self.text(statement, 0)),
                      let kind = CallKind(rawValue: Self.text(statement, 1)) else { throw CallAnalyticsReadError.archive }
                return CallAnalyticsEntry(source: source, kind: kind, name: Self.text(statement, 2),
                    server: Self.optionalText(statement, 3), agent: Self.optionalText(statement, 4), dayKey: Self.text(statement, 5),
                    count: Int(sqlite3_column_int64(statement, 6)), outcomeKnownCount: Int(sqlite3_column_int64(statement, 7)),
                    successCount: Int(sqlite3_column_int64(statement, 8)), durationSampleCount: Int(sqlite3_column_int64(statement, 9)),
                    durationMsTotal: sqlite3_column_double(statement, 10))
            }
        let invocations = try database.query("SELECT source,agent,day_key,count FROM call_agent_daily ORDER BY source,agent,day_key") { statement in
            guard let source = CallSourceKind(rawValue: Self.text(statement, 0)) else { throw CallAnalyticsReadError.archive }
            let day = Self.text(statement, 2)
            return AgentInvocationCount(source: source, agent: Self.text(statement, 1), count: Int(sqlite3_column_int64(statement, 3)),
                                        dayKey: day.isEmpty ? nil : day)
        }
        let inventory = try database.query("SELECT kind,source,name FROM call_inventory ORDER BY source,name") { statement in
            guard let source = CallSourceKind(rawValue: Self.text(statement, 1)) else { throw CallAnalyticsReadError.archive }
            return (kind: Self.text(statement, 0), item: InstalledItem(source: source, name: Self.text(statement, 2)))
        }
        let statuses = try database.query("SELECT source,available,event_count,files_scanned,error_code FROM call_source_status ORDER BY source") { statement in
            guard let source = CallSourceKind(rawValue: Self.text(statement, 0)) else { throw CallAnalyticsReadError.archive }
            return CallSourceStatus(source: source, available: sqlite3_column_int64(statement, 1) != 0,
                eventCount: Int(sqlite3_column_int64(statement, 2)), filesScanned: Int(sqlite3_column_int64(statement, 3)),
                errorCode: Self.optionalText(statement, 4))
        }
        return CallAnalyticsSnapshot(generatedAt: generatedAt, rangeKey: "all", entries: entries,
            installedSkills: inventory.filter { $0.kind == "skill" }.map(\.item),
            installedMCPServers: inventory.filter { $0.kind == "mcp" }.map(\.item), agentInvocations: invocations, sources: statuses,
            aggregationTimeZoneIdentifier: try database.scalarText("SELECT aggregation_timezone FROM call_meta WHERE id=1"))
    }

    /// 复合主键显式区分 nil 与空字符串，不依赖 SQLite 对 NULL 唯一约束的特殊行为。
    private static func optionalKey(_ value: String?) -> String { value.map { "1" + $0 } ?? "0" }
    private static func optional(_ value: String?) -> AnalyticsDatabase.Value { value.map(AnalyticsDatabase.Value.text) ?? .null }
    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String { optionalText(statement, column) ?? "" }
    private static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
