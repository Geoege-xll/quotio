import Foundation
import SQLite3

/// 生产账本通过磁盘上的待处理队列接管扫描结果。内存上限由单批事件和单个会话决定，
/// 不再随全部历史增长；扫描水位、待处理标记和最终投影分别拥有可恢复的事务边界。
nonisolated extension ClientUsageSQLiteStore {
    func prepareIncrementalLedgerTables() throws {
        // 附表不改变旧状态表的列顺序，兼容已有数据库与归档导入；只有真实采集完成后写入新诊断。
        try database.execute("CREATE TABLE IF NOT EXISTS client_usage_status_details (source TEXT PRIMARY KEY, read_errors INTEGER, incomplete_sessions INTEGER)")
        try database.execute("CREATE TABLE IF NOT EXISTS client_usage_dirty_scopes (scope TEXT PRIMARY KEY)")
        try database.execute("CREATE TABLE IF NOT EXISTS client_usage_projection_dirty (session_id TEXT PRIMARY KEY)")
        try database.execute("CREATE TABLE IF NOT EXISTS client_usage_projection_status (session_id TEXT PRIMARY KEY, has_errors INTEGER NOT NULL)")
        try database.execute("CREATE INDEX IF NOT EXISTS client_usage_checkpoints_parent ON client_usage_checkpoints(scope,parent_id,session_id)")
        try database.execute("CREATE INDEX IF NOT EXISTS client_usage_checkpoints_session_records ON client_usage_checkpoints(scope,session_id,id)")
        try preparePresentationTables()

        // 会话累计量变化会影响自身差额，以及直接子会话在分叉时间点读取的原始父累计量。
        // 孙会话读取的是自己的直接父会话原始累计量，因此无需递归重算整棵分叉树。
        for operation in ["INSERT", "UPDATE"] {
            try database.execute("DROP TRIGGER IF EXISTS client_usage_checkpoint_dirty_\(operation.lowercased())")
            try database.execute("""
                CREATE TRIGGER IF NOT EXISTS client_usage_checkpoint_dirty_\(operation.lowercased())_v2
                AFTER \(operation) ON client_usage_checkpoints WHEN NEW.scope='ledger'
                BEGIN
                    INSERT INTO client_usage_projection_dirty VALUES(NEW.session_id) ON CONFLICT(session_id) DO NOTHING;
                    INSERT INTO client_usage_projection_dirty
                        SELECT DISTINCT session_id FROM client_usage_checkpoints
                        WHERE scope='ledger' AND parent_id=NEW.session_id ON CONFLICT(session_id) DO NOTHING;
                END
                """)
        }
        let migration = "client-usage-incremental-projection-v1"
        if try !database.hasMigration(migration) {
            // 包含源日志已经消失的扫描记录：旧版本可能刚提交扫描游标、还没来得及交给账本。
            // 标记和迁移完成位于同一事务，取消后重试不会将孤儿输入误认为已消费。
            try database.execute("INSERT OR IGNORE INTO client_usage_dirty_scopes SELECT DISTINCT scope FROM client_usage_records WHERE scope LIKE 'scan:%'")
            try database.execute("INSERT OR IGNORE INTO client_usage_dirty_scopes SELECT DISTINCT scope FROM client_usage_checkpoints WHERE scope LIKE 'scan:%'")
            try database.execute("INSERT OR IGNORE INTO client_usage_projection_dirty SELECT DISTINCT session_id FROM client_usage_checkpoints WHERE scope='ledger'")
            try database.markMigration(migration)
        }
    }

    /// 调用方必须在写扫描事件与文件水位的同一事务内调用；标记存入磁盘后再返回扫描完成。
    func markScanScopeDirty(_ scope: String) throws {
        try database.execute("INSERT OR IGNORE INTO client_usage_dirty_scopes VALUES(?)", [.text(scope)])
    }

    /// 扫描器的生产结果仅携带状态；显式传入的记录仍支持独立解析测试和旧归档接入。
    /// 每个文件先提交事件并登记待投影会话，再逐个会话投影。中途取消只留下可重放的队列。
    func mergeIncrementally(scans: [ClientUsageScan], at date: Date) throws {
        try prepare()
        for scan in scans {
            try Task.checkCancellation()
            try consumePendingScan(source: scan.source)
            try database.transaction {
                if scan.source == .codex, !scan.codexCheckpoints.isEmpty {
                    try upsertLedgerCheckpoints(scan.codexCheckpoints)
                } else {
                    try upsertLedgerRecords(scan.records.filter { $0.source == scan.source })
                }
            }
            if scan.source == .codex { try consumePendingProjections() }
            var readErrors = scan.hasErrors
            var incompleteSessions = 0
            if scan.source == .codex {
                incompleteSessions = Int(try database.scalarInt(
                    "SELECT count(*) FROM client_usage_projection_status WHERE has_errors=1") ?? 0)
                let hasCheckpoints = try database.scalarInt(
                    "SELECT 1 FROM client_usage_checkpoints WHERE scope='ledger' LIMIT 1") != nil
                // 历史投影缺口可能长期存在，但不能把本轮成功读取改成失败。
                // 无检查点的失败来源保留旧降级判断，真正的 I/O/解析错误始终独立上报。
                readErrors = scan.codexReadErrors || (!hasCheckpoints && scan.hasErrors)
            }
            try database.transaction {
                try saveStatus(ClientUsageStatus(source: scan.source, available: scan.available,
                    hasErrors: readErrors || incompleteSessions > 0, filesScanned: scan.filesScanned,
                    readErrors: readErrors, incompleteSessionCount: incompleteSessions))
                try database.execute("INSERT OR REPLACE INTO client_usage_metadata VALUES('collected_at',?)", [.real(date.timeIntervalSince1970)])
            }
        }
    }

    /// 一次只加载 256 条扫描事实。读取、写入和清除 scope 标记同事务完成，
    /// 另一连接不能在消费期间推进同一文件水位后被错误地清除新待办。
    func consumePendingScan(source: ClientUsageSource) throws {
        let prefix = "scan:" + source.rawValue
        while let scope = try database.scalarText(
            "SELECT scope FROM client_usage_dirty_scopes WHERE scope=? OR scope LIKE ? ORDER BY scope LIMIT 1",
            [.text(prefix), .text(prefix + ":%")]) {
            try Task.checkCancellation()
            try database.transaction {
                var cursor = ""
                while true {
                    if source == .codex {
                        let rows = try database.query("SELECT \(Self.checkpointColumns) FROM client_usage_checkpoints WHERE scope=? AND id>? ORDER BY id LIMIT 256",
                            [.text(scope), .text(cursor)], map: Self.checkpoint)
                        guard let last = rows.last else { break }
                        try upsertLedgerCheckpoints(rows)
                        cursor = last.id
                    } else {
                        let rows = try database.query("SELECT \(Self.recordColumns) FROM client_usage_records WHERE scope=? AND id>? ORDER BY id LIMIT 256",
                            [.text(scope), .text(cursor)], map: Self.record)
                        guard let last = rows.last else { break }
                        try upsertLedgerRecords(rows.filter { $0.source == source })
                        cursor = last.id
                    }
                }
                try database.execute("DELETE FROM client_usage_dirty_scopes WHERE scope=?", [.text(scope)])
            }
        }
    }

    /// 同一非 Codex 消息可能在后续分块中补齐 Token；保留较完整记录，等量修正允许更新元数据。
    /// SQL 直接按主键比较旧行，避免为一次小增量构造包含所有历史 ID 的 Swift 字典。
    private func upsertLedgerRecords(_ records: [ClientUsageRecord]) throws {
        let columns = Self.recordColumns.split(separator: ",").map(String.init).filter { $0 != "id" }
        let assignments = columns.map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        let changed = columns.map { "client_usage_records.\($0) IS NOT excluded.\($0)" }.joined(separator: " OR ")
        let sql = """
            INSERT INTO client_usage_records(scope,\(Self.recordColumns)) VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(scope,id) DO UPDATE SET \(assignments)
            WHERE client_usage_records.total<=excluded.total AND (\(changed))
            """
        for start in stride(from: 0, to: records.count, by: 256) {
            let end = min(start + 256, records.count)
            try writeRows(sql, rows: records[start..<end].map { [.text("ledger")] + Self.values($0) })
        }
    }

    /// 与 CodexUsageCheckpoint.merging 的补全语义一致。只有实际值变化才触发待投影队列，
    /// 否则重复扫描同一文件会导致每分钟重新计算全部旧会话。
    private func upsertLedgerCheckpoints(_ checkpoints: [CodexUsageCheckpoint]) throws {
        var expressions: [(String, String)] = [
            ("parent_id", "COALESCE(excluded.parent_id,client_usage_checkpoints.parent_id)"),
            ("fork_date", "COALESCE(excluded.fork_date,client_usage_checkpoints.fork_date)"),
            ("model", "CASE WHEN excluded.model NOT IN ('unknown','') THEN excluded.model ELSE client_usage_checkpoints.model END"),
            ("ordinal", "MIN(excluded.ordinal,client_usage_checkpoints.ordinal)"),
            ("has_errors", "MIN(excluded.has_errors,client_usage_checkpoints.has_errors)")
        ]
        for prefix in ["cumulative", "last"] {
            for suffix in ["input", "output", "cached", "reasoning", "total"] {
                let column = prefix + "_" + suffix
                expressions.append((column, "COALESCE(excluded.\(column),client_usage_checkpoints.\(column))"))
            }
        }
        let assignments = expressions.map { "\($0.0)=\($0.1)" }.joined(separator: ",")
        let changed = expressions.map { "client_usage_checkpoints.\($0.0) IS NOT (\($0.1))" }.joined(separator: " OR ")
        let sql = """
            INSERT INTO client_usage_checkpoints(scope,\(Self.checkpointColumns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(scope,id) DO UPDATE SET \(assignments) WHERE \(changed)
            """
        for start in stride(from: 0, to: checkpoints.count, by: 256) {
            let end = min(start + 256, checkpoints.count)
            try writeRows(sql, rows: checkpoints[start..<end].map { [.text("ledger")] + Self.values($0) })
        }
    }

    private func consumePendingProjections() throws {
        while let sessionID = try database.scalarText("SELECT session_id FROM client_usage_projection_dirty ORDER BY session_id LIMIT 1") {
            try Task.checkCancellation()
            var checkpoints = try sessionCheckpoints(sessionID)
            let parents = Set(checkpoints.compactMap(\.parentSessionID)).subtracting([sessionID])
            for parent in parents.sorted() { checkpoints.append(contentsOf: try sessionCheckpoints(parent)) }
            // 只计算一个目标会话；父检查点仅提供分叉时的原始累计基线，不发布父记录或父错误。
            let projection = CodexClientUsageSource.project(checkpoints: checkpoints, outputSessionIDs: [sessionID])
            try Task.checkCancellation()
            try database.transaction {
                // 先删除该会话已有投影，包含迟到前驱补入后应降为零的旧事件；无检查点旧归档保留。
                // 日汇总脏标记由行触发器产生，因此下降、模型修正和删除也会更新展示。
                try database.execute("""
                    DELETE FROM client_usage_records WHERE scope='ledger' AND id IN (
                        SELECT id FROM client_usage_checkpoints WHERE scope='ledger' AND session_id=?)
                    """, [.text(sessionID)])
                try upsertLedgerRecords(projection.records)
                try database.execute("INSERT OR REPLACE INTO client_usage_projection_status VALUES(?,?)",
                                     [.text(sessionID), Self.bool(projection.hasErrors)])
                try database.execute("DELETE FROM client_usage_projection_dirty WHERE session_id=?", [.text(sessionID)])
            }
        }
    }

    private func sessionCheckpoints(_ sessionID: String) throws -> [CodexUsageCheckpoint] {
        // 显式使用会话索引。将目标与父会话合并成 OR 子查询再 ORDER BY id，会让 SQLite
        // 选择(scope,id)主键并扫描所有历史来避免排序，数千会话下反而形成平方级工作量。
        try database.query("""
            SELECT \(Self.checkpointColumns) FROM client_usage_checkpoints INDEXED BY client_usage_checkpoints_session_records
            WHERE scope='ledger' AND session_id=? ORDER BY id
            """, [.text(sessionID)], map: Self.checkpoint)
    }

    /// 清理只释放可重建的内存索引；已提交的扫描输入、永久账本和未消费队列都继续留在 SQLite。
    func clearMemoryCaches() {
        lineCaches.removeAll(keepingCapacity: false)
        codexCaches = nil
        openCodeCache = nil
        openCodeLoaded = false
    }
}
