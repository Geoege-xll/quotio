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

    func testCodexFiltersImportedExternalSessionsHeadlessProbesArchivedAndEmptyShellsFromMainList() async throws {
        let userRollout = try write(".codex/sessions/user-main.jsonl", """
        {"type":"session_meta","payload":{"id":"user-main","source":"vscode","originator":"Codex Desktop","cwd":"/projects/quotio"}}
        """)
        let archivedRollout = try write(".codex/archived_sessions/archived-file.jsonl", """
        {"type":"session_meta","payload":{"id":"archived-file","source":"cli","originator":"codex-tui","cwd":"/projects/quotio"}}
        """)
        try write(".codex/session_index.jsonl", """
        {"id":"indexed-main","thread_name":"索引优先标题"}
        """)
        try write(".codex/external_agent_session_imports.json", """
        {"version":1,"records":[{"source_agent":"claude","imported_thread_id":"imported-from-json"}]}
        """)
        try database(".codex/state_5.sqlite", """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT,
            title TEXT,
            first_user_message TEXT,
            cwd TEXT,
            created_at INTEGER,
            updated_at INTEGER,
            source TEXT,
            agent_nickname TEXT,
            agent_role TEXT,
            name TEXT,
            preview TEXT,
            thread_source TEXT,
            originator TEXT,
            archived INTEGER
        );
        CREATE TABLE external_agent_config_imports (
            agent_name TEXT,
            successes TEXT
        );
        INSERT INTO external_agent_config_imports VALUES (
            'Claude Code',
            '[{"item_type":"SESSIONS","target":"imported-from-db"}]'
        );
        INSERT INTO threads VALUES (
            'user-main', '\(userRollout)',
            '# Files mentioned by the user:\n\n## File: A.swift\n\n## My request for Codex:\n修复会话列表过滤',
            '# Files mentioned by the user:\n\n## File: A.swift\n\n## My request for Codex:\n修复会话列表过滤',
            '/projects/quotio', 100, 200, 'vscode', NULL, NULL, NULL, '修复会话列表过滤', 'user', 'Codex Desktop', 0
        );
        INSERT INTO threads VALUES (
            'indexed-main', '', '原始标题', '原始提问',
            '/projects/quotio', 100, 190, 'cli', NULL, NULL, NULL, '原始提问', 'user', 'codex-tui', 0
        );
        INSERT INTO threads VALUES (
            'named-main', '', '原始标题', '原始提问',
            '/projects/quotio', 100, 180, 'cli', NULL, NULL, '数据库自定义名称', '原始提问', 'user', 'codex-tui', 0
        );
        INSERT INTO threads VALUES (
            'imported-from-db', '', 'Claude 导入会话 1', '导入内容',
            '/private/tmp/awf-native-acceptance/claude/project', 100, 170, 'vscode', NULL, NULL, NULL, '导入内容', NULL, 'Codex Desktop', 0
        );
        INSERT INTO threads VALUES (
            'imported-from-json', '', 'Claude 导入会话 2', '导入内容',
            '/Users/test/O2O-iOS', 100, 160, 'vscode', NULL, NULL, NULL, '导入内容', NULL, NULL, 0
        );
        INSERT INTO threads VALUES (
            'headless-probe', '', '仅回复一句中文：原生模型连接成功', '仅回复一句中文：原生模型连接成功',
            '/private/tmp/awf-native-acceptance/codex/project', 100, 150, 'vscode', NULL, NULL, NULL, '仅回复一句中文', NULL, 'agent_workflow_acceptance', 0
        );
        INSERT INTO threads VALUES (
            'voice-helper', '', '语音会话', '语音会话',
            '/projects/quotio', 100, 140, 'vscode', NULL, NULL, NULL, '语音会话', 'voice_chat', 'Codex Desktop', 0
        );
        INSERT INTO threads VALUES (
            'archived-db', '', '归档会话', '归档会话',
            '/projects/quotio', 100, 130, 'cli', NULL, NULL, NULL, '归档会话', 'user', 'codex-tui', 1
        );
        INSERT INTO threads VALUES (
            'empty-tui-shell', '', '', '',
            '/Users/test/server-frp-gost', 100, 120, 'cli', NULL, NULL, NULL, '', 'user', 'codex-tui', 0
        );
        INSERT INTO threads VALUES (
            'guardian-sub', '', '守护审查', '守护审查',
            '/projects/quotio', 100, 110, 'cli', NULL, NULL, NULL, '守护审查', 'guardian_review', 'codex-tui', 0
        );
        """)

        let provider = CodexSessionProvider(homeDir: home.path)
        let records = await provider.scanSessions()
        XCTAssertEqual(records.count, 11, "所有底层记录仍需保留在扫描集合中供存储与删除管理")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archivedRollout) == false)
        XCTAssertEqual(records.first { $0.id == "user-main" }?.title, "修复会话列表过滤")
        XCTAssertEqual(records.first { $0.id == "indexed-main" }?.title, "索引优先标题")
        XCTAssertEqual(records.first { $0.id == "named-main" }?.title, "数据库自定义名称")
        XCTAssertEqual(records.first { $0.id == "guardian-sub" }?.relationship.kind, .subagent)
        await assertMainList(records, agent: .codex, expected: ["user-main", "indexed-main", "named-main"])
    }

    func testClaudeFiltersSDKCLIProbesCommandOnlyShellsAndCleansSystemRemindersAndTitles() async throws {
        let project = ".claude/projects/project-main"
        try write("\(project)/interactive-main.jsonl", """
        {"type":"permission-mode","permissionMode":"default","sessionId":"interactive-main"}
        {"type":"api-request-blob","sessionId":"interactive-main","cwd":"/projects/quotio","entrypoint":"cli","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>不应作为标题或正文的内部提醒</system-reminder>"}]}}
        {"type":"user","isMeta":true,"sessionId":"interactive-main","cwd":"/projects/quotio","entrypoint":"cli","message":{"role":"user","content":"<local-command-caveat>Caveat: local commands</local-command-caveat>"}}
        {"type":"user","sessionId":"interactive-main","cwd":"/projects/quotio","entrypoint":"cli","timestamp":"2026-11-12T10:00:00Z","message":{"role":"user","content":"<command-name>/model</command-name>\\n<command-message>model</command-message>"}}
        {"type":"user","sessionId":"interactive-main","cwd":"/projects/quotio","entrypoint":"cli","timestamp":"2026-11-12T10:01:00Z","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>系统提示</system-reminder>\\n审计并修复智能体会话列表"}]}}
        {"type":"assistant","sessionId":"interactive-main","cwd":"/projects/quotio","entrypoint":"cli","timestamp":"2026-11-12T10:02:00Z","message":{"role":"assistant","content":[{"type":"text","text":"已完成审计与修复。"}]}}
        {"type":"ai-title","sessionId":"interactive-main","aiTitle":"会话列表审计与修复"}
        {"type":"file-history-snapshot","timestamp":"2026-11-12T10:03:00Z"}
        """)

        try write("\(project)/sdk-probe.jsonl", """
        {"type":"user","sessionId":"sdk-probe","cwd":"/private/tmp/awf-native-acceptance/claude/project","entrypoint":"sdk-cli","timestamp":"2026-11-12T10:00:00Z","message":{"role":"user","content":"这是当前临时项目的单次模型路由连通测试"}}
        {"type":"assistant","sessionId":"sdk-probe","cwd":"/private/tmp/awf-native-acceptance/claude/project","entrypoint":"sdk-cli","timestamp":"2026-11-12T10:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"ROUTE_OK"}]}}
        """)

        try write("\(project)/command-only.jsonl", """
        {"type":"user","isMeta":true,"sessionId":"command-only","cwd":"/projects/quotio","entrypoint":"cli","message":{"role":"user","content":"<local-command-caveat>Caveat</local-command-caveat>"}}
        {"type":"user","sessionId":"command-only","cwd":"/projects/quotio","entrypoint":"cli","timestamp":"2026-11-12T09:00:00Z","message":{"role":"user","content":"<command-name>/clear</command-name>\\n<command-message>clear</command-message>"}}
        """)

        try write("\(project)/empty-lifecycle.jsonl", """
        {"type":"last-prompt","sessionId":"empty-lifecycle"}
        {"type":"permission-mode","permissionMode":"default","sessionId":"empty-lifecycle","cwd":"/projects/quotio","entrypoint":"cli"}
        {"type":"cost-state","sessionId":"empty-lifecycle"}
        """)

        try write("\(project)/slash-skill.jsonl", """
        {"type":"permission-mode","permissionMode":"default","sessionId":"slash-skill"}
        {"type":"user","sessionId":"slash-skill","cwd":"/projects/quotio","entrypoint":"cli","timestamp":"2026-11-12T11:00:00Z","message":{"role":"user","content":"<command-message>rex</command-message>\\n<command-name>/rex</command-name>"}}
        {"type":"user","isMeta":true,"sessionId":"slash-skill","cwd":"/projects/quotio","entrypoint":"cli","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /Users/test/.claude/skills/rex"}]}}
        {"type":"assistant","sessionId":"slash-skill","cwd":"/projects/quotio","entrypoint":"cli","timestamp":"2026-11-12T11:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"Rex skill 已加载。"}]}}
        """)

        let provider = ClaudeSessionProvider(homeDir: home.path)
        let records = await provider.scanSessions()
        XCTAssertEqual(records.count, 5)

        let main = try XCTUnwrap(records.first { $0.id == "interactive-main" })
        XCTAssertEqual(main.title, "会话列表审计与修复", "尾部带 timestamp 的快照行不能截断前方的 ai-title / custom-title")
        XCTAssertEqual(main.summary, "审计并修复智能体会话列表")

        let slashSkill = try XCTUnwrap(records.first { $0.id == "slash-skill" })
        XCTAssertEqual(slashSkill.title, "/rex")

        let messages = try await provider.loadMessages(for: main)
        XCTAssertEqual(messages.map(\.content), ["审计并修复智能体会话列表", "已完成审计与修复。"])

        await assertMainList(records, agent: .claude, expected: ["interactive-main", "slash-skill"])
    }
}
