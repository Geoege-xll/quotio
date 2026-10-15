import Foundation
import SQLite3

/// 扫描索引与统计事实共用 SQLite。文件名仅保存 SHA-256 键，正文、半行缓冲区和原始身份不落盘。
/// 这里保留已消失源文件的索引，因为扫描完成后、账本投影前应用可能退出；这些行是可重放输入。
nonisolated extension ClientUsageSQLiteStore {
    func prepareScanTables() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS client_usage_line_files (
                source TEXT NOT NULL, file_key TEXT NOT NULL, version INTEGER NOT NULL, device INTEGER NOT NULL,
                inode INTEGER NOT NULL, size INTEGER NOT NULL, modified_seconds INTEGER NOT NULL,
                modified_nanos INTEGER NOT NULL, changed_seconds INTEGER NOT NULL, changed_nanos INTEGER NOT NULL,
                created_seconds INTEGER NOT NULL, created_nanos INTEGER NOT NULL, offset INTEGER NOT NULL,
                prefix_hash TEXT NOT NULL, boundary_hash TEXT NOT NULL, has_errors INTEGER NOT NULL,
                tail_errors INTEGER NOT NULL, PRIMARY KEY(source,file_key))
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS client_usage_codex_files (
                file_key TEXT PRIMARY KEY, version INTEGER NOT NULL, device INTEGER NOT NULL, inode INTEGER NOT NULL,
                size INTEGER NOT NULL, modified_seconds INTEGER NOT NULL, modified_nanos INTEGER NOT NULL,
                changed_seconds INTEGER NOT NULL, changed_nanos INTEGER NOT NULL, offset INTEGER NOT NULL,
                ordinal INTEGER NOT NULL, model TEXT NOT NULL, session_id TEXT NOT NULL, found_metadata INTEGER NOT NULL,
                has_errors INTEGER NOT NULL, prefix_hash TEXT NOT NULL, boundary_hash TEXT NOT NULL)
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS client_usage_opencode_state (
                id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, database_identity TEXT NOT NULL,
                fingerprint TEXT NOT NULL, has_errors INTEGER NOT NULL)
            """)
        try database.execute("CREATE TABLE IF NOT EXISTS client_usage_opencode_revisions (message_key TEXT PRIMARY KEY, revision TEXT NOT NULL)")
    }

    func loadLineCache(source: ClientUsageSource, legacyURL: URL?, includeRecords: Bool = true) throws -> ClaudeClientUsageReader.Cache {
        if includeRecords, let cached = lineCaches[source] { return cached }
        try prepare()
        let migration = "client-usage-line-cache-v2-" + source.rawValue
        if try !database.hasMigration(migration) {
            // 旧索引可能包含尚未投影且源日志已删除的唯一历史。现存文件读/解码失败必须
            // 中止迁移，不能当成空缓存标记成功；修复旧文件后下一次刷新仍可完整重试。
            if let legacyURL { try AnalyticsDatabase.validate(legacyURL) }
            let legacy = try legacyURL.flatMap { try ClientUsageCacheFile.load(ClaudeClientUsageReader.Cache.self, from: $0) }
            if let legacy {
                guard legacy.version == 2, legacy.files.allSatisfy({ validLineEntry($0.value, source: source, key: $0.key) }) else {
                    throw ClientUsageEngine.ArchiveError.invalidArchive
                }
            }
            try database.transaction {
                guard try !database.hasMigration(migration) else { return }
                if let legacy {
                    for (key, entry) in legacy.files {
                        try writeLineEntry(entry, previous: nil, source: source, key: key)
                    }
                }
                try database.markMigration(migration)
            }
        }
        let files: [(String, ClaudeClientUsageReader.Entry)] = try database.query("""
            SELECT file_key,device,inode,size,modified_seconds,modified_nanos,changed_seconds,changed_nanos,
                   created_seconds,created_nanos,offset,prefix_hash,boundary_hash,has_errors,tail_errors
            FROM client_usage_line_files WHERE source=? AND version=2
            """, [.text(source.rawValue)]) { statement in
                let key = Self.text(statement, 0)
                let fingerprint = ClaudeClientUsageReader.Fingerprint(device: Int32(truncatingIfNeeded: sqlite3_column_int64(statement, 1)),
                    inode: UInt64(bitPattern: sqlite3_column_int64(statement, 2)), size: sqlite3_column_int64(statement, 3),
                    modifiedSeconds: sqlite3_column_int64(statement, 4), modifiedNanoseconds: sqlite3_column_int64(statement, 5),
                    changedSeconds: sqlite3_column_int64(statement, 6), changedNanoseconds: sqlite3_column_int64(statement, 7),
                    createdSeconds: sqlite3_column_int64(statement, 8), createdNanoseconds: sqlite3_column_int64(statement, 9))
                // 生产扫描只读取小型文件水位。完整记录仅供显式原始采集/归档兼容路径恢复。
                let records = includeRecords ? try loadRecords(scope: Self.lineScope(source, key)) : []
                return (key, ClaudeClientUsageReader.Entry(fingerprint: fingerprint, prefixDigest: Self.text(statement, 11),
                    boundaryDigest: Self.text(statement, 12), offset: sqlite3_column_int64(statement, 10), records: records,
                    hasErrors: sqlite3_column_int(statement, 13) != 0, tailHasErrors: sqlite3_column_int(statement, 14) != 0))
            }
        var cache = ClaudeClientUsageReader.Cache()
        cache.files = Dictionary(files, uniquingKeysWith: { _, last in last })
        if includeRecords { lineCaches[source] = cache }
        return cache
    }

    func saveLineCache(_ cache: ClaudeClientUsageReader.Cache, source: ClientUsageSource) throws {
        try prepare()
        let old = lineCaches[source] ?? ClaudeClientUsageReader.Cache()
        let changes = cache.files.filter { old.files[$0.key] != $0.value }
        guard !changes.isEmpty else { return }
        try database.transaction {
            for (key, entry) in changes {
                try writeLineEntry(entry, previous: old.files[key], source: source, key: key)
            }
        }
        // 只有事务提交后才发布新游标；取消/写盘失败时继续复用旧内存视图。
        lineCaches[source] = cache
    }

    private func validLineEntry(_ entry: ClaudeClientUsageReader.Entry, source: ClientUsageSource, key: String) -> Bool {
        key.count == 64 && entry.offset >= 0 && entry.offset <= entry.fingerprint.size
            && entry.records.allSatisfy { $0.source == source }
            && Self.valid(ClientUsageSnapshot(records: entry.records))
    }
    private static func lineScope(_ source: ClientUsageSource, _ key: String) -> String { "scan:" + source.rawValue + ":" + key }
    private func writeLineEntry(_ entry: ClaudeClientUsageReader.Entry, previous: ClaudeClientUsageReader.Entry?,
                                source: ClientUsageSource, key: String) throws {
        guard validLineEntry(entry, source: source, key: key) else { throw ClientUsageEngine.ArchiveError.invalidArchive }
        try writeRecords(entry.records, previous: previous?.records ?? [], scope: Self.lineScope(source, key))
        try markScanScopeDirty(Self.lineScope(source, key))
        let value = entry.fingerprint
        try database.execute("INSERT OR REPLACE INTO client_usage_line_files VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
            .text(source.rawValue), .text(key), .integer(2), .integer(Int64(value.device)), .integer(Int64(bitPattern: value.inode)),
            .integer(value.size), .integer(value.modifiedSeconds), .integer(value.modifiedNanoseconds),
            .integer(value.changedSeconds), .integer(value.changedNanoseconds), .integer(value.createdSeconds),
            .integer(value.createdNanoseconds), .integer(entry.offset), .text(entry.prefixDigest), .text(entry.boundaryDigest),
            Self.bool(entry.hasErrors), Self.bool(entry.tailHasErrors)])
    }

    /// 生产仅恢复文件水位，不加载历史检查点；完整索引仅保留给显式兼容采集入口。
    /// SQL 中的孤儿文件仍保留，其未完成投影由持久化 dirty scope 恢复。
    func loadCodexCaches(legacyURL: URL?, includeCheckpoints: Bool = true) throws -> [String: CodexUsageFileCache] {
        if includeCheckpoints, let codexCaches { return codexCaches }
        try prepare()
        let migration = "client-usage-codex-cache-v2"
        if try !database.hasMigration(migration) {
            try database.transaction {
                guard try !database.hasMigration(migration) else { return }
                if let legacyURL {
                    try AnalyticsDatabase.validate(legacyURL)
                    let directory = CodexUsageFileCache.directory(base: legacyURL)
                    try AnalyticsDatabase.validate(directory)
                    if FileManager.default.fileExists(atPath: directory.path) {
                        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        for url in urls where url.pathExtension == "json" {
                            try Task.checkCancellation()
                            try AnalyticsDatabase.validate(url)
                            guard let cache = try ClientUsageCacheFile.load(CodexUsageFileCache.self, from: url), cache.isValid,
                                  url.deletingPathExtension().lastPathComponent.count == 64 else {
                                throw ClientUsageEngine.ArchiveError.invalidArchive
                            }
                            // 单个文件解码后立即写入，不把全部旧 JSON 的检查点同时保留在内存。
                            // 任一损坏文件仍使整个迁移回滚，旧文件原样保留供下次重试。
                            try writeCodexCache(cache, previous: nil, key: url.lastPathComponent)
                        }
                    }
                }
                try database.markMigration(migration)
            }
        }
        let rows: [(String, CodexUsageFileCache)] = try database.query("""
            SELECT file_key,version,device,inode,size,modified_seconds,modified_nanos,changed_seconds,changed_nanos,
                   offset,ordinal,model,session_id,found_metadata,has_errors,prefix_hash,boundary_hash
            FROM client_usage_codex_files
            """) { statement in
                let key = Self.text(statement, 0)
                let stamp = CodexUsageFileStamp(device: UInt64(bitPattern: sqlite3_column_int64(statement, 2)),
                    inode: UInt64(bitPattern: sqlite3_column_int64(statement, 3)), size: sqlite3_column_int64(statement, 4),
                    modifiedSeconds: sqlite3_column_int64(statement, 5), modifiedNanos: sqlite3_column_int64(statement, 6),
                    changedSeconds: sqlite3_column_int64(statement, 7), changedNanos: sqlite3_column_int64(statement, 8))
                let value = CodexUsageFileCache(version: Int(sqlite3_column_int64(statement, 1)), stamp: stamp,
                    offset: sqlite3_column_int64(statement, 9), ordinal: Int(sqlite3_column_int64(statement, 10)),
                    model: Self.text(statement, 11), hashedSessionID: Self.text(statement, 12),
                    foundMetadata: sqlite3_column_int(statement, 13) != 0, hasErrors: sqlite3_column_int(statement, 14) != 0,
                    prefixHash: Self.text(statement, 15), boundaryHash: Self.text(statement, 16),
                    checkpoints: includeCheckpoints ? try loadCheckpoints(scope: "scan:codex:" + key) : [])
                guard value.isValid else { throw ClientUsageEngine.ArchiveError.invalidArchive }
                return (key, value)
            }
        let result = Dictionary(rows, uniquingKeysWith: { _, last in last })
        if includeCheckpoints { codexCaches = result }
        return result
    }

    func saveCodexCache(_ cache: CodexUsageFileCache, key: String) throws {
        try prepare()
        let previous = codexCaches?[key]
        guard previous != cache else { return }
        try database.transaction { try writeCodexCache(cache, previous: previous, key: key) }
        if codexCaches == nil { codexCaches = [:] }
        codexCaches?[key] = cache
    }
    private func writeCodexCache(_ cache: CodexUsageFileCache, previous: CodexUsageFileCache?, key: String) throws {
        guard cache.isValid else { throw ClientUsageEngine.ArchiveError.invalidArchive }
        try writeCheckpoints(cache.checkpoints, previous: previous?.checkpoints ?? [], scope: "scan:codex:" + key)
        try markScanScopeDirty("scan:codex:" + key)
        let stamp = cache.stamp
        try database.execute("INSERT OR REPLACE INTO client_usage_codex_files VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
            .text(key), Self.integer(cache.version), .integer(Int64(bitPattern: stamp.device)), .integer(Int64(bitPattern: stamp.inode)),
            .integer(stamp.size), .integer(stamp.modifiedSeconds), .integer(stamp.modifiedNanos),
            .integer(stamp.changedSeconds), .integer(stamp.changedNanos), .integer(cache.offset), Self.integer(cache.ordinal),
            .text(cache.model), .text(cache.hashedSessionID), Self.bool(cache.foundMetadata), Self.bool(cache.hasErrors),
            .text(cache.prefixHash), .text(cache.boundaryHash)])
    }

    func loadOpenCodeCache(legacyURL: URL?, includeRecords: Bool = true) throws -> OpenCodeClientUsageCache? {
        if includeRecords, openCodeLoaded { return openCodeCache }
        try prepare()
        let migration = "client-usage-opencode-cache-v1"
        if try !database.hasMigration(migration) {
            if let legacyURL { try AnalyticsDatabase.validate(legacyURL) }
            let legacy = try legacyURL.flatMap { try ClientUsageCacheFile.load(OpenCodeClientUsageCache.self, from: $0) }
            guard legacy?.isValid != false else { throw ClientUsageEngine.ArchiveError.invalidArchive }
            try database.transaction {
                guard try !database.hasMigration(migration) else { return }
                if let legacy { try writeOpenCodeCache(legacy, previous: nil) }
                try database.markMigration(migration)
            }
        }
        let result = try database.query("SELECT version,database_identity,fingerprint,has_errors FROM client_usage_opencode_state WHERE id=1") { statement in
            let revisions: [(String, String)] = includeRecords ? try database.query("SELECT message_key,revision FROM client_usage_opencode_revisions") {
                (Self.text($0, 0), Self.text($0, 1))
            } : []
            return OpenCodeClientUsageCache(version: Int(sqlite3_column_int64(statement, 0)), databaseIdentity: Self.text(statement, 1),
                fingerprint: Self.text(statement, 2), revisions: Dictionary(revisions, uniquingKeysWith: { _, last in last }),
                records: includeRecords ? try loadRecords(scope: "scan:opencode") : [], hasErrors: sqlite3_column_int(statement, 3) != 0)
        }.first
        guard result?.isValid != false else { throw ClientUsageEngine.ArchiveError.invalidArchive }
        if includeRecords { openCodeCache = result; openCodeLoaded = true }
        return result
    }

    func saveOpenCodeCache(_ cache: OpenCodeClientUsageCache) throws {
        try prepare()
        guard cache != openCodeCache else { return }
        try database.transaction { try writeOpenCodeCache(cache, previous: openCodeCache) }
        openCodeCache = cache; openCodeLoaded = true
    }
    private func writeOpenCodeCache(_ cache: OpenCodeClientUsageCache, previous: OpenCodeClientUsageCache?) throws {
        guard cache.isValid else { throw ClientUsageEngine.ArchiveError.invalidArchive }
        try writeRecords(cache.records, previous: previous?.records ?? [], scope: "scan:opencode")
        try markScanScopeDirty("scan:opencode")
        let old = previous?.revisions ?? [:]
        try writeRows("INSERT OR REPLACE INTO client_usage_opencode_revisions VALUES(?,?)", rows: cache.revisions.compactMap { key, value in
            old[key] == value ? nil : [.text(key), .text(value)]
        })
        for key in old.keys where cache.revisions[key] == nil {
            try database.execute("DELETE FROM client_usage_opencode_revisions WHERE message_key=?", [.text(key)])
        }
        try database.execute("INSERT OR REPLACE INTO client_usage_opencode_state VALUES(1,?,?,?,?)", [
            Self.integer(cache.version), .text(cache.databaseIdentity), .text(cache.fingerprint), Self.bool(cache.hasErrors)])
    }
}
