import XCTest
import SQLite3
@testable import Quotio

/// 每项测试创建真实临时 SQLite，数据库及 WAL 留在沙箱临时目录；不访问用户 OpenCode 会话。
final class OpenCodeClientUsageTests: XCTestCase {
    private func withDatabase(_ body: (URL, URL, OpaquePointer) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-usage-\(UUID().uuidString)")
        let directory = home.appendingPathComponent(".local/share/opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        let database = try XCTUnwrap(db)
        defer { sqlite3_close(database); try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)", nil, nil, nil), SQLITE_OK)
        try body(home, path, database)
    }

    private func insert(_ database: OpaquePointer, id: String = "message-1", session: String = "session-1", json: String) throws {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO message(id,session_id,time_created,data) VALUES(?,?,1760000000000,?)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        sqlite3_bind_text(statement, 2, session, -1, transient)
        sqlite3_bind_text(statement, 3, json, -1, transient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private let usage = #"{"role":"assistant","providerID":"aiusage","modelID":"model-a","tokens":{"input":100,"output":40,"reasoning":10,"cache":{"read":20,"write":5}},"text":"PRIVATE MESSAGE BODY"}"#

    func testReadsCommittedWALAndNormalizesCacheWithoutAddingReasoningTwice() throws {
        try withDatabase { home, _, db in
            XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0", nil, nil, nil), SQLITE_OK)
            try insert(db, json: usage)
            let result = try OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:]).collect()
            XCTAssertTrue(result.available)
            XCTAssertFalse(result.hasErrors)
            XCTAssertEqual(result.filesScanned, 1)
            let record = try XCTUnwrap(result.records.first)
            XCTAssertEqual(record.model, "aiusage/model-a")
            XCTAssertEqual(record.input, 125)
            XCTAssertEqual(record.cached, 25)
            XCTAssertEqual(record.output, 40)
            XCTAssertEqual(record.reasoning, 10)
            XCTAssertEqual(record.total, 165)
            let encoded = try JSONEncoder().encode(record)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PRIVATE MESSAGE BODY"))
        }
    }

    func testRepeatedScansKeepMessageIdentityAndSessionDisambiguatesIt() throws {
        try withDatabase { home, _, db in
            try insert(db, json: usage)
            let source = OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:])
            let first = try XCTUnwrap(source.collect().records.first)
            let repeated = try XCTUnwrap(source.collect().records.first)
            XCTAssertEqual(first.id, repeated.id)
            XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET session_id='another-session'", nil, nil, nil), SQLITE_OK)
            let changed = try XCTUnwrap(source.collect().records.first)
            XCTAssertNotEqual(first.id, changed.id)
            XCTAssertFalse(first.id.contains("message-1"))
        }
    }

    func testSkipsNonAssistantAndMissingOrZeroUsage() throws {
        try withDatabase { home, _, db in
            try insert(db, id: "user", json: #"{"role":"user","tokens":{"input":100}}"#)
            try insert(db, id: "user-malformed-usage", json: #"{"role":"user","tokens":"not-assistant-usage"}"#)
            try insert(db, id: "missing", json: #"{"role":"assistant"}"#)
            try insert(db, id: "zero", json: #"{"role":"assistant","tokens":{"input":0,"output":0}}"#)
            let result = try OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:]).collect()
            XCTAssertTrue(result.available)
            XCTAssertFalse(result.hasErrors)
            XCTAssertTrue(result.records.isEmpty)
        }
    }

    func testMalformedRowPreservesValidRecordsAndReportsPartialError() throws {
        try withDatabase { home, _, db in
            try insert(db, json: usage)
            try insert(db, id: "malformed", json: "{broken")
            let result = try OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:]).collect()
            XCTAssertEqual(result.records.count, 1)
            XCTAssertTrue(result.hasErrors)
        }
    }

    func testMissingDatabaseAndBrokenSchemaHaveDifferentStatuses() throws {
        try withDatabase { home, _, db in
            let missing = try OpenCodeClientUsageSource(homeDirectory: home.appendingPathComponent("missing").path, environment: [:]).collect()
            XCTAssertFalse(missing.available)
            XCTAssertFalse(missing.hasErrors)
            XCTAssertEqual(sqlite3_exec(db, "DROP TABLE message", nil, nil, nil), SQLITE_OK)
            let broken = try OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:]).collect()
            XCTAssertTrue(broken.available)
            XCTAssertTrue(broken.hasErrors)
            XCTAssertTrue(broken.records.isEmpty)
        }
    }

    func testRejectsDatabaseAndWALSymbolicLinks() throws {
        try withDatabase { home, path, db in
            try insert(db, json: usage)
            let sidecar = URL(fileURLWithPath: path.path + "-wal")
            try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: path)
            let source = OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:])
            let badWAL = try source.collect()
            XCTAssertTrue(badWAL.hasErrors)
            XCTAssertTrue(badWAL.records.isEmpty)
            try FileManager.default.removeItem(at: sidecar)
            let xdg = home.appendingPathComponent("xdg/opencode")
            try FileManager.default.createDirectory(at: xdg, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: xdg.appendingPathComponent("opencode.db"), withDestinationURL: path)
            let badDB = try OpenCodeClientUsageSource(homeDirectory: home.path, environment: ["XDG_DATA_HOME": home.appendingPathComponent("xdg").path]).collect()
            XCTAssertTrue(badDB.available)
            XCTAssertTrue(badDB.hasErrors)
            XCTAssertTrue(badDB.records.isEmpty)
        }
    }

    func testXDGAndApplicationSupportDiscovery() throws {
        try withDatabase { home, path, db in
            try insert(db, json: usage)
            // 测试副本仅包含合成夹具，用来模拟两个支持的安装目录；生产采集不会复制数据库。
            let xdg = home.appendingPathComponent("xdg/opencode")
            try FileManager.default.createDirectory(at: xdg, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: path, to: xdg.appendingPathComponent("opencode.db"))
            let xdgResult = try OpenCodeClientUsageSource(homeDirectory: home.appendingPathComponent("absent").path,
                environment: ["XDG_DATA_HOME": home.appendingPathComponent("xdg").path]).collect()
            XCTAssertEqual(xdgResult.records.count, 1)
            let supportHome = home.appendingPathComponent("desktop")
            let support = supportHome.appendingPathComponent("Library/Application Support/opencode")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: path, to: support.appendingPathComponent("opencode.db"))
            let supportResult = try OpenCodeClientUsageSource(homeDirectory: supportHome.path, environment: [:]).collect()
            XCTAssertEqual(supportResult.records.count, 1)
        }
    }
    func testOnlyInvalidCountersReportPartialInsteadOfReliableZero() throws {
        try withDatabase { home, _, db in
            // 包括负数、布尔、字符串、小数、越界值；任何一个都不能钳位成成功读取的零。
            let invalidInputs = ["-1", "true", "\"12\"", "1.5", "1000000000001", "1e999"]
            for (index, input) in invalidInputs.enumerated() {
                XCTAssertEqual(sqlite3_exec(db, "DELETE FROM message", nil, nil, nil), SQLITE_OK)
                try insert(db, id: "invalid-\(index)", json: "{\"role\":\"assistant\",\"tokens\":{\"input\":\(input),\"output\":0}}")
                let result = try OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:]).collect()
                XCTAssertTrue(result.available)
                XCTAssertTrue(result.hasErrors, "非法计数 \(input) 不能被标为可靠零")
                XCTAssertTrue(result.records.isEmpty)
            }
        }
    }

    func testInvalidUsageRetainsValidPeerAndRejectsMissingRequiredCounters() throws {
        try withDatabase { home, _, db in
            try insert(db, json: usage)
            try insert(db, id: "empty-tokens", json: #"{"role":"assistant","tokens":{}}"#)
            try insert(db, id: "missing-output", json: #"{"role":"assistant","tokens":{"input":50}}"#)
            try insert(db, id: "bad-cache", json: #"{"role":"assistant","tokens":{"input":0,"output":0,"cache":{"read":-1}}}"#)
            try insert(db, id: "bad-reasoning", json: #"{"role":"assistant","tokens":{"input":0,"output":0,"reasoning":true}}"#)
            let result = try OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:]).collect()
            XCTAssertTrue(result.hasErrors)
            XCTAssertEqual(result.records.count, 1)
            XCTAssertEqual(result.records.first?.total, 165)
        }
    }

    func testNormalizedInputOverflowIsAnErrorInsteadOfSilentTruncation() throws {
        try withDatabase { home, _, db in
            try insert(db, json: #"{"role":"assistant","tokens":{"input":1000000000000,"output":0,"cache":{"read":1}}}"#)
            let result = try OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:]).collect()
            XCTAssertTrue(result.hasErrors)
            XCTAssertTrue(result.records.isEmpty)
        }
    }

    func testUnchangedCacheReplaysRecordsWithoutReadingJSONAndCanReopen() throws {
        try withDatabase { home, _, db in
            try insert(db, json: usage)
            let cache = home.appendingPathComponent("cache/opencode.json")
            let first = try OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:]).collect(cacheURL: cache)
            let progress = ProgressCapture()
            // 新建 source 模拟应用重启；索引必须同时携带记录，不能只保存水位导致账本遗漏。
            let second = try OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:])
                .collect(cacheURL: cache, progress: { progress.append($0) })
            XCTAssertEqual(first.records, second.records)
            XCTAssertEqual(second.records.count, 1)
            XCTAssertEqual(progress.last?.filesReused, 1)
            XCTAssertEqual(progress.last?.bytesRead, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path), "新扫描不再创建 JSON 索引")
            let store = ClientUsageSQLiteStore(databaseURL: AnalyticsDatabase.storeURL(forLegacyURL: cache))
            let data = try JSONEncoder().encode(try store.loadOpenCodeCache(legacyURL: nil))
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("PRIVATE MESSAGE BODY"))
            XCTAssertFalse(text.contains("message-1"))
            XCTAssertFalse(text.contains("session-1"))
            XCTAssertFalse(text.contains(home.path))
        }
    }

    func testUpdatedSchemaReadsOnlyChangedJSONAndIncludesOldDatedBackfill() throws {
        try withDatabase { home, _, db in
            XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE message ADD COLUMN time_updated INTEGER NOT NULL DEFAULT 1", nil, nil, nil), SQLITE_OK)
            for index in 0..<300 { try insert(db, id: "message-\(index)", json: usage) }
            let cache = home.appendingPathComponent("cache/opencode.json")
            let source = OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:])
            let firstProgress = ProgressCapture()
            _ = try source.collect(cacheURL: cache, progress: { firstProgress.append($0) })
            try insert(db, id: "late-old-message", json: usage)
            XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET time_created=1000,time_updated=0 WHERE id='late-old-message'", nil, nil, nil), SQLITE_OK)
            let secondProgress = ProgressCapture()
            let appended = try source.collect(cacheURL: cache, progress: { secondProgress.append($0) })
            XCTAssertFalse(appended.hasErrors)
            XCTAssertEqual(appended.records.count, 301)
            XCTAssertLessThan(try XCTUnwrap(secondProgress.last?.bytesRead), try XCTUnwrap(firstProgress.last?.bytesRead))
            XCTAssertTrue(appended.records.contains { $0.timestamp.timeIntervalSince1970 == 1 })
            // 旧消息 time_updated 可以倒退：逐条 revision 比较不能只看全库最大水位。
            XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET time_updated=0,data=json_set(data,'$.tokens.output',90) WHERE id='message-0'", nil, nil, nil), SQLITE_OK)
            let updated = try source.collect(cacheURL: cache)
            XCTAssertEqual(updated.records.count, 301)
            XCTAssertEqual(updated.records.filter { $0.output == 90 }.count, 1)
        }
    }

    func testUnmarkedSameLengthUpdateAndLegacySchemaSafelyFallBack() throws {
        try withDatabase { home, _, db in
            try insert(db, json: usage)
            let cache = home.appendingPathComponent("cache/opencode.json")
            let source = OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:])
            _ = try source.collect(cacheURL: cache)
            XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET data=json_set(data,'$.tokens.output',60)", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(try source.collect(cacheURL: cache).records.first?.output, 60)
            XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE message ADD COLUMN time_updated INTEGER NOT NULL DEFAULT 1", nil, nil, nil), SQLITE_OK)
            _ = try source.collect(cacheURL: cache)
            XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET data=json_set(data,'$.tokens.output',70)", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(try source.collect(cacheURL: cache).records.first?.output, 70)
        }
    }

    func testDatabaseReplacementInvalidatesCachedFileIdentity() throws {
        try withDatabase { home, path, db in
            try insert(db, json: usage)
            let cache = home.appendingPathComponent("cache/opencode.json")
            let source = OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:])
            _ = try source.collect(cacheURL: cache)
            try FileManager.default.moveItem(at: path, to: path.deletingLastPathComponent().appendingPathComponent("old.db"))
            var replacement: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path.path, &replacement), SQLITE_OK)
            let newDB = try XCTUnwrap(replacement)
            defer { sqlite3_close(newDB) }
            XCTAssertEqual(sqlite3_exec(newDB, "CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)", nil, nil, nil), SQLITE_OK)
            try insert(newDB, id: "replacement-message", json: usage)
            let progress = ProgressCapture()
            let replaced = try source.collect(cacheURL: cache, progress: { progress.append($0) })
            XCTAssertFalse(replaced.hasErrors)
            XCTAssertEqual(replaced.records.count, 2)
            let reopened = try OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:]).collect(cacheURL: cache)
            XCTAssertEqual(reopened.records.count, 2, "替换后的缓存仍应重放旧库和新库的历史")
            XCTAssertEqual(progress.last?.filesReused, 0)
            XCTAssertGreaterThan(progress.last?.bytesRead ?? 0, 0)
        }
    }

    func testSQLiteProgressHandlerCancelsDuringLargeNonAssistantScan() async throws {
        // 没有 assistant 匹配行时，forEachRow 外层根本不会拿到 SQLITE_ROW。
        // 第二次进度来自 SQLite VM 内部而非文件启动，因此取消必须在 sqlite3_step 内生效。
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-cancel-\(UUID().uuidString)")
        let directory = home.appendingPathComponent(".local/share/opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("opencode.db").path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_close(db); try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,time_created INTEGER,data TEXT)", nil, nil, nil), SQLITE_OK)
        let sql = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<50000) INSERT INTO message SELECT 'm-'||x,'s',1760000000000,'{\"role\":\"user\",\"text\":\"synthetic fixture\"}' FROM n"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let cancellation = ScanCancellation()
        let task = Task.detached {
            try OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:]).collect(progress: { _ in cancellation.progress() })
        }
        cancellation.install(task)
        do { _ = try await task.value; XCTFail("SQLite 内部扫描应响应取消") }
        catch is CancellationError { }
        XCTAssertTrue(cancellation.didCancel)
    }

    private final class ProgressCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ClientUsageProgress] = []
        func append(_ value: ClientUsageProgress) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var last: ClientUsageProgress? { lock.lock(); defer { lock.unlock() }; return values.last }
    }
    private final class ScanCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<ClientUsageScan, Error>?
        private var calls = 0
        private var cancelled = false
        func install(_ task: Task<ClientUsageScan, Error>) { lock.lock(); defer { lock.unlock() }; self.task = task }
        func progress() {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            if calls > 1, let task { task.cancel(); cancelled = true }
        }
        var didCancel: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    func testCacheReplaysUncommittedHistoryAfterSourceDatabaseDisappears() throws {
        try withDatabase { home, path, db in
            try insert(db, json: usage)
            let cache = home.appendingPathComponent("cache/opencode.json")
            // 仅调用来源缓存，没有执行 Engine.merge，复现缓存到永久账本之间被取消的边界。
            let initial = try OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:]).collect(cacheURL: cache)
            try FileManager.default.removeItem(at: path)
            let reopened = try OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:]).collect(cacheURL: cache)
            XCTAssertFalse(reopened.available)
            XCTAssertFalse(reopened.hasErrors)
            XCTAssertEqual(reopened.filesScanned, 0)
            XCTAssertEqual(reopened.records, initial.records)
            XCTAssertEqual(reopened.records.first?.total, 165)
        }
    }

    func testDeletedRowsKeepCachedHistoryAndLowerUsageCannotReplaceCompleteRecord() throws {
        try withDatabase { home, _, db in
            try insert(db, json: usage)
            let cache = home.appendingPathComponent("cache/opencode.json")
            let source = OpenCodeClientUsageSource(homeDirectory: home.path, environment: [:])
            let initial = try source.collect(cacheURL: cache)
            XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET data=json_set(data,'$.tokens.output',1)", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(try source.collect(cacheURL: cache).records, initial.records)
            XCTAssertEqual(sqlite3_exec(db, "DELETE FROM message", nil, nil, nil), SQLITE_OK)
            let deleted = try source.collect(cacheURL: cache)
            XCTAssertTrue(deleted.available)
            XCTAssertEqual(deleted.records, initial.records)
            let store = ClientUsageSQLiteStore(databaseURL: AnalyticsDatabase.storeURL(forLegacyURL: cache))
            let index = try XCTUnwrap(store.loadOpenCodeCache(legacyURL: nil))
            XCTAssertTrue(index.revisions.isEmpty)
            XCTAssertEqual(index.records, initial.records)
        }
    }

}
