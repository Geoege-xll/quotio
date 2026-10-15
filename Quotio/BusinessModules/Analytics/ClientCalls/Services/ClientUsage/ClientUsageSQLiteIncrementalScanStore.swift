import Foundation
import SQLite3

/// 生产扫描的按需写入入口。文件水位只携带本轮增量，历史事实留在 SQLite，
/// 不再为追加一行日志恢复整个文件、整个来源的历史数组。
nonisolated extension ClientUsageSQLiteStore {
    func saveLineIncrement(_ entry: ClaudeClientUsageReader.Entry, source: ClientUsageSource, key: String) throws {
        try prepare()
        guard key.count == 64, entry.offset >= 0, entry.offset <= entry.fingerprint.size,
              entry.records.allSatisfy({ $0.source == source }),
              Self.valid(ClientUsageSnapshot(records: entry.records)) else { throw ClientUsageEngine.ArchiveError.invalidArchive }
        try database.transaction {
            let scope = "scan:" + source.rawValue + ":" + key
            try mergeScanRecords(entry.records, scope: scope)
            let value = entry.fingerprint
            try database.execute("INSERT OR REPLACE INTO client_usage_line_files VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                .text(source.rawValue), .text(key), .integer(2), .integer(Int64(value.device)), .integer(Int64(bitPattern: value.inode)),
                .integer(value.size), .integer(value.modifiedSeconds), .integer(value.modifiedNanoseconds),
                .integer(value.changedSeconds), .integer(value.changedNanoseconds), .integer(value.createdSeconds),
                .integer(value.createdNanoseconds), .integer(entry.offset), .text(entry.prefixDigest), .text(entry.boundaryDigest),
                Self.bool(entry.hasErrors), Self.bool(entry.tailHasErrors)])
        }
        // 显式兼容采集也可能复用此连接；生产写入后使它的旧全量视图失效。
        lineCaches.removeValue(forKey: source)
    }

    func saveCodexIncrement(_ cache: CodexUsageFileCache, key: String) throws {
        try prepare()
        guard cache.isValid else { throw ClientUsageEngine.ArchiveError.invalidArchive }
        try database.transaction {
            let scope = "scan:codex:" + key
            // 与 CodexUsageCheckpoint.merging 完全一致：补充模型、父关联和 Token 证据，
            // 较完整副本可以修复解析错误；文件截断或替换不会删除已采集历史。
            let sql = """
                INSERT INTO client_usage_checkpoints(scope,\(Self.checkpointColumns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(scope,id) DO UPDATE SET
                  parent_id=COALESCE(excluded.parent_id,parent_id), fork_date=COALESCE(excluded.fork_date,fork_date),
                  model=CASE WHEN excluded.model<>'' AND excluded.model<>'unknown' THEN excluded.model ELSE model END,
                  ordinal=MIN(ordinal,excluded.ordinal), has_errors=has_errors AND excluded.has_errors,
                  cumulative_input=COALESCE(excluded.cumulative_input,cumulative_input),
                  cumulative_output=COALESCE(excluded.cumulative_output,cumulative_output),
                  cumulative_cached=COALESCE(excluded.cumulative_cached,cumulative_cached),
                  cumulative_reasoning=COALESCE(excluded.cumulative_reasoning,cumulative_reasoning),
                  cumulative_total=COALESCE(excluded.cumulative_total,cumulative_total),
                  last_input=COALESCE(excluded.last_input,last_input), last_output=COALESCE(excluded.last_output,last_output),
                  last_cached=COALESCE(excluded.last_cached,last_cached), last_reasoning=COALESCE(excluded.last_reasoning,last_reasoning),
                  last_total=COALESCE(excluded.last_total,last_total)
                """
            for start in stride(from: 0, to: cache.checkpoints.count, by: 256) {
                try Task.checkCancellation()
                let end = min(start + 256, cache.checkpoints.count)
                try writeRows(sql, rows: cache.checkpoints[start..<end].map { [.text(scope)] + Self.values($0) })
            }
            if !cache.checkpoints.isEmpty { try markScanScopeDirty(scope) }
            let stamp = cache.stamp
            try database.execute("INSERT OR REPLACE INTO client_usage_codex_files VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                .text(key), Self.integer(cache.version), .integer(Int64(bitPattern: stamp.device)), .integer(Int64(bitPattern: stamp.inode)),
                .integer(stamp.size), .integer(stamp.modifiedSeconds), .integer(stamp.modifiedNanos),
                .integer(stamp.changedSeconds), .integer(stamp.changedNanos), .integer(cache.offset), Self.integer(cache.ordinal),
                .text(cache.model), .text(cache.hashedSessionID), Self.bool(cache.foundMetadata), Self.bool(cache.hasErrors),
                .text(cache.prefixHash), .text(cache.boundaryHash)])
        }
        codexCaches = nil
    }

    /// 按消息查询一个版本，避免每次 OpenCode 刷新构造所有消息的双份修订字典。
    func openCodeRevision(for key: String) throws -> String? {
        try database.query("SELECT revision FROM client_usage_opencode_revisions WHERE message_key=?", [.text(key)]) {
            Self.text($0, 0)
        }.first
    }

    /// 一批消息的版本和事实同事务提交；即使随后取消或源库消失，dirty scope 仍可重放。
    func saveOpenCodeIncrement(records: [ClientUsageRecord], revisions: [(String, String)]) throws {
        try prepare()
        guard records.allSatisfy({ $0.source == .opencode }), Self.valid(ClientUsageSnapshot(records: records)),
              revisions.allSatisfy({ $0.0.count == 64 && $0.1.count == 64 }) else { throw ClientUsageEngine.ArchiveError.invalidArchive }
        try database.transaction {
            try mergeScanRecords(records, scope: "scan:opencode")
            try writeRows("INSERT OR REPLACE INTO client_usage_opencode_revisions VALUES(?,?)",
                          rows: revisions.map { [.text($0.0), .text($0.1)] })
        }
        openCodeCache = nil; openCodeLoaded = false
    }

    /// 只有整个只读事务完成且源库指纹未变时才发布新指纹；不把部分扫描伪装为完整复用。
    func saveOpenCodeFingerprint(identity: String, fingerprint: String, hasErrors: Bool) throws {
        try prepare()
        try database.execute("INSERT OR REPLACE INTO client_usage_opencode_state VALUES(1,1,?,?,?)", [
            .text(identity), .text(fingerprint), Self.bool(hasErrors)])
        openCodeCache = nil; openCodeLoaded = false
    }

    private func mergeScanRecords(_ records: [ClientUsageRecord], scope: String) throws {
        let sql = """
            INSERT INTO client_usage_records(scope,\(Self.recordColumns)) VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(scope,id) DO UPDATE SET
              source=excluded.source,timestamp=excluded.timestamp,model=excluded.model,
              input=excluded.input,output=excluded.output,cached=excluded.cached,reasoning=excluded.reasoning,
              total=excluded.total,reasoning_known=excluded.reasoning_known
            WHERE excluded.total>=client_usage_records.total
            """
        for start in stride(from: 0, to: records.count, by: 256) {
            try Task.checkCancellation()
            let end = min(start + 256, records.count)
            try writeRows(sql, rows: records[start..<end].map { [.text(scope)] + Self.values($0) })
        }
        if !records.isEmpty { try markScanScopeDirty(scope) }
    }
}
