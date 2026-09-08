// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 参考 sylearn/AIUsage bdb83bbe 的 OpenCodeCostProvider；Quotio 修改：直接只读、最小字段投影、稳定消息身份与错误状态。
import Foundation
import SQLite3
import Darwin

/// OpenCode 本地客户端 Token 来源。只读 message 的使用量字段，不读取 part 正文，
/// 不复制原数据库及 WAL；SQLite 只读事务会直接看到 WAL 中已经提交的消息。
nonisolated struct OpenCodeClientUsageSource {
    let homeDirectory: String
    let environment: [String: String]

    func collect(cacheURL: URL? = nil, cacheStore: ClientUsageSQLiteStore? = nil,
                 progress: ClientUsageProgressHandler? = nil, incremental: Bool = false) throws -> ClientUsageScan {
        if incremental, let persistence = cacheStore ?? ClientUsageSQLiteStore.forCache(cacheURL) {
            return try collectIncrementally(cacheURL: cacheURL, store: persistence, progress: progress)
        }
        var scan = ClientUsageScan(source: .opencode)
        do {
            try Task.checkCancellation()
            // 先恢复脱敏历史再发现源库。来源缓存先落盘、永久账本尚未接管时若库被删除，
            // 仍须重放已扫描历史；available 只描述本次源文件是否存在，不能据缓存伪造成功。
            let persistence = cacheStore ?? ClientUsageSQLiteStore.forCache(cacheURL)
            var cached = try persistence?.loadOpenCodeCache(legacyURL: cacheURL)
            scan.records = cached?.records ?? []
            guard let path = databaseCandidate() else {
                scan.hasErrors = cached?.hasErrors ?? false
                return scan
            }
            scan.available = true
            let safePath = try checkedPath(path)
            for suffix in ["-wal", "-shm"] where exists(safePath + suffix) {
                _ = try checkedPath(safePath + suffix)
            }
            let stamp = try OpenCodeClientUsageCache.fileStamp(safePath)
            // 替换数据库只使当前行索引失效，不能删除尚待永久账本接管的旧历史记录。
            if cached?.databaseIdentity != stamp.identity { cached = nil }
            progress?(ClientUsageProgress(source: .opencode, filesTotal: 1, bytesTotal: stamp.bytes))
            if let cached, cached.fingerprint == stamp.fingerprint {
                scan.records = cached.records; scan.hasErrors = cached.hasErrors; scan.filesScanned = 1
                progress?(ClientUsageProgress(source: .opencode, filesCompleted: 1, filesTotal: 1,
                                              bytesTotal: stamp.bytes, filesReused: 1))
                return scan
            }
            let revisions = try readDatabase(safePath, previous: cached, buildIndex: persistence != nil,
                                             bytesTotal: stamp.bytes, progress: progress, into: &scan)
            try Task.checkCancellation()
            if let persistence {
                let after = try OpenCodeClientUsageCache.fileStamp(safePath)
                // SQLite 查询期间源库可能继续写入。指纹变化时不把旧事务结果标为新指纹，
                // 让下一次重新比较源数据；本次已读取结果仍可交给永久账本保存。
                if after.fingerprint == stamp.fingerprint {
                    let value = OpenCodeClientUsageCache(databaseIdentity: stamp.identity, fingerprint: stamp.fingerprint,
                        revisions: revisions, records: scan.records, hasErrors: scan.hasErrors)
                    // 指纹、消息版本和脱敏记录一起提交到本地统计库，不写扫描 JSON。
                    try persistence.saveOpenCodeCache(value)
                }
            }
        } catch {
            if error is CancellationError { throw error }
            scan.hasErrors = true
        }
        return scan
    }

    /// 路径优先级与 OpenCode 对齐；只选一个活动目录，避免桌面版迁移备份被重复累加。
    private func databaseCandidate() -> String? {
        var roots: [String] = []
        if let xdg = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           xdg.hasPrefix("/") {
            roots.append((xdg as NSString).appendingPathComponent("opencode"))
        }
        roots += [".local/share/opencode", "Library/Application Support/opencode"].map {
            (homeDirectory as NSString).appendingPathComponent($0)
        }
        return roots.map { ($0 as NSString).appendingPathComponent("opencode.db") }.first(where: exists)
    }

    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// macOS 标准 /var 和 /tmp 别名先规范化，其余路径分量逐级 lstat 检查。
    /// SQLite 的 NOFOLLOW 再保护最终文件打开，避免读取用户放置的链接目标。
    private func checkedPath(_ path: String) throws -> String {
        var canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        if canonical.hasPrefix("/var/") { canonical = "/private" + canonical }
        if canonical.hasPrefix("/tmp/") { canonical = "/private" + canonical }
        var current = ""
        let pieces = canonical.split(separator: "/")
        for (index, piece) in pieces.enumerated() {
            current += "/" + piece
            var info = stat()
            guard lstat(current, &info) == 0 else { throw ReadError.unsafePath }
            let kind = info.st_mode & S_IFMT
            guard kind != S_IFLNK else { throw ReadError.unsafePath }
            if index == pieces.count - 1 {
                guard kind == S_IFREG else { throw ReadError.unsafePath }
            } else {
                guard kind == S_IFDIR else { throw ReadError.unsafePath }
            }
        }
        return canonical
    }

    private struct MessageRevision {
        let id: String
        let session: String
        let key: String
        let revision: String
    }

    /// 生产入口只保留指纹，每次按消息修订查询 SQL，解析结果最多缓存 256 条便落盘。
    /// 返回值不再携带全部历史；扫描到的事实由持久化 dirty scope 交给账本。
    private func collectIncrementally(cacheURL: URL?, store: ClientUsageSQLiteStore,
                                      progress: ClientUsageProgressHandler?) throws -> ClientUsageScan {
        var scan = ClientUsageScan(source: .opencode)
        do {
            try Task.checkCancellation()
            let cached = try store.loadOpenCodeCache(legacyURL: cacheURL, includeRecords: false)
            guard let path = databaseCandidate() else { scan.hasErrors = cached?.hasErrors ?? false; return scan }
            scan.available = true
            let safePath = try checkedPath(path)
            for suffix in ["-wal", "-shm"] where exists(safePath + suffix) { _ = try checkedPath(safePath + suffix) }
            let stamp = try OpenCodeClientUsageCache.fileStamp(safePath)
            let previous = cached?.databaseIdentity == stamp.identity ? cached : nil
            if let previous, previous.fingerprint == stamp.fingerprint {
                scan.hasErrors = previous.hasErrors; scan.filesScanned = 1
                progress?(ClientUsageProgress(source: .opencode, filesCompleted: 1, filesTotal: 1,
                                              bytesTotal: stamp.bytes, filesReused: 1))
                return scan
            }
            progress?(ClientUsageProgress(source: .opencode, filesTotal: 1, bytesTotal: stamp.bytes))
            try readDatabaseIncrementally(safePath, previous: previous, store: store,
                                         bytesTotal: stamp.bytes, progress: progress, into: &scan)
            try Task.checkCancellation()
            let after = try OpenCodeClientUsageCache.fileStamp(safePath)
            if after.fingerprint == stamp.fingerprint {
                try store.saveOpenCodeFingerprint(identity: stamp.identity, fingerprint: stamp.fingerprint, hasErrors: scan.hasErrors)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { scan.hasErrors = true }
        return scan
    }

    /// 来源库始终只读。消息版本与解析事实分批写入本地库，取消只会留下可重放的完整批次。
    /// 不使用最大日期水位，仍能发现旧日期补录、修订倒退和 usage 后补。
    private func readDatabaseIncrementally(_ path: String, previous: OpenCodeClientUsageCache?,
                                          store: ClientUsageSQLiteStore, bytesTotal: Int64,
                                          progress: ClientUsageProgressHandler?, into scan: inout ClientUsageScan) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            sqlite3_close(database); throw ReadError.database
        }
        defer { sqlite3_close(database) }
        scan.filesScanned = 1
        sqlite3_busy_timeout(database, 1000)
        let sqlProgress = SQLProgressContext(handler: progress, bytesTotal: bytesTotal)
        sqlite3_progress_handler(database, 1000, { raw in
            if let raw { Unmanaged<SQLProgressContext>.fromOpaque(raw).takeUnretainedValue().tick() }
            return Task<Never, Never>.isCancelled ? 1 : 0
        }, Unmanaged.passUnretained(sqlProgress).toOpaque())
        defer { sqlite3_progress_handler(database, 0, nil, nil); withExtendedLifetime(sqlProgress) {} }
        try execute(database, sql: "BEGIN")
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        let indexed = try supportsUpdatedIndex(database)
        let decoder = JSONDecoder()
        var records: [ClientUsageRecord] = []
        var revisions: [(String, String)] = []
        var bytesRead: Int64 = 0
        var rows = 0
        func flush() throws {
            guard !records.isEmpty || !revisions.isEmpty else { return }
            try store.saveOpenCodeIncrement(records: records, revisions: revisions)
            records.removeAll(keepingCapacity: true); revisions.removeAll(keepingCapacity: true)
        }
        func report() {
            sqlProgress.bytesRead = bytesRead
            if rows.isMultiple(of: 256) {
                progress?(ClientUsageProgress(source: .opencode, filesTotal: 1, bytesRead: bytesRead, bytesTotal: bytesTotal))
            }
        }
        let projection = """
            SELECT id,session_id,time_created,
              CASE WHEN json_valid(data) THEN json_object(
                'role',json_extract(data,'$.role'),'providerID',json_extract(data,'$.providerID'),
                'modelID',json_extract(data,'$.modelID'),
                'tokens',CASE WHEN json_extract(data,'$.role')='assistant' THEN json_extract(data,'$.tokens') ELSE NULL END) ELSE NULL END,
              \(indexed ? "time_updated" : "NULL"),length(data)
            FROM message
            """
        func consume(_ statement: OpaquePointer) throws {
            try Task.checkCancellation()
            rows += 1
            defer { report() }
            guard let id = text(statement, column: 0), !id.isEmpty,
                  let session = text(statement, column: 1), !session.isEmpty,
                  let payload = text(statement, column: 3) else { scan.hasErrors = true; return }
            bytesRead += Int64(payload.utf8.count)
            do {
                let message = try decoder.decode(Message.self, from: Data(payload.utf8))
                if message.role == "assistant", let tokens = message.tokens {
                    let cached = (tokens.cache?.read ?? 0) + (tokens.cache?.write ?? 0)
                    guard tokens.input + cached <= TokensLimit.maximum else { throw ReadError.invalidUsage }
                    if tokens.input + tokens.output + cached > 0 {
                        let millis = sqlite3_column_double(statement, 2)
                        guard sqlite3_column_type(statement, 2) != SQLITE_NULL, millis.isFinite, millis > 0 else { throw ReadError.invalidUsage }
                        let model = [message.providerID, message.modelID].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }.joined(separator: "/")
                        let identity = String(decoding: try JSONEncoder().encode([session, id]), as: UTF8.self)
                        records.append(ClientUsageRecord(identity: identity, source: .opencode,
                            timestamp: Date(timeIntervalSince1970: millis / 1000), model: model.isEmpty ? "unknown" : model,
                            input: tokens.input + cached, output: tokens.output, cached: cached, reasoning: tokens.reasoning ?? 0))
                    }
                }
                if indexed, sqlite3_column_type(statement, 4) == SQLITE_INTEGER {
                    let revision = OpenCodeClientUsageCache.digest([2, 4, 5].map { text(statement, column: $0) ?? "null" })
                    revisions.append((try OpenCodeClientUsageCache.messageKey(session: session, id: id), revision))
                }
            } catch { scan.hasErrors = true }
            if records.count >= 256 || revisions.count >= 256 { try flush() }
        }
        func fullScan() throws {
            var statement: OpaquePointer?
            let predicate = " WHERE CASE WHEN json_valid(data) THEN json_extract(data,'$.role')='assistant' ELSE 1 END"
            guard sqlite3_prepare_v2(database, projection + predicate, -1, &statement, nil) == SQLITE_OK, let statement else {
                try Task.checkCancellation(); throw ReadError.database
            }
            defer { sqlite3_finalize(statement) }
            while true {
                try Task.checkCancellation()
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { try Task.checkCancellation(); throw ReadError.database }
                try consume(statement)
            }
        }
        if indexed, previous != nil, previous?.hasErrors == false {
            var metadata: OpaquePointer?
            var changed: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT id,session_id,time_created,time_updated,length(data) FROM message", -1, &metadata, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(database, projection + " WHERE id=? AND session_id=?", -1, &changed, nil) == SQLITE_OK,
                  let metadata, let changed else {
                sqlite3_finalize(metadata); sqlite3_finalize(changed)
                try Task.checkCancellation(); throw ReadError.database
            }
            defer { sqlite3_finalize(metadata); sqlite3_finalize(changed) }
            var changes = 0
            var needsFullScan = false
            while true {
                try Task.checkCancellation()
                let result = sqlite3_step(metadata)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { try Task.checkCancellation(); throw ReadError.database }
                guard let id = text(metadata, column: 0), !id.isEmpty,
                      let session = text(metadata, column: 1), !session.isEmpty,
                      sqlite3_column_type(metadata, 3) == SQLITE_INTEGER else { needsFullScan = true; break }
                bytesRead += Int64(id.utf8.count + session.utf8.count + 24)
                sqlProgress.bytesRead = bytesRead
                let key = try OpenCodeClientUsageCache.messageKey(session: session, id: id)
                let revision = OpenCodeClientUsageCache.digest((2...4).map { text(metadata, column: Int32($0)) ?? "null" })
                guard try store.openCodeRevision(for: key) != revision else { continue }
                changes += 1
                sqlite3_reset(changed); sqlite3_clear_bindings(changed)
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(changed, 1, id, -1, transient); sqlite3_bind_text(changed, 2, session, -1, transient)
                while true {
                    let step = sqlite3_step(changed)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW else { try Task.checkCancellation(); throw ReadError.database }
                    try consume(changed)
                }
            }
            // 文件指纹变化但所有修订相同，可能是外部同长度修库，仍保留原来的全量核验兜底。
            if changes == 0 || needsFullScan { try fullScan() }
        } else { try fullScan() }
        try Task.checkCancellation()
        try flush()
        progress?(ClientUsageProgress(source: .opencode, filesCompleted: 1, filesTotal: 1,
                                      bytesRead: bytesRead, bytesTotal: bytesTotal))
    }

    private func readDatabase(_ path: String, previous: OpenCodeClientUsageCache?, buildIndex: Bool,
                              bytesTotal: Int64, progress: ClientUsageProgressHandler?,
                              into scan: inout ClientUsageScan) throws -> [String: String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw ReadError.database
        }
        defer { sqlite3_close(database) }
        scan.filesScanned = 1
        sqlite3_busy_timeout(database, 1000)
        // busy_timeout 只约束锁等待。progress handler 才能在一次 sqlite3_step 内部扫描
        // 大量非 assistant 行时响应 Task 取消，不必等找到下一条匹配消息。
        let sqlProgress = SQLProgressContext(handler: progress, bytesTotal: bytesTotal)
        let context = Unmanaged.passUnretained(sqlProgress).toOpaque()
        sqlite3_progress_handler(database, 1000, { raw in
            if let raw { Unmanaged<SQLProgressContext>.fromOpaque(raw).takeUnretainedValue().tick() }
            return Task<Never, Never>.isCancelled ? 1 : 0
        }, context)
        defer { sqlite3_progress_handler(database, 0, nil, nil); withExtendedLifetime(sqlProgress) {} }
        try execute(database, sql: "BEGIN")
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }

        let indexedUpdates = try supportsUpdatedIndex(database)
        var metadata: [MessageRevision] = []
        var bytesRead: Int64 = 0
        if buildIndex && indexedUpdates {
            // 所有消息身份/版本只做轻量元数据比较，JSON 仅为变化行执行。
            // 不依赖最大时间水位，旧日期补录、time_updated 倒退和较晚补齐的 usage 也能发现。
            metadata = try readRevisions(database, bytesRead: &bytesRead, bytesTotal: bytesTotal, progress: progress, sqlProgress: sqlProgress)
        }
        let currentRevisions = Dictionary(metadata.map { ($0.key, $0.revision) }, uniquingKeysWith: { _, latest in latest })
        let changed = metadata.filter { previous?.revisions[$0.key] != $0.revision }
        // 没有 updated 字段时无法可靠识别同长度原位更新，变化库退回全量。
        // 指纹已变但版本元数据完全没变，同样全量核验，兼容外部修库未更新 time_updated。
        let incremental = previous != nil && previous?.hasErrors != true && indexedUpdates && !metadata.isEmpty && !changed.isEmpty
        var records = Dictionary(scan.records.map { ($0.id, $0) }, uniquingKeysWith: { first, latest in
            first.total >= latest.total ? first : latest
        })
        // 完整已观测记录随缓存保留，源消息删除或永久账本写入失败也不会使缓存水位越过数据。
        defer { scan.records = records.values.sorted { $0.id < $1.id } }

        let projection = """
        SELECT id, session_id, time_created,
          CASE WHEN json_valid(data) THEN json_object(
            'role', json_extract(data, '$.role'),
            'providerID', json_extract(data, '$.providerID'),
            'modelID', json_extract(data, '$.modelID'),
            'tokens', json_extract(data, '$.tokens')) ELSE NULL END
        FROM message
        """
        let predicate = incremental ? " WHERE id = ? AND session_id = ?" : " WHERE CASE WHEN json_valid(data) THEN json_extract(data, '$.role') = 'assistant' ELSE 1 END"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, projection + predicate, -1, &statement, nil) == SQLITE_OK else {
            try Task.checkCancellation(); throw ReadError.database
        }
        defer { sqlite3_finalize(statement) }
        let decoder = JSONDecoder()
        let batches: [MessageRevision?] = incremental ? changed.map(Optional.some) : [nil]
        var rows = 0
        for target in batches {
            try Task.checkCancellation()
            if let target {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, target.id, -1, transient)
                sqlite3_bind_text(statement, 2, target.session, -1, transient)
            }
            while true {
                try Task.checkCancellation()
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { try Task.checkCancellation(); throw ReadError.database }
                rows += 1
                guard let id = text(statement, column: 0), !id.isEmpty,
                      let session = text(statement, column: 1), !session.isEmpty,
                      let payload = text(statement, column: 3) else { scan.hasErrors = true; continue }
                bytesRead += Int64(payload.utf8.count)
                sqlProgress.bytesRead = bytesRead
                do {
                    let message = try decoder.decode(Message.self, from: Data(payload.utf8))
                    guard message.role == "assistant", let tokens = message.tokens else { continue }
                    let input = tokens.input
                    let output = tokens.output
                    let cached = (tokens.cache?.read ?? 0) + (tokens.cache?.write ?? 0)
                    let reasoning = tokens.reasoning ?? 0
                    guard input + cached <= TokensLimit.maximum else { throw ReadError.invalidUsage }
                    guard input + output + cached > 0 else { continue }
                    let millis = sqlite3_column_double(statement, 2)
                    guard sqlite3_column_type(statement, 2) != SQLITE_NULL, millis.isFinite, millis > 0 else { throw ReadError.invalidUsage }
                    let model = [message.providerID, message.modelID].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }.joined(separator: "/")
                    let identity = String(decoding: try JSONEncoder().encode([session, id]), as: UTF8.self)
                    let record = ClientUsageRecord(identity: identity, source: .opencode,
                        timestamp: Date(timeIntervalSince1970: millis / 1000), model: model.isEmpty ? "unknown" : model,
                        input: input + cached, output: output, cached: cached, reasoning: reasoning)
                    // 同一消息保留最完整的累计 usage；旧副本或临时回退值不能覆盖已观测完整历史。
                    if records[record.id].map({ $0.total <= record.total }) ?? true { records[record.id] = record }
                } catch { scan.hasErrors = true }
                if rows % 256 == 0 {
                    progress?(ClientUsageProgress(source: .opencode, filesTotal: 1, bytesRead: bytesRead, bytesTotal: bytesTotal))
                }
            }
        }
        scan.records = records.values.sorted { $0.id < $1.id }
        progress?(ClientUsageProgress(source: .opencode, filesCompleted: 1, filesTotal: 1,
                                      bytesRead: bytesRead, bytesTotal: bytesTotal))
        return currentRevisions
    }

    private func supportsUpdatedIndex(_ database: OpaquePointer?) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(message)", -1, &statement, nil) == SQLITE_OK else {
            try Task.checkCancellation(); throw ReadError.database
        }
        defer { sqlite3_finalize(statement) }
        var hasUpdated = false
        var idIsPrimaryKey = false
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { try Task.checkCancellation(); throw ReadError.database }
            let name = text(statement, column: 1)
            if name == "time_updated" { hasUpdated = true }
            if name == "id", sqlite3_column_int(statement, 5) > 0 { idIsPrimaryKey = true }
        }
        return hasUpdated && idIsPrimaryKey
    }

    private func readRevisions(_ database: OpaquePointer?, bytesRead: inout Int64, bytesTotal: Int64,
                               progress: ClientUsageProgressHandler?, sqlProgress: SQLProgressContext) throws -> [MessageRevision] {
        var statement: OpaquePointer?
        let sql = "SELECT id, session_id, time_created, time_updated, length(data) FROM message"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            try Task.checkCancellation(); throw ReadError.database
        }
        defer { sqlite3_finalize(statement) }
        var result: [MessageRevision] = []
        while true {
            try Task.checkCancellation()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { try Task.checkCancellation(); throw ReadError.database }
            guard let id = text(statement, column: 0), let session = text(statement, column: 1),
                  !id.isEmpty, !session.isEmpty else { throw ReadError.invalidUsage }
            guard sqlite3_column_type(statement, 3) == SQLITE_INTEGER else { return [] }
            let revision = OpenCodeClientUsageCache.digest((2...4).map { text(statement, column: Int32($0)) ?? "null" })
            result.append(MessageRevision(id: id, session: session,
                key: try OpenCodeClientUsageCache.messageKey(session: session, id: id), revision: revision))
            bytesRead += Int64(id.utf8.count + session.utf8.count + 24)
            sqlProgress.bytesRead = bytesRead
            if result.count % 256 == 0 {
                progress?(ClientUsageProgress(source: .opencode, filesTotal: 1, bytesRead: bytesRead, bytesTotal: bytesTotal))
            }
        }
        return result
    }

    private func execute(_ database: OpaquePointer?, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            try Task.checkCancellation(); throw ReadError.database
        }
    }

    /// SQLite 在找不到 assistant 行时也定期发出活跃进度；调用方可显示运行状态或取消。
    /// 此上下文只在当前只读连接的执行线程内修改，回调移除后才释放。
    private final class SQLProgressContext {
        let handler: ClientUsageProgressHandler?
        let bytesTotal: Int64
        var ticks = 0
        var bytesRead: Int64 = 0
        init(handler: ClientUsageProgressHandler?, bytesTotal: Int64) {
            self.handler = handler; self.bytesTotal = bytesTotal
        }
        func tick() {
            ticks += 1
            if ticks % 50 == 0 {
                handler?(ClientUsageProgress(source: .opencode, filesTotal: 1, bytesRead: bytesRead, bytesTotal: bytesTotal))
            }
        }
    }

    private func text(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_bytes(statement, column) <= 64 * 1024,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }
    private enum ReadError: Error { case unsafePath, database, invalidUsage }
    private enum TokensLimit { static let maximum = 1_000_000_000_000 }
    private struct Message: Decodable {
        let role: String?
        let providerID: String?
        let modelID: String?
        let tokens: Tokens?
        /// 出现 tokens 对象就要求明确的 input/output；空对象和缺列不是可靠的零用量。
        /// Int 解码拒绝布尔、字符串、小数和非有限值；范围校验拒绝负值及异常大值，
        /// 错误由逐行捕获转为 partial，不再通过钳位把坏记录悄悄变成真实零。
        struct Tokens: Decodable {
            let input: Int
            let output: Int
            let reasoning: Int?
            let cache: Cache?
            enum CodingKeys: String, CodingKey { case input, output, reasoning, cache }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                input = try Self.checked(container.decode(Int.self, forKey: .input))
                output = try Self.checked(container.decode(Int.self, forKey: .output))
                reasoning = container.contains(.reasoning) ? try Self.checked(container.decode(Int.self, forKey: .reasoning)) : nil
                cache = container.contains(.cache) ? try container.decode(Cache.self, forKey: .cache) : nil
            }
            static func checked(_ count: Int) throws -> Int {
                guard count >= 0, count <= TokensLimit.maximum else { throw ReadError.invalidUsage }
                return count
            }
            struct Cache: Decodable {
                let read: Int?
                let write: Int?
                enum CodingKeys: String, CodingKey { case read, write }
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    read = container.contains(.read) ? try Tokens.checked(container.decode(Int.self, forKey: .read)) : nil
                    write = container.contains(.write) ? try Tokens.checked(container.decode(Int.self, forKey: .write)) : nil
                }
            }
        }
    }
}
