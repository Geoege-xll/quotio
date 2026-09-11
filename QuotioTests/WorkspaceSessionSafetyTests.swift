import XCTest
import SQLite3
@testable import Quotio

/// 所有会话、数据库和故障场景都创建于独立临时 home，禁止触碰本机客户端记录。
final class WorkspaceSessionSafetyTests: XCTestCase {
    private var home: URL!
    private let files = FileManager.default

    override func setUpWithError() throws {
        home = files.temporaryDirectory.appendingPathComponent("WorkspaceSessionSafety-\(UUID().uuidString)").resolvingSymlinksInPath()
        try files.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try files.removeItem(at: home) }

    private func write(_ relative: String, _ text: String = "fixture") throws -> String {
        let url = home.appendingPathComponent(relative)
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func session(_ id: String = "p", agent: WorkspaceAgent = .codex, path: String, cwd: String? = nil) -> WorkspaceSession {
        WorkspaceSession(id: id, agent: agent, title: "fixture", projectDirectory: cwd, projectName: "fixture", lastActiveAt: Date(), filePath: path, fileSizeBytes: 0, messageCount: 0, resumeCommand: "echo untrusted-metadata")
    }

    private func execute(_ path: String, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw NSError(domain: "fixture", code: 1) }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
        }
    }

    private func count(_ path: String, table: String = "threads") throws -> Int {
        let database = try WorkspaceSessionDatabase(path: path)
        return Int(try database.rows("SELECT COUNT(*) FROM \(table)")[0][0] ?? "-1") ?? -1
    }

    private func codexFixture(childPath: String? = nil, cycle: Bool = false) throws -> (database: String, paths: [String]) {
        let paths = try ["p", "c", "g"].map { try write(".codex/sessions/\($0).jsonl", "正文-\($0)") }
        let database = home.appendingPathComponent(".codex/state_5.sqlite").path
        // 刻意不建可选 artifacts/tools 表，验证旧版本数据库仍可安全级联删除。
        try execute(database, """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, source TEXT);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT PRIMARY KEY);
        INSERT INTO threads VALUES ('p', '\(paths[0])', 'cli');
        INSERT INTO threads VALUES ('c', '\(childPath ?? paths[1])', 'subagent');
        INSERT INTO threads VALUES ('g', '\(paths[2])', 'subagent');
        INSERT INTO thread_spawn_edges VALUES ('p', 'c');
        INSERT INTO thread_spawn_edges VALUES ('c', 'g');
        \(cycle ? "INSERT INTO thread_spawn_edges VALUES ('g', 'p');" : "")
        """)
        return (database, paths)
    }

    private func assertNoQuarantine() {
        let pending = files.enumerator(atPath: home.path)?.allObjects.compactMap { $0 as? String }.filter { $0.contains(".quotio-session-delete-") } ?? []
        XCTAssertTrue(pending.isEmpty, "故障回滚后不应遗留隔离正文")
    }

    func testClaudeResumeUsesOptionAndQuotesUntrustedArguments() {
        let identifier = "id'; echo injected; '"
        let command = WorkspaceSessionCommandBuilder.resumeCommand(agent: .claude, id: identifier)
        XCTAssertEqual(command, "'claude' '--resume' " + WorkspaceSessionCommandBuilder.quote(identifier))
        let record = session(identifier, agent: .claude, path: "/unused.jsonl")
        let terminal = WorkspaceSessionCommandBuilder.terminalCommand(session: record, homeDirectory: "/tmp/user home")
        XCTAssertEqual(terminal, "cd -- '/tmp/user home' && " + command)
        XCTAssertFalse(terminal.contains("untrusted-metadata"))
        XCTAssertFalse(terminal.contains("cd '~'"))
    }

    func testPiMessageParentsAreNotSessionParentsAndMessagesDecode() async throws {
        let identifier = "11111111-1111-4111-8111-111111111111"
        _ = try write(".pi/agent/sessions/project/2026-09-11_\(identifier).jsonl", """
        {"type":"session","version":3,"id":"\(identifier)","timestamp":"2026-09-11T10:00:00.123Z","cwd":"/tmp/project"}
        {"type":"message","id":"entry001","parentId":null,"timestamp":"2026-09-11T10:00:01.123Z","message":{"role":"user","content":"检查中文消息"}}
        {"type":"message","id":"entry002","parentId":"entry001","timestamp":"2026-09-11T10:00:02.123Z","message":{"role":"assistant","content":[{"type":"text","text":"正常回复"}]}}
        """)
        let provider = PiSessionProvider(homeDir: home.path)
        let records = await provider.scanSessions()
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertFalse(record.isSubagent)
        XCTAssertNil(record.parentSessionID)
        XCTAssertEqual(record.title, "检查中文消息")
        XCTAssertNotNil(record.createdAt)
        let messages = try await provider.loadMessages(for: record)
        XCTAssertEqual(messages.map(\.content), ["检查中文消息", "正常回复"])
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.map(\.id), ["entry001", "entry002"])
    }

    func testPiParentSessionPathNormalizesToUUID() async throws {
        let parentID = "11111111-1111-4111-8111-111111111111"
        _ = try write(".pi/sessions/fork.jsonl", """
        {"type":"session","version":3,"id":"22222222-2222-4222-8222-222222222222","timestamp":"2026-09-11T10:00:00Z","cwd":"/tmp/project","parentSession":"/tmp/2026-09-11_\(parentID).jsonl"}
        """)
        let records = await PiSessionProvider(homeDir: home.path).scanSessions()
        XCTAssertEqual(records.first?.parentSessionID, parentID)
    }

    func testCodexDeletesThreeLevelsAndLeavesHistoricalDatabaseUntouched() async throws {
        let fixture = try codexFixture()
        let backup = home.appendingPathComponent(".codex/state_4.sqlite").path
        try files.copyItem(atPath: fixture.database, toPath: backup)
        let success = try await CodexSessionProvider(homeDir: home.path).deleteSession(session(path: fixture.paths[0]))
        XCTAssertTrue(success)
        XCTAssertEqual(try count(fixture.database), 0)
        XCTAssertEqual(try count(backup), 3)
        XCTAssertEqual(try count(fixture.database, table: "thread_spawn_edges"), 0)
        for path in fixture.paths { XCTAssertFalse(files.fileExists(atPath: path)) }
        assertNoQuarantine()
    }

    func testCodexCycleTerminatesAndDeletesEachRecordOnce() async throws {
        let fixture = try codexFixture(cycle: true)
        let success = try await CodexSessionProvider(homeDir: home.path).deleteSession(session(path: fixture.paths[0]))
        XCTAssertTrue(success)
        XCTAssertEqual(try count(fixture.database), 0)
        for path in fixture.paths { XCTAssertFalse(files.fileExists(atPath: path)) }
    }

    func testCleanupTransactionRejectsNewDatabaseDescendantAfterConstraintWasFrozen() throws {
        let path = try write(".codex/sessions/parent.jsonl", "old parent")
        let database = home.appendingPathComponent(".codex/state_5.sqlite").path
        try execute(database, """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, source TEXT, updated_at INTEGER);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT PRIMARY KEY);
        INSERT INTO threads VALUES ('parent', '\(path)', 'cli', 1600000000);
        """)
        let parent = WorkspaceSession(id: "parent", agent: .codex, title: "parent", projectName: "fixture",
                                      lastActiveAt: Date(timeIntervalSince1970: 1600000000), filePath: path,
                                      fileSizeBytes: 0, messageCount: 1, resumeCommand: "")
        let constraint = try WorkspaceSessionCleanupConstraint(sessions: [parent], cutoff: Date(), homeDirectory: home.path)
        let child = try write(".codex/sessions/child.jsonl", "new active child")
        try execute(database, "INSERT INTO threads VALUES ('child', '\(child)', 'subagent', 2100000000); INSERT INTO thread_spawn_edges VALUES ('parent', 'child');")
        // 直接调用引擎，证明防护不只是 service 的一次异步复扫，而是在写事务内仍生效。
        XCTAssertThrowsError(try WorkspaceSessionDeletionEngine.delete(parent, expectedAgent: .codex, homeDirectory: home.path,
                                                                       relatedSessions: [parent], cleanupConstraint: constraint))
        XCTAssertEqual(try count(database), 2)
        XCTAssertTrue(files.fileExists(atPath: path))
        XCTAssertTrue(files.fileExists(atPath: child))
        assertNoQuarantine()
    }

    func testCleanupTransactionRejectsReactivatedDatabaseRecord() throws {
        let path = try write(".codex/sessions/parent.jsonl", "old parent")
        let database = home.appendingPathComponent(".codex/state_5.sqlite").path
        try execute(database, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, source TEXT, updated_at INTEGER); INSERT INTO threads VALUES ('parent', '\(path)', 'cli', 1600000000);")
        let parent = WorkspaceSession(id: "parent", agent: .codex, title: "parent", projectName: "fixture",
                                      lastActiveAt: Date(timeIntervalSince1970: 1600000000), filePath: path,
                                      fileSizeBytes: 0, messageCount: 1, resumeCommand: "")
        let constraint = try WorkspaceSessionCleanupConstraint(sessions: [parent], cutoff: Date(), homeDirectory: home.path)
        try execute(database, "UPDATE threads SET updated_at=2100000000 WHERE id='parent';")
        XCTAssertThrowsError(try WorkspaceSessionDeletionEngine.delete(parent, expectedAgent: .codex, homeDirectory: home.path,
                                                                       relatedSessions: [parent], cleanupConstraint: constraint))
        XCTAssertEqual(try count(database), 1)
        XCTAssertTrue(files.fileExists(atPath: path))
    }

    func testCleanupFileSnapshotRejectsNewSidecarBeforeDeletingAnyOriginalFile() throws {
        let path = try write(".claude/projects/test/parent.jsonl", "old parent")
        let parent = WorkspaceSession(id: "parent", agent: .claude, title: "parent", projectName: "fixture",
                                      lastActiveAt: Date(timeIntervalSince1970: 1600000000), filePath: path,
                                      fileSizeBytes: 0, messageCount: 1, resumeCommand: "")
        let constraint = try WorkspaceSessionCleanupConstraint(sessions: [parent], cutoff: Date(), homeDirectory: home.path)
        let newFile = try write(".claude/projects/test/parent/subagents/new-child.jsonl", "new child")
        XCTAssertThrowsError(try WorkspaceSessionDeletionEngine.delete(parent, expectedAgent: .claude, homeDirectory: home.path,
                                                                       relatedSessions: [parent], cleanupConstraint: constraint))
        XCTAssertTrue(files.fileExists(atPath: path))
        XCTAssertTrue(files.fileExists(atPath: newFile))
        assertNoQuarantine()
    }

    func testCodexDatabaseWriteLockDoesNotRemoveAnyFile() async throws {
        let fixture = try codexFixture()
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database, &blocker), SQLITE_OK)
        defer { sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil); sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        do {
            _ = try await CodexSessionProvider(homeDir: home.path).deleteSession(session(path: fixture.paths[0]))
            XCTFail("数据库被写锁占用时必须返回失败")
        } catch { }
        for path in fixture.paths { XCTAssertTrue(files.fileExists(atPath: path)) }
        assertNoQuarantine()
    }

    func testCodexSQLFailureRestoresFilesAndDatabaseRows() async throws {
        let fixture = try codexFixture()
        try execute(fixture.database, "CREATE TRIGGER refuse_delete BEFORE DELETE ON threads BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;")
        do {
            _ = try await CodexSessionProvider(homeDir: home.path).deleteSession(session(path: fixture.paths[0]))
            XCTFail("SQL 失败不能报告删除成功")
        } catch { }
        XCTAssertEqual(try count(fixture.database), 3)
        XCTAssertEqual(try count(fixture.database, table: "thread_spawn_edges"), 2)
        for path in fixture.paths { XCTAssertTrue(files.fileExists(atPath: path)) }
        assertNoQuarantine()
    }

    func testUnsafeDescendantPreflightLeavesParentAndDatabaseIntact() async throws {
        let outside = try write("Documents/sentinel.jsonl", "必须保留")
        let fixture = try codexFixture(childPath: outside)
        do {
            _ = try await CodexSessionProvider(homeDir: home.path).deleteSession(session(path: fixture.paths[0]))
            XCTFail("子会话越界必须在任何删除前失败")
        } catch { }
        XCTAssertEqual(try count(fixture.database), 3)
        for path in fixture.paths + [outside] { XCTAssertTrue(files.fileExists(atPath: path)) }
        assertNoQuarantine()
    }

    func testDirectoryMasqueradingAsRolloutIsRejected() async throws {
        let directory = home.appendingPathComponent(".codex/sessions/directory.jsonl")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = try write(".codex/sessions/directory.jsonl/sentinel", "不可递归删除")
        let fixture = try codexFixture(childPath: directory.path)
        do {
            _ = try await CodexSessionProvider(homeDir: home.path).deleteSession(session(path: fixture.paths[0]))
            XCTFail("rollout_path 不允许目录")
        } catch { }
        XCTAssertTrue(files.fileExists(atPath: sentinel))
        XCTAssertTrue(files.fileExists(atPath: fixture.paths[0]))
        XCTAssertEqual(try count(fixture.database), 3)
    }

    func testDirectProviderRejectsRootPrefixImpostorAndConfigurationFile() async throws {
        let impostor = try write(".codex-backup/sentinel.jsonl")
        let config = try write(".claude/settings.json", "必须保留配置")
        do {
            _ = try await CodexSessionProvider(homeDir: home.path).deleteSession(session(path: impostor))
            XCTFail("同名前缀不构成合法根目录")
        } catch { }
        do {
            _ = try await ClaudeSessionProvider(homeDir: home.path).deleteSession(session(agent: .claude, path: config))
            XCTFail("Provider 的公开入口也必须保护配置文件")
        } catch { }
        XCTAssertTrue(files.fileExists(atPath: impostor))
        XCTAssertTrue(files.fileExists(atPath: config))
        XCTAssertThrowsError(try WorkspaceSessionPathPolicy(homeDirectory: home.path, agent: .codex).validate(home.appendingPathComponent(".codex/sessions").path, allowDirectory: true))
    }

    func testSQLiteLocatorCannotBypassFixedDatabaseBoundary() async throws {
        let database = home.appendingPathComponent("unrelated.db").path
        try execute(database, "CREATE TABLE session(id TEXT); INSERT INTO session VALUES ('p');")
        do {
            _ = try await OpenCodeSessionProvider(homeDir: home.path).deleteSession(session(agent: .opencode, path: "sqlite:\(database):p"))
            XCTFail("sqlite 定位符不允许操作其它数据库")
        } catch { }
        XCTAssertEqual(try count(database, table: "session"), 1)
    }

    func testSymlinkedSessionRootAndDatabaseParentAreRejected() async throws {
        let outside = home.appendingPathComponent("outside-client-root")
        try files.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("p.jsonl")
        try "保留".write(to: sentinel, atomically: true, encoding: .utf8)
        try files.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try files.createSymbolicLink(at: home.appendingPathComponent(".claude/projects"), withDestinationURL: outside)
        do {
            _ = try await ClaudeSessionProvider(homeDir: home.path).deleteSession(session(agent: .claude, path: home.appendingPathComponent(".claude/projects/p.jsonl").path))
            XCTFail("会话根目录的符号链接不能把外部目录变成合法删除范围")
        } catch { }
        XCTAssertTrue(files.fileExists(atPath: sentinel.path))
        try files.createSymbolicLink(at: home.appendingPathComponent(".codex"), withDestinationURL: outside)
        XCTAssertThrowsError(try WorkspaceSessionDatabase(path: home.appendingPathComponent(".codex/state_5.sqlite").path, homeDirectory: home.path))
    }

    func testMissingSessionDoesNotReportSuccess() async throws {
        let path = home.appendingPathComponent(".codex/sessions/missing.jsonl").path
        let success = try await CodexSessionProvider(homeDir: home.path).deleteSession(session(path: path))
        XCTAssertFalse(success)
    }

    func testChineseLargeJSONLPreservesMetadataAtByteBoundaries() async throws {
        let identifier = "11111111-1111-4111-8111-111111111111"
        let head = "{\"sessionId\":\"\(identifier)\",\"cwd\":\"/tmp/project\",\"timestamp\":\"2026-09-11T10:00:00.123Z\",\"message\":{\"role\":\"user\",\"content\":\"中文首条消息\"}}"
        let large = "{\"type\":\"progress\",\"content\":\"" + String(repeating: "中", count: 150_000) + "\"}"
        _ = try write(".claude/projects/project/different-filename.jsonl", head + "\n" + large + "\n")
        let records = await ClaudeSessionProvider(homeDir: home.path).scanSessions()
        XCTAssertEqual(records.first?.id, identifier)
        XCTAssertEqual(records.first?.title, "中文首条消息")
        XCTAssertNotNil(records.first?.createdAt)
        XCTAssertEqual(records.first?.messageCount, 0, "扫描采样不得虚构真实消息总数")
    }

    func testOpenCodeThreeLevelCascade() async throws {
        let directory = home.appendingPathComponent(".local/share/opencode")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("opencode.db").path
        try execute(database, """
        CREATE TABLE session(id TEXT PRIMARY KEY, parent_id TEXT);
        INSERT INTO session VALUES ('p', NULL), ('c', 'p'), ('g', 'c');
        """)
        let success = try await OpenCodeSessionProvider(homeDir: home.path).deleteSession(session(agent: .opencode, path: "sqlite:\(database):p"))
        XCTAssertTrue(success)
        XCTAssertEqual(try count(database, table: "session"), 0)
    }

    func testAGYThreeLevelCascadeCleansAllBrainDirectories() async throws {
        let database = home.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db").path
        let paths = try ["p", "c", "g"].map { try write(".gemini/antigravity-cli/brain/\($0)/.system_generated/logs/transcript.jsonl", "fixture") }
        try execute(database, """
        CREATE TABLE conversation_summaries(conversation_id TEXT PRIMARY KEY, parent_conversation_id TEXT);
        INSERT INTO conversation_summaries VALUES ('p', NULL), ('c', 'p'), ('g', 'c');
        """)
        let success = try await AGYSessionProvider(homeDir: home.path).deleteSession(session(agent: .agy, path: paths[0]))
        XCTAssertTrue(success)
        XCTAssertEqual(try count(database, table: "conversation_summaries"), 0)
        for path in paths { XCTAssertFalse(files.fileExists(atPath: path)) }
    }
}
