import XCTest
import SQLite3
@testable import QuotioPlus

/// 按官方来源构造三端存储样本，从扫描结果验证主列表和删除行为；所有文件都位于隔离 home。
final class WorkspaceSessionRelationshipTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("SessionContract-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    @discardableResult
    private func write(_ path: String, _ text: String) throws -> String {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func database(_ path: String, _ sql: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func assertMainList(_ records: [WorkspaceSession], agent: WorkspaceAgent, expected: Set<String>) async {
        let service = WorkspaceSessionService(homeDir: home.path)
        let skills = WorkspaceSkillService(homeDir: home.path)
        let storage = WorkspaceStorageService(homeDir: home.path)
        await MainActor.run {
            let vm = WorkspaceViewModel(sessionService: service, skillService: skills, storageService: storage)
            vm.sessions = records
            vm.selectedAgentFilter = agent
            XCTAssertEqual(Set(vm.rootFilteredSessions.map(\.id)), expected)
            XCTAssertEqual(Set(vm.projectGroups.flatMap(\.sessions).map(\.id)), expected)
            XCTAssertEqual(vm.sessions.count, records.count, "浏览过滤不能删除原始索引数据")
        }
    }

    func testOfficialCodexSourcesDoNotInferIdentityFromNamesOrForks() {
        // CLI 0.153.4 导出的 SessionSource/SubAgentSource 包含这两种存储/API 拼写。
        for key in ["subagent", "subAgent"] {
            for value: Any in ["review", "compact", "memory_consolidation", ["other": "guardian"], ["thread_spawn": ["parent_thread_id": "root", "depth": 1]]] {
                XCTAssertTrue(WorkspaceSessionRelationshipAdapter.codex(source: [key: value]).isSubagent)
            }
        }
        for source in ["cli", "vscode", "exec", "appServer"] {
            XCTAssertTrue(WorkspaceSessionRelationshipAdapter.codex(source: source).isMainSession)
        }
        XCTAssertTrue(WorkspaceSessionRelationshipAdapter.codex(source: ["custom": "guardian"]).isMainSession)
        XCTAssertEqual(WorkspaceSessionRelationshipAdapter.codex(source: "futureSource").kind, .unknown)
        XCTAssertNil(WorkspaceSessionRelationshipAdapter.codexParent(in: ["forkedFromId": "root", "note": ["parent_thread_id": "root"]]))
        XCTAssertFalse(WorkspaceSessionRelationshipAdapter.codex(source: ["description": "subagent"]).isMainSession)
        XCTAssertEqual(WorkspaceSessionRelationshipAdapter.claude(metadata: [:]).kind, .unknown)
        XCTAssertEqual(WorkspaceSessionRelationshipAdapter.agy(metadata: [:], hasSummary: false).kind, .unknown)
    }

    func testCodexPartialDatabaseMergesRolloutAndDeletesFileOnlyDescendants() async throws {
        let root = try write(".codex/sessions/root.jsonl", """
        {"type":"session_meta","payload":{"id":"root","source":"cli","cwd":"/projects/agent_workflow"}}
        """)
        let helper = try write(".codex/sessions/helper.jsonl", """
        {"type":"session_meta","payload":{"id":"helper","source":{"subagent":{"other":"guardian"}}}}
        """)
        let child = try write(".codex/sessions/child.jsonl", """
        {"type":"session_meta","payload":{"id":"child","source":{"subagent":{"thread_spawn":{"parent_thread_id":"root","depth":1}}}}}
        """)
        // 不存在边表、nickname 和 role 列；不能让整库扫描失败，也不能让 DB 的空 source 覆盖文件证据。
        try database(".codex/state_5.sqlite", """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT, source TEXT, cwd TEXT);
        INSERT INTO threads VALUES ('root', '\(root)', '自定义工作流主会话', 'cli', '/projects/agent_workflow');
        INSERT INTO threads VALUES ('helper', '\(helper)', '保留数据库标题', NULL, '/projects/agent_workflow');
        """)
        let provider = CodexSessionProvider(homeDir: home.path)
        let records = await provider.scanSessions()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.first { $0.id == "helper" }?.title, "保留数据库标题")
        XCTAssertEqual(records.first { $0.id == "helper" }?.relationship.kind, .subagent)
        await assertMainList(records, agent: .codex, expected: ["root"])
        let success = try await provider.deleteSession(XCTUnwrap(records.first { $0.id == "root" }))
        XCTAssertTrue(success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: child), "DB 主记录的文件子任务也必须实际清理")
        XCTAssertTrue(FileManager.default.fileExists(atPath: helper), "无父辅助任务不应被猜测性级联删除")
        let remaining = await provider.scanSessions()
        XCTAssertEqual(remaining.map(\.id), ["helper"])
    }

    func testCodexTwoUUIDFilenameDoesNotTurnOrdinaryForkIntoSubagent() async throws {
        let first = "11111111-1111-4111-8111-111111111111"
        let second = "22222222-2222-4222-8222-222222222222"
        try write(".codex/sessions/rollout-\(first)_\(second).jsonl", """
        {"type":"session_meta","payload":{"id":"\(second)","source":"cli","forked_from_id":"\(first)"}}
        """)
        let records = await CodexSessionProvider(homeDir: home.path).scanSessions()
        XCTAssertEqual(records.first?.id, second)
        XCTAssertTrue(records.first?.isMainSession == true)
        XCTAssertNil(records.first?.parentSessionID)
    }

    func testCodexOldDatabaseWithoutRolloutColumnStillLoadsDiscoveredMessages() async throws {
        try database(".codex/state_5.sqlite", "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, source TEXT); INSERT INTO threads VALUES ('main', '数据库标题', 'cli');")
        let file = try write(".codex/sessions/main.jsonl", """
        {"type":"session_meta","payload":{"id":"main","source":"cli"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"实际正文"}]}}
        """)
        let provider = CodexSessionProvider(homeDir: home.path)
        let records = await provider.scanSessions()
        let main = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(main.title, "数据库标题")
        XCTAssertEqual(main.filePath, file)
        let messages = try await provider.loadMessages(for: main)
        XCTAssertEqual(messages.map(\.content), ["实际正文"])
    }

    func testClaudeSidechainAndDocumentedPathDoNotCollideWithMainSession() async throws {
        let project = ".claude/projects/project-11111111-1111-4111-8111-111111111111"
        try write("\(project)/main.jsonl", """
        {"sessionId":"main","agentName":"agent_workflow","agentId":"custom-primary","isSidechain":false,"parentUuid":"message-id","cwd":"/projects/agent_workflow","message":{"role":"user","content":"主会话"}}
        """)
        try write("\(project)/agent-flat.jsonl", """
        {"sessionId":"main","agentId":"flat","isSidechain":true,"message":{"role":"user","content":"共享 sessionId 的旧侧链"}}
        """)
        try write("\(project)/main/subagents/agent-child.jsonl", """
        {"sessionId":"main","agentId":"child","isSidechain":true,"message":{"role":"user","content":"子任务"}}
        """)
        try write("\(project)/agent-child.jsonl", """
        {"sessionId":"main","agentId":"child","isSidechain":true,"message":{"role":"user","content":"旧平铺副本"}}
        """)
        let records = await ClaudeSessionProvider(homeDir: home.path).scanSessions()
        XCTAssertEqual(records.count, 3, "平铺副本与官方目录记录必须合并为唯一子会话")
        XCTAssertEqual(Set(records.map(\.id)), ["main", "agent-flat", "agent-child"])
        XCTAssertEqual(records.first { $0.id == "agent-child" }?.parentSessionID, "main")
        XCTAssertTrue(records.first { $0.id == "agent-child" }?.filePath.contains("/main/subagents/") == true)
        XCTAssertNil(records.first { $0.id == "agent-flat" }?.parentSessionID, "平铺 sidechain 只有身份依据，不能猜父会话")
        XCTAssertTrue(records.first { $0.id == "agent-flat" }?.isSubagent == true)
        await assertMainList(records, agent: .claude, expected: ["main"])
    }

    func testAGYMergesSummaryJSONBrainAndInternalCacheWithoutDuplicateRows() async throws {
        let base = ".gemini/antigravity-cli"
        try database("\(base)/conversation_summaries.db", """
        CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, preview TEXT,
            step_count INTEGER, last_modified_time TEXT, workspace_uris TEXT, parent_conversation_id TEXT);
        INSERT INTO conversation_summaries VALUES ('main', '主会话', '', 1, '2026-09-14T10:00:00Z', '["/projects/agent_workflow"]', NULL);
        INSERT INTO conversation_summaries VALUES ('partial', '旧版本父字段仍有效', '', 1, '2026-09-14T10:00:00Z', '[]', 'main');
        INSERT INTO conversation_summaries VALUES ('child', '优先数据库标题', '', 1, '2026-09-14T10:00:00Z', '[]', NULL);
        """)
        try write("\(base)/conversations/child.json", """
        {"title":"旧 JSON 标题","parent_conversation_id":"main","nesting_depth":1,"cwd":"/projects/agent_workflow"}
        """)
        for id in ["child", "internal", "unknown", "cached-main"] {
            try write("\(base)/conversations/\(id).db", "fixture")
            try write("\(base)/brain/\(id)/.system_generated/logs/transcript_full.jsonl", """
            {"type":"USER_INPUT","content":"不应覆盖摘要的正文","created_at":"2026-09-14T10:00:00Z"}
            """)
        }
        try write("\(base)/cache/conversation_metadata.json", """
        {"conversations":{
          "child":{"is_internal":true},
          "internal":{"is_internal":true},
          "cached-main":{"is_internal":false,"summary":{"Title":"缓存主会话","AgentName":"guardian","WorkspaceURIs":["file:///projects/agent_workflow"],"Internal":false}},
          "already-deleted":{"is_internal":false,"summary":{"Title":"不可复活"}}
        }}
        """)
        try write("\(base)/conversations/empty.json", "{}")
        let records = await AGYSessionProvider(homeDir: home.path).scanSessions()
        XCTAssertEqual(records.count, 7)
        XCTAssertEqual(Set(records.map(\.id)).count, records.count)
        XCTAssertEqual(records.first { $0.id == "child" }?.title, "优先数据库标题")
        XCTAssertEqual(records.first { $0.id == "child" }?.relationship.kind, .subagent)
        XCTAssertEqual(records.first { $0.id == "partial" }?.parentSessionID, "main", "缺少 depth/name 列不能丢 parent 列")
        XCTAssertEqual(records.first { $0.id == "internal" }?.relationship.kind, .internalSession)
        XCTAssertNil(records.first { $0.id == "internal" }?.parentSessionID)
        XCTAssertEqual(records.first { $0.id == "unknown" }?.relationship.kind, .unknown)
        XCTAssertEqual(records.first { $0.id == "empty" }?.relationship.kind, .unknown)
        XCTAssertEqual(records.first { $0.id == "cached-main" }?.projectName, "agent_workflow")
        await assertMainList(records, agent: .agy, expected: ["main", "cached-main"])
    }

    func testAGYDatabaseRootDeletesJSONOnlyChildWithBrainAndDBArtifacts() async throws {
        let base = ".gemini/antigravity-cli"
        try database("\(base)/conversation_summaries.db", """
        CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, preview TEXT,
            step_count INTEGER, last_modified_time TEXT, workspace_uris TEXT);
        INSERT INTO conversation_summaries VALUES ('main', '主会话', '', 1, '2026-09-14T10:00:00Z', '[]');
        """)
        let json = try write("\(base)/conversations/child.json", """
        {"title":"子任务","parent_conversation_id":"main","nesting_depth":1}
        """)
        let childDB = try write("\(base)/conversations/child.db", "fixture")
        let brain = try write("\(base)/brain/child/.system_generated/logs/transcript.jsonl", "{\"type\":\"USER_INPUT\",\"content\":\"子任务\"}")
        let provider = AGYSessionProvider(homeDir: home.path)
        let records = await provider.scanSessions()
        let success = try await provider.deleteSession(XCTUnwrap(records.first { $0.id == "main" }))
        XCTAssertTrue(success)
        for path in [json, childDB, brain] { XCTAssertFalse(FileManager.default.fileExists(atPath: path)) }
        let after = await provider.scanSessions()
        XCTAssertTrue(after.isEmpty)
    }
}
