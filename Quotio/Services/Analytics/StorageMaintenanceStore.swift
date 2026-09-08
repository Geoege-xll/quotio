import Foundation
import SQLite3

/// 清理范围与三个统计页面一一对应；账户、模型价格、代理安装和源日志不属于统计清理。
/// 原始值同时用于界面的稳定身份，不能根据本地化标题推断数据库表名。
nonisolated enum AnalyticsStorageModule: String, CaseIterable, Sendable, Identifiable {
    case dashboard, clientUsage, callAnalytics

    var id: String { rawValue }
    var titleKey: String { "storage.module." + rawValue }
}

/// 文件大小与记录行数由后台读取，不构造完整事件数组，也不把 WAL 当成可单独删除的缓存。
nonisolated struct AnalyticsStorageSnapshot: Equatable, Sendable {
    let databaseBytes: Int64
    let walBytes: Int64
    let recordCounts: [AnalyticsStorageModule: Int64]

    var totalBytes: Int64 { databaseBytes + walBytes }
}

/// 删除数量包含选定模块的事实、汇总、索引和水位行；它与用户实际调用次数是不同概念。
nonisolated struct AnalyticsStorageClearResult: Equatable, Sendable {
    let deletedCounts: [AnalyticsStorageModule: Int64]
    var totalDeletedCount: Int64 { deletedCounts.values.reduce(0, +) }
}

/// 仅在上层暂停并等待所有统计写入结束后执行维护事务。
/// 不删除数据库文件及其 WAL/SHM，也不通过重新建库破坏其他模块或遗失迁移标记。
actor StorageMaintenanceStore {
    private let database: AnalyticsDatabase

    init(databaseURL: URL = AnalyticsDatabase.defaultURL()) {
        database = AnalyticsDatabase(url: databaseURL)
    }

    /// 概况只执行标量查询；未建立数据库时返回空概况，不为了显示页面创建空库。
    func inspect() throws -> AnalyticsStorageSnapshot {
        guard FileManager.default.fileExists(atPath: database.url.path) else {
            return AnalyticsStorageSnapshot(databaseBytes: 0, walBytes: 0, recordCounts: [:])
        }
        let tables = try existingTables()
        var counts: [AnalyticsStorageModule: Int64] = [:]
        for module in AnalyticsStorageModule.allCases {
            switch module {
            case .dashboard:
                counts[module] = try count("cpa_events", existing: tables)
                    + count("cpa_historical_buckets", existing: tables)
            case .clientUsage:
                // 扫描输入与展示账本可能保存同一个事件；概况只计账本，避免把双 scope 当成两次用量。
                counts[module] = tables.contains("client_usage_records")
                    ? try database.scalarInt("SELECT COUNT(*) FROM client_usage_records WHERE scope='ledger'") ?? 0 : 0
            case .callAnalytics:
                counts[module] = try count("call_daily", existing: tables)
                    + count("call_agent_daily", existing: tables)
            }
        }
        return AnalyticsStorageSnapshot(databaseBytes: try size(of: database.url),
            walBytes: try size(of: URL(fileURLWithPath: database.url.path + "-wal")), recordCounts: counts)
    }

    /// 所选模块在同一个事务中删除，任一 SQL 失败或任务取消均整体回滚。
    /// 保留并补齐旧版本迁移标记，防止清除后又从旧备份恢复；仍存在的源日志可在后续采集重新导入。
    func clearStatistics(_ modules: Set<AnalyticsStorageModule>) throws -> AnalyticsStorageClearResult {
        guard !modules.isEmpty else { return AnalyticsStorageClearResult(deletedCounts: [:]) }
        return try database.transaction {
            let tables = try existingTables()
            var deletedCounts: [AnalyticsStorageModule: Int64] = [:]
            for module in AnalyticsStorageModule.allCases where modules.contains(module) {
                var deleted: Int64 = 0
                for table in Self.clearableTables(for: module, existing: tables) {
                    try Task.checkCancellation()
                    try database.execute("DELETE FROM \(table)")
                    deleted += Int64(database.changes)
                }
                if module == .callAnalytics, tables.contains("call_meta") {
                    // 调用归档只有日摘要，统计时区属于解释历史的配置；保留时区与 schema，只重置采集时间。
                    try database.execute("UPDATE call_meta SET generated_at=?", [.real(Date.distantPast.timeIntervalSince1970)])
                }
                for migration in Self.legacyMigrations(for: module) {
                    try database.markMigration(migration)
                }
                deletedCounts[module] = deleted
            }
            return AnalyticsStorageClearResult(deletedCounts: deletedCounts)
        }
    }

    /// DELETE 后的空闲页可供后续写入复用；用户显式执行此动作才重排数据库并尝试归还磁盘空间。
    /// VACUUM 不能位于写事务内。上层持有维护屏障，失败只报告整理失败，不再删除任何统计。
    func compact() throws -> AnalyticsStorageSnapshot {
        guard FileManager.default.fileExists(atPath: database.url.path) else { return try inspect() }
        try Task.checkCancellation()
        try database.execute("VACUUM")
        let busy = try database.query("PRAGMA wal_checkpoint(TRUNCATE)") { sqlite3_column_int($0, 0) }.first ?? 0
        guard busy == 0 else { throw AnalyticsDatabase.DatabaseError.sqlite(SQLITE_BUSY, "统计数据库仍有正在使用的读取连接") }
        return try inspect()
    }

    private func existingTables() throws -> Set<String> {
        Set(try database.query("SELECT name FROM sqlite_master WHERE type='table'") { statement in
            sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        })
    }

    private func count(_ table: String, existing: Set<String>) throws -> Int64 {
        guard existing.contains(table) else { return 0 }
        return try database.scalarInt("SELECT COUNT(*) FROM \(table)") ?? 0
    }

    private func size(of url: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        try AnalyticsDatabase.validate(url)
        return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 所有表名由应用维护白名单决定。client_usage_ 前缀覆盖同模块新增的可重建汇总表，
    /// 同时拒绝标点、引号等标识符，绝不把数据库内任意字符串直接拼入清除语句。
    private static func clearableTables(for module: AnalyticsStorageModule, existing: Set<String>) -> [String] {
        let allowed: Set<String>
        switch module {
        case .dashboard:
            allowed = ["cpa_events", "cpa_daily_buckets", "cpa_historical_buckets", "cpa_legacy_dedup_ids", "cpa_metadata"]
        case .clientUsage:
            allowed = existing.filter {
                $0.hasPrefix("client_usage_") && $0.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil
            }
        case .callAnalytics:
            allowed = ["call_daily", "call_agent_daily", "call_inventory", "call_source_status", "call_scan_checkpoint"]
        }
        return existing.intersection(allowed).sorted()
    }

    private static func legacyMigrations(for module: AnalyticsStorageModule) -> [String] {
        switch module {
        case .dashboard: ["cpa-unified-storage-v1"]
        case .clientUsage:
            ["client-usage-ledger-v1", "client-usage-line-cache-v2-claude", "client-usage-line-cache-v2-pi",
             "client-usage-codex-cache-v2", "client-usage-opencode-cache-v1"]
        case .callAnalytics: ["call_analytics_json_v1"]
        }
    }
}
