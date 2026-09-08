import XCTest
import SQLite3
@testable import Quotio

/// 生产扫描入口的边界测试：所有日志、SQLite 和清理都只作用于临时合成目录。
/// 检查状态结果不携带历史数组，并证明追加、截断、取消后仍可从磁盘恢复完整事实。
final class ClientUsageIncrementalScanTests: XCTestCase {
    private nonisolated final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ClientUsageProgress?
        func store(_ progress: ClientUsageProgress) { lock.lock(); defer { lock.unlock() }; value = progress }
        func read() -> ClientUsageProgress? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotio-incremental-scan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func file(_ root: URL, _ relative: String, content: Data) throws -> URL {
        let path = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: path)
        return path
    }

    private func append(_ data: Data, to path: URL) throws {
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }

    private func codexHeader(_ id: String = "synthetic-session") -> Data {
        Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"timestamp\":\"2026-09-05T10:00:00Z\",\"model\":\"fixture\"}}\n".utf8)
    }

    private func codexUsage(_ total: Int, minute: Int) -> Data {
        Data("{\"type\":\"event_msg\",\"timestamp\":\"2026-09-05T10:\(String(format: "%02d", minute)):00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(total),\"output_tokens\":0,\"total_tokens\":\(total)}}}}\n".utf8)
    }

    private func claudeUsage(_ id: String, output: Int = 5) -> Data {
        Data("{\"type\":\"assistant\",\"timestamp\":\"2026-09-05T10:00:00Z\",\"message\":{\"id\":\"\(id)\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":10,\"output_tokens\":\(output)}}}\n".utf8)
    }

    func testCodexProductionKeepsOnlyWatermarksAndSkipsUnchangedBytes() throws {
        let root = try fixture()
        let log = try file(root, ".codex/sessions/fixture.jsonl", content: codexHeader() + codexUsage(100, minute: 1))
        let store = ClientUsageSQLiteStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let source = CodexClientUsageSource(homeDirectory: root.path, environment: [:])
        let first = try source.collect(cacheStore: store, incremental: true)
        XCTAssertTrue(first.records.isEmpty); XCTAssertTrue(first.codexCheckpoints.isEmpty)
        XCTAssertNil(store.codexCaches, "生产扫描不能在连接上常驻历史检查点")
        let metadata = try store.loadCodexCaches(legacyURL: nil, includeCheckpoints: false)
        XCTAssertEqual(metadata.count, 1); XCTAssertTrue(metadata.values.allSatisfy { $0.checkpoints.isEmpty })
        let progress = ProgressBox()
        _ = try source.collect(cacheStore: store, progress: { progress.store($0) }, incremental: true)
        XCTAssertEqual(progress.read()?.bytesRead, 0); XCTAssertEqual(progress.read()?.filesReused, 1)
        try append(codexUsage(160, minute: 2), to: log)
        let appended = try source.collect(cacheStore: store, incremental: true)
        XCTAssertTrue(appended.codexCheckpoints.isEmpty)
        let checkpoints = try store.loadCheckpoints(scope: "scan:codex:" + CodexUsageFileCache.key(path: log.path))
        XCTAssertEqual(checkpoints.count, 2)
        XCTAssertEqual(CodexClientUsageSource.project(checkpoints: checkpoints).records.map(\.total), [100, 60])
        XCTAssertNil(store.codexCaches)
    }

    func testCodexTruncationAndDeletedSourceKeepPendingHistory() throws {
        let root = try fixture()
        let log = try file(root, ".codex/sessions/fixture.jsonl", content: codexHeader() + codexUsage(100, minute: 1))
        let databaseURL = root.appendingPathComponent("usage.sqlite")
        let store = ClientUsageSQLiteStore(databaseURL: databaseURL)
        let source = CodexClientUsageSource(homeDirectory: root.path, environment: [:])
        _ = try source.collect(cacheStore: store, incremental: true)
        try (codexHeader() + codexUsage(40, minute: 2)).write(to: log)
        _ = try source.collect(cacheStore: store, incremental: true)
        try FileManager.default.removeItem(at: log)
        let reopened = ClientUsageSQLiteStore(databaseURL: databaseURL)
        let missing = try source.collect(cacheStore: reopened, incremental: true)
        XCTAssertTrue(missing.codexCheckpoints.isEmpty)
        let scope = "scan:codex:" + CodexUsageFileCache.key(path: log.path)
        XCTAssertEqual(try reopened.loadCheckpoints(scope: scope).count, 2)
        XCTAssertEqual(try reopened.database.scalarText("SELECT scope FROM client_usage_dirty_scopes"), scope)
    }

    func testClaudeAppendAndTruncationMergeOnDiskWithoutResidentRecords() throws {
        let root = try fixture()
        let log = try file(root, ".claude/projects/fixture/session.jsonl", content: claudeUsage("first"))
        let store = ClientUsageSQLiteStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let source = ClaudeClientUsageSource(homeDirectory: root.path, environment: [:])
        XCTAssertTrue(try source.collect(cacheStore: store, incremental: true).records.isEmpty)
        try append(claudeUsage("first", output: 9) + claudeUsage("second"), to: log)
        _ = try source.collect(cacheStore: store, incremental: true)
        try claudeUsage("third").write(to: log)
        _ = try source.collect(cacheStore: store, incremental: true)
        // macOS 临时 URL 的 path 可能使用 /var，而目录枚举返回 /private/var。
        // 旧扫描键沿用枚举所得路径；断言按真实扫描路径查询，不能对写夹具的 URL 另算一个键。
        let scannedPath = try XCTUnwrap(ClientUsageFiles.jsonlFiles(roots: [root.appendingPathComponent(".claude/projects").path]).first)
        let records = try store.loadRecords(scope: "scan:claude:" + ClaudeClientUsageReader.key(for: scannedPath))
        XCTAssertEqual(records.count, 3); XCTAssertEqual(records.map(\.output).sorted(), [5, 5, 9])
        XCTAssertTrue(store.lineCaches.isEmpty)
        XCTAssertTrue(try store.loadLineCache(source: .claude, legacyURL: nil, includeRecords: false).files.values.allSatisfy { $0.records.isEmpty })
    }

    func testPiProductionUsesNativeUsageAndDoesNotReturnLedgerRecords() throws {
        let root = try fixture()
        let content = Data("{\"type\":\"message\",\"id\":\"fixture-message\",\"timestamp\":\"2026-09-05T10:00:00Z\",\"message\":{\"role\":\"assistant\",\"model\":\"fixture\",\"provider\":\"fixture\",\"usage\":{\"input\":10,\"output\":5,\"cacheRead\":2,\"cacheWrite\":3}}}\n".utf8)
        _ = try file(root, ".pi/agent/sessions/fixture/session.jsonl", content: content)
        let store = ClientUsageSQLiteStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let scan = try PiClientUsageSource(homeDirectory: root.path, environment: [:]).collect(cacheStore: store, incremental: true)
        XCTAssertFalse(scan.hasErrors); XCTAssertTrue(scan.records.isEmpty)
        let scannedPath = try XCTUnwrap(ClientUsageFiles.jsonlFiles(roots: [root.appendingPathComponent(".pi/agent/sessions").path]).first)
        XCTAssertEqual(try store.loadRecords(scope: "scan:pi:" + ClaudeClientUsageReader.key(for: scannedPath)).first?.total, 20)
        XCTAssertTrue(store.lineCaches.isEmpty)
    }

    func testCancellationAfterCompletedFileLeavesDurablePendingInput() async throws {
        let root = try fixture()
        _ = try file(root, ".claude/projects/fixture/a.jsonl", content: claudeUsage("first"))
        _ = try file(root, ".claude/projects/fixture/b.jsonl", content: claudeUsage("second"))
        let databaseURL = root.appendingPathComponent("usage.sqlite")
        let task = Task.detached {
            let store = ClientUsageSQLiteStore(databaseURL: databaseURL)
            return try ClaudeClientUsageSource(homeDirectory: root.path, environment: [:]).collect(cacheStore: store, progress: { progress in
                if progress.filesCompleted >= 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }, incremental: true)
        }
        // 字节进度有限流，第二个文件可能先完成；取消只要求已提交事实和待处理标记始终匹配。
        do { _ = try await task.value; XCTFail("扫描进度中的取消应向上传递") }
        catch is CancellationError { }
        let reopened = ClientUsageSQLiteStore(databaseURL: databaseURL)
        try reopened.prepare()
        XCTAssertGreaterThan(try reopened.database.scalarInt("SELECT COUNT(*) FROM client_usage_records WHERE scope LIKE 'scan:claude:%'") ?? 0, 0)
        XCTAssertGreaterThan(try reopened.database.scalarInt("SELECT COUNT(*) FROM client_usage_dirty_scopes") ?? 0, 0)
        let result = try ClaudeClientUsageSource(homeDirectory: root.path, environment: [:]).collect(cacheStore: reopened, incremental: true)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(try reopened.database.scalarInt("SELECT COUNT(*) FROM client_usage_records WHERE scope LIKE 'scan:claude:%'"), 2)
    }

    func testOpenCodeProductionStreamsRevisionsAndRetainsDeletedMessages() throws {
        let root = try fixture()
        let path = try file(root, ".local/share/opencode/opencode.db", content: Data())
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                XCTFail(String(cString: sqlite3_errmsg(database))); throw NSError(domain: "fixture", code: 1)
            }
        }
        try execute("CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT)")
        try execute("INSERT INTO message VALUES('first','session',1760000000000,1,'{\"role\":\"assistant\",\"tokens\":{\"input\":10,\"output\":5}}')")
        let store = ClientUsageSQLiteStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let source = OpenCodeClientUsageSource(homeDirectory: root.path, environment: [:])
        XCTAssertTrue(try source.collect(cacheStore: store, incremental: true).records.isEmpty)
        XCTAssertNil(store.openCodeCache); XCTAssertFalse(store.openCodeLoaded)
        try execute("UPDATE message SET time_updated=2,data='{\"role\":\"assistant\",\"tokens\":{\"input\":10,\"output\":9}}' WHERE id='first'")
        XCTAssertFalse(try source.collect(cacheStore: store, incremental: true).hasErrors)
        XCTAssertEqual(try store.loadRecords(scope: "scan:opencode").first?.total, 19)
        // 长度与 time_updated 都不变，文件指纹变化仍触发兜底核验，不能漏掉外部修库。
        try execute("UPDATE message SET data='{\"role\":\"assistant\",\"tokens\":{\"input\":11,\"output\":9}}' WHERE id='first'")
        _ = try source.collect(cacheStore: store, incremental: true)
        XCTAssertEqual(try store.loadRecords(scope: "scan:opencode").first?.total, 20)
        try execute("DELETE FROM message")
        _ = try source.collect(cacheStore: store, incremental: true)
        XCTAssertEqual(try store.loadRecords(scope: "scan:opencode").count, 1)
        XCTAssertNil(store.openCodeCache)
    }

    func testOpenCodeCancelledBatchKeepsRecordsWithoutAdvancingFingerprint() async throws {
        let root = try fixture()
        let path = try file(root, ".local/share/opencode/opencode.db", content: Data())
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT)", nil, nil, nil), SQLITE_OK)
        let rows = """
            WITH RECURSIVE fixture(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM fixture WHERE n<600)
            INSERT INTO message SELECT 'fixture-'||n,'session',1760000000000,1,
              '{"role":"assistant","tokens":{"input":10,"output":5}}' FROM fixture
            """
        XCTAssertEqual(sqlite3_exec(database, rows, nil, nil, nil), SQLITE_OK)
        let databaseURL = root.appendingPathComponent("usage.sqlite")
        let task = Task.detached {
            let store = ClientUsageSQLiteStore(databaseURL: databaseURL)
            return try OpenCodeClientUsageSource(homeDirectory: root.path, environment: [:]).collect(cacheStore: store, progress: { progress in
                // 每 256 行落盘后的进度触发取消，验证已完成批次和最终指纹有不同提交边界。
                if progress.bytesRead > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }, incremental: true)
        }
        do { _ = try await task.value; XCTFail("扫描取消应向上传递") }
        catch is CancellationError { }
        let reopened = ClientUsageSQLiteStore(databaseURL: databaseURL)
        try reopened.prepare()
        XCTAssertEqual(try reopened.loadRecords(scope: "scan:opencode").count, 256)
        XCTAssertNil(try reopened.loadOpenCodeCache(legacyURL: nil, includeRecords: false))
        XCTAssertEqual(try reopened.database.scalarText("SELECT scope FROM client_usage_dirty_scopes"), "scan:opencode")
        _ = try OpenCodeClientUsageSource(homeDirectory: root.path, environment: [:]).collect(cacheStore: reopened, incremental: true)
        XCTAssertEqual(try reopened.loadRecords(scope: "scan:opencode").count, 600)
        XCTAssertNil(reopened.openCodeCache)
    }
}
