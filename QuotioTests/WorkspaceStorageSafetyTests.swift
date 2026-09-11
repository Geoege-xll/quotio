import XCTest
import SQLite3
@testable import Quotio

/// 所有夹具都位于独立临时 home，禁止用 shared 服务触碰本机正在运行的客户端目录。
final class WorkspaceStorageSafetyTests: XCTestCase {
    private let fm = FileManager.default

    func testConstructionDoesNotCreateHomeOrClientDirectories() throws {
        let home = fm.temporaryDirectory.appendingPathComponent("WorkspaceStorageNoIO_\(UUID().uuidString)")
        _ = WorkspaceStorageService(homeDir: home.path)
        XCTAssertFalse(fm.fileExists(atPath: home.path))
    }

    func testAGYPreviewAndCleanupUseSameLogicalSessionAndDeleteDatabaseAndBody() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let base = home.appendingPathComponent(".gemini/antigravity-cli")
        let brainFile = try write(home, ".gemini/antigravity-cli/brain/old-agy/.system_generated/logs/transcript.jsonl", text: "{\"content\":\"old body\"}\n")
        let conversation = try write(home, ".gemini/antigravity-cli/conversations/old-agy.json", text: "{\"title\":\"Old AGY\"}")
        let database = base.appendingPathComponent("conversation_summaries.db")
        try executeSQL(database, """
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY, title TEXT, preview TEXT,
            step_count INTEGER, last_modified_time TEXT, workspace_uris TEXT
        );
        INSERT INTO conversation_summaries VALUES ('old-agy', 'Old AGY', 'Preview', 2, '2020-01-01T00:00:00Z', '[]');
        """)
        let storage = WorkspaceStorageService(homeDir: home.path)
        let report = await storage.analyzeStorage()
        let expectedBytes = Int64(try Data(contentsOf: brainFile).count + Data(contentsOf: conversation).count)
        XCTAssertEqual(report.items.first { $0.agent == .agy }?.sessionCount, 1)
        XCTAssertEqual(report.oldSessionsCount, 1)
        XCTAssertEqual(report.oldSessionsBytes, expectedBytes)

        // 使用 analyzeStorage 保存的原始候选，不另起一套以文件时间为准的枚举规则。
        let result = await storage.cleanOldSessionsReport(olderThanDays: 30)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.freedBytes, expectedBytes)
        XCTAssertFalse(fm.fileExists(atPath: brainFile.path))
        XCTAssertFalse(fm.fileExists(atPath: conversation.path))
        XCTAssertEqual(try scalar(database, "SELECT count(*) FROM conversation_summaries"), 0)
    }

    func testRecentGrandchildProtectsWholeTreeWithoutCollidingAcrossAgents() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let root = try session(home, id: "shared-id", agent: .claude)
        let child = try session(home, id: "old-child", agent: .claude, parent: root.id)
        let grandchild = try session(home, id: "active-grandchild", agent: .claude, parent: child.id, date: Date())
        let otherAgent = try session(home, id: "shared-id", agent: .codex)
        let fake = StorageSessionFixture(sessions: [root, child, grandchild, otherAgent])
        let storage = WorkspaceStorageService(homeDir: home.path, sessionService: fake)
        let plan = await storage.makeCleanupPlan()
        XCTAssertEqual(plan.sessionCount, 1)
        XCTAssertEqual(plan.candidates.first?.agent, .codex)
        let result = await storage.executeCleanupPlan(plan)
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.failures, [])
        XCTAssertTrue(fm.fileExists(atPath: root.filePath))
        XCTAssertTrue(fm.fileExists(atPath: grandchild.filePath))
        XCTAssertFalse(fm.fileExists(atPath: otherAgent.filePath))
    }

    func testActivityAfterPreviewProtectsPreviouslyOldSession() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let old = try session(home, id: "reactivated", agent: .codex)
        let fake = StorageSessionFixture(sessions: [old])
        let storage = WorkspaceStorageService(homeDir: home.path, sessionService: fake)
        let plan = await storage.makeCleanupPlan()
        let updated = try session(home, id: old.id, agent: .codex, date: Date())
        await fake.replaceSessions([updated])
        let result = await storage.executeCleanupPlan(plan)
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: old.filePath))
    }

    func testNewDescendantAfterPreviewIsNotIncludedInCascade() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let parent = try session(home, id: "parent", agent: .codex)
        let fake = StorageSessionFixture(sessions: [parent])
        let storage = WorkspaceStorageService(homeDir: home.path, sessionService: fake)
        let plan = await storage.makeCleanupPlan()
        // 即使新发现的后代也已过期，仍不能扩大已展示给用户的删除范围。
        let child = try session(home, id: "newly-discovered-child", agent: .codex, parent: parent.id)
        await fake.replaceSessions([parent, child])
        let result = await storage.executeCleanupPlan(plan)
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: parent.filePath))
        XCTAssertTrue(fm.fileExists(atPath: child.filePath))
    }

    func testNewUnrelatedOldSessionDoesNotExpandCachedPreview() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let first = try session(home, id: "shown-in-preview", agent: .codex)
        let fake = StorageSessionFixture(sessions: [first])
        let storage = WorkspaceStorageService(homeDir: home.path, sessionService: fake)
        _ = await storage.analyzeStorage()
        let later = try session(home, id: "arrived-after-preview", agent: .codex)
        await fake.replaceSessions([first, later])
        let result = await storage.cleanOldSessionsReport(olderThanDays: 30)
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.failures, [])
        XCTAssertFalse(fm.fileExists(atPath: first.filePath))
        XCTAssertTrue(fm.fileExists(atPath: later.filePath))
    }

    func testDeleteFailureDoesNotCountEstimatedBytesAsFreed() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let old = try session(home, id: "failed-delete", agent: .codex)
        let fake = StorageSessionFixture(sessions: [old], failDeletion: true)
        let storage = WorkspaceStorageService(homeDir: home.path, sessionService: fake)
        let plan = await storage.makeCleanupPlan()
        XCTAssertGreaterThan(plan.estimatedBytes, 0)
        let result = await storage.executeCleanupPlan(plan)
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: old.filePath))
    }

    func testOrphanSiblingPartialFailureCountsOnlyConfirmedDirectedSubtree() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let first = try session(home, id: "a-success", agent: .codex, parent: "missing-parent")
        let second = try session(home, id: "b-failure", agent: .codex, parent: "missing-parent")
        let fake = StorageSessionFixture(sessions: [first, second], failingIDs: [second.id])
        let storage = WorkspaceStorageService(homeDir: home.path, sessionService: fake)
        let expectedBytes = Int64(try Data(contentsOf: URL(fileURLWithPath: first.filePath)).count)
        let result = await storage.cleanOldSessionsReport()
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.freedBytes, expectedBytes)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: first.filePath))
        XCTAssertTrue(fm.fileExists(atPath: second.filePath))
    }

    func testFailedDeleteFollowedByUnavailableScanCannotReportSuccess() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let old = try session(home, id: "unreadable-after-failure", agent: .codex)
        let fake = StorageSessionFixture(sessions: [old], failDeletion: true, emptyAfterFailure: true)
        let storage = WorkspaceStorageService(homeDir: home.path, sessionService: fake)
        let result = await storage.cleanOldSessionsReport()
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: old.filePath))
    }

    func testChildInsertedAfterFinalStorageScanPreservesRealDatabaseTree() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let parent = try write(home, ".gemini/antigravity-cli/conversations/parent.json", text: "{}")
        let database = home.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db")
        try executeSQL(database, """
        CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, preview TEXT,
          step_count INTEGER, last_modified_time TEXT, workspace_uris TEXT, parent_conversation_id TEXT);
        INSERT INTO conversation_summaries VALUES ('parent', 'Parent', '', 1, '2020-01-01T00:00:00Z', '[]', NULL);
        """)
        let injected = StorageDatabaseRaceFixture(home: home.path)
        let storage = WorkspaceStorageService(homeDir: home.path, sessionService: injected)
        let plan = await storage.makeCleanupPlan()
        XCTAssertEqual(plan.sessionCount, 1)
        // 替身仅在受约束删除入口才写入真实 SQLite，精确覆盖最后扫描与 delete actor 调用之间的窗口。
        let result = await storage.executeCleanupPlan(plan)
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertEqual(try scalar(database, "SELECT count(*) FROM conversation_summaries"), 2)
        XCTAssertTrue(fm.fileExists(atPath: parent.path))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".gemini/antigravity-cli/conversations/new-child.json").path))
    }

    func testCacheRootAndAncestorSymlinksNeverDeleteExternalFiles() async throws {
        let home = try makeHome()
        let outside = try makeHome()
        defer { try? fm.removeItem(at: home); try? fm.removeItem(at: outside) }
        let externalFile = try write(outside, "cache/keep.txt", text: "外部文件必须保留")
        try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent(".claude/cache"), withDestinationURL: outside.appendingPathComponent("cache"))
        try fm.createSymbolicLink(at: home.appendingPathComponent(".codex"), withDestinationURL: outside)
        let storage = WorkspaceStorageService(homeDir: home.path, sessionService: StorageSessionFixture(sessions: []))
        let claude = await storage.clearCachesReport(for: .claude)
        let codex = await storage.clearCachesReport(for: .codex)
        XCTAssertEqual(claude.freedBytes, 0)
        XCTAssertEqual(codex.freedBytes, 0)
        XCTAssertFalse(claude.failures.isEmpty)
        XCTAssertFalse(codex.failures.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: externalFile.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".claude/cache").path), outside.appendingPathComponent("cache").path)
    }

    func testCacheCleanupPreservesLocksTmpAndPresence() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let lockedCache = try write(home, ".claude/cache/model.bin", text: "cached data")
        let lock = try write(home, ".claude/cache/worker.lock", text: "12345")
        let tmp = try write(home, ".codex/tmp/active-executable", text: "in use")
        let presence = try write(home, ".gemini/antigravity-cli/presence/active.json", text: "{}")
        let storage = WorkspaceStorageService(homeDir: home.path, sessionService: StorageSessionFixture(sessions: []))
        let result = await storage.clearCachesReport()
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertFalse(result.failures.isEmpty)
        for file in [lockedCache, lock, tmp, presence] { XCTAssertTrue(fm.fileExists(atPath: file.path)) }
    }

    func testCachePartialFailureOnlyReportsSuccessfulFiles() async throws {
        let home = try makeHome()
        let outside = try makeHome()
        defer { try? fm.removeItem(at: home); try? fm.removeItem(at: outside) }
        let cache = try write(home, ".claude/cache/model.bin", text: "abc123")
        try fm.createSymbolicLink(at: home.appendingPathComponent(".claude/debug"), withDestinationURL: outside)
        let storage = WorkspaceStorageService(homeDir: home.path, sessionService: StorageSessionFixture(sessions: []))
        let result = await storage.clearCachesReport(for: .claude)
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.freedBytes, 6)
        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: cache.path))
        XCTAssertTrue(fm.fileExists(atPath: cache.deletingLastPathComponent().path))
    }

    private func makeHome() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("WorkspaceStorageSafety_\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ home: URL, _ relative: String, text: String) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func session(_ home: URL, id: String, agent: WorkspaceAgent, parent: String? = nil,
                         date: Date = Date(timeIntervalSince1970: 1_600_000_000)) throws -> WorkspaceSession {
        let relative = agent == .claude ? ".claude/projects/test/\(id).jsonl" : ".codex/sessions/\(id).jsonl"
        let url = try write(home, relative, text: "{\"id\":\"\(id)\"}\n")
        return WorkspaceSession(id: id, agent: agent, title: id, projectName: "Fixture",
                                lastActiveAt: date, filePath: url.path, fileSizeBytes: 0,
                                messageCount: 1, resumeCommand: "", parentSessionID: parent)
    }

    private func executeSQL(_ url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw fixtureError("创建测试数据库失败") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw fixtureError("写入测试数据库失败") }
    }

    private func scalar(_ url: URL, _ sql: String) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw fixtureError("读取测试数据库失败") }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw fixtureError("准备测试查询失败") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw fixtureError("测试查询没有返回数据") }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "WorkspaceStorageSafetyFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private actor StorageSessionFixture: WorkspaceSessionServicing {
    private var sessions: [WorkspaceSession]
    private let failDeletion: Bool
    private let failingIDs: Set<String>
    private let emptyAfterFailure: Bool
    private var failed = false

    init(sessions: [WorkspaceSession], failDeletion: Bool = false, failingIDs: Set<String> = [], emptyAfterFailure: Bool = false) {
        self.sessions = sessions
        self.failDeletion = failDeletion
        self.failingIDs = failingIDs
        self.emptyAfterFailure = emptyAfterFailure
    }

    func replaceSessions(_ sessions: [WorkspaceSession]) { self.sessions = sessions }
    func scanAllSessions(agentFilter: WorkspaceAgent?) async -> [WorkspaceSession] {
        if failed && emptyAfterFailure { return [] }
        return sessions.filter { agentFilter == nil || $0.agent == agentFilter }
    }
    func loadSessionMessages(session: WorkspaceSession) async throws -> [WorkspaceSessionMessage] { [] }
    func resumeInTerminal(session: WorkspaceSession) async throws {}

    func deleteSession(_ session: WorkspaceSession, constrainedBy constraint: WorkspaceSessionCleanupConstraint) async throws -> Bool {
        try constraint.validateObserved(sessions, root: session)
        try constraint.validateFiles()
        return try await deleteSession(session)
    }

    func deleteSession(_ session: WorkspaceSession) async throws -> Bool {
        if failDeletion || failingIDs.contains(session.id) {
            failed = true
            throw NSError(domain: "StorageSessionFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟删除失败"])
        }
        // 删除替身也必须使用有向后代；共用缺失父节点的兄弟不属于本次根的级联范围。
        let tree = WorkspaceSessionTree(sessions: sessions)
        let group = [session] + tree.descendants(of: session).map(\.session)
        let keys = Set(group.map(WorkspaceCleanupSessionKey.init))
        for record in group where FileManager.default.fileExists(atPath: record.filePath) {
            try FileManager.default.removeItem(atPath: record.filePath)
        }
        sessions.removeAll { keys.contains(WorkspaceCleanupSessionKey($0)) }
        return !group.isEmpty
    }
}

private actor StorageDatabaseRaceFixture: WorkspaceSessionServicing {
    private let home: String
    private let service: WorkspaceSessionService
    init(home: String) { self.home = home; service = WorkspaceSessionService(homeDir: home) }
    func scanAllSessions(agentFilter: WorkspaceAgent?) async -> [WorkspaceSession] { await service.scanAllSessions(agentFilter: agentFilter) }
    func loadSessionMessages(session: WorkspaceSession) async throws -> [WorkspaceSessionMessage] { try await service.loadSessionMessages(session: session) }
    func resumeInTerminal(session: WorkspaceSession) async throws {}
    func deleteSession(_ session: WorkspaceSession) async throws -> Bool { try await service.deleteSession(session) }
    func deleteSession(_ session: WorkspaceSession, constrainedBy constraint: WorkspaceSessionCleanupConstraint) async throws -> Bool {
        let base = URL(fileURLWithPath: home).appendingPathComponent(".gemini/antigravity-cli")
        try Data("{}".utf8).write(to: base.appendingPathComponent("conversations/new-child.json"))
        var database: OpaquePointer?
        guard sqlite3_open_v2(base.appendingPathComponent("conversation_summaries.db").path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "StorageDatabaseRaceFixture", code: 1)
        }
        defer { sqlite3_close(database) }
        let sql = "INSERT INTO conversation_summaries VALUES ('new-child', 'New child', '', 1, '2035-01-01T00:00:00Z', '[]', 'parent');"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "StorageDatabaseRaceFixture", code: 2) }
        return try await service.deleteSession(session, constrainedBy: constraint)
    }
}
