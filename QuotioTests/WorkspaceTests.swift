//
//  WorkspaceTests.swift
//  QuotioTests - Workspace Sessions, Skills & Storage Test Suite
//

import XCTest
import SQLite3
@testable import Quotio

final class WorkspaceTests: XCTestCase {
    private var tempHomeURL: URL!
    private var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempHomeURL = fileManager.temporaryDirectory.appendingPathComponent("WorkspaceTests_\(UUID().uuidString)")
        try? fileManager.createDirectory(at: tempHomeURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempHomeURL)
        super.tearDown()
    }

    // MARK: - Sessions Discovery Tests

    func testClaudeSessionDiscovery() async throws {
        let claudeProjectsDir = tempHomeURL.appendingPathComponent(".claude/projects/test-project")
        try fileManager.createDirectory(at: claudeProjectsDir, withIntermediateDirectories: true)

        let sessionFile = claudeProjectsDir.appendingPathComponent("test-session.jsonl")
        let lines = [
            """
            {"sessionId": "test-session-123", "cwd": "/Users/test/my-app", "timestamp": "2026-09-08T10:00:00Z", "type": "user", "message": {"role": "user", "content": "How do I optimize SwiftUI views?"}}
            """,
            """
            {"sessionId": "test-session-123", "type": "assistant", "message": {"role": "assistant", "content": "You can use @Observable and small subviews."}}
            """
        ]
        try lines.joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let service = WorkspaceSessionService(homeDir: tempHomeURL.path)
        let sessions = await service.scanAllSessions(agentFilter: .claude)

        XCTAssertEqual(sessions.count, 1)
        let session = sessions[0]
        XCTAssertEqual(session.id, "test-session-123")
        XCTAssertEqual(session.agent, .claude)
        XCTAssertEqual(session.projectName, "my-app")
        XCTAssertEqual(session.title, "How do I optimize SwiftUI views?")
        XCTAssertEqual(session.resumeCommand, "'claude' '--resume' 'test-session-123'")

        let messages = try await service.loadSessionMessages(session: session)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "How do I optimize SwiftUI views?")
        XCTAssertEqual(messages[1].role, .assistant)
    }

    func testCodexSessionDiscovery() async throws {
        let codexSessionsDir = tempHomeURL.appendingPathComponent(".codex/sessions/2026/09/08")
        try fileManager.createDirectory(at: codexSessionsDir, withIntermediateDirectories: true)

        let sessionFile = codexSessionsDir.appendingPathComponent("rollout-456.jsonl")
        let lines = [
            """
            {"session_id": "rollout-456", "cwd": "/Users/test/codex-proj", "timestamp": "2026-09-08T11:00:00Z", "prompt": "Implement QuickSort in Swift"}
            """,
            """
            {"session_id": "rollout-456", "response_item": {"payload": {"type": "message", "text": "Here is QuickSort in Swift..."}}}
            """
        ]
        try lines.joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let service = WorkspaceSessionService(homeDir: tempHomeURL.path)
        let sessions = await service.scanAllSessions(agentFilter: .codex)

        XCTAssertEqual(sessions.count, 1)
        let session = sessions[0]
        XCTAssertEqual(session.id, "rollout-456")
        XCTAssertEqual(session.agent, .codex)
        XCTAssertEqual(session.projectName, "codex-proj")
        let messages = try await service.loadSessionMessages(session: session)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant)
    }

    func testRealWorldCodexRolloutParsing() async throws {
        let codexSessionsDir = tempHomeURL.appendingPathComponent(".codex/sessions/2026/09/10")
        try fileManager.createDirectory(at: codexSessionsDir, withIntermediateDirectories: true)

        let sessionFile = codexSessionsDir.appendingPathComponent("rollout-2026-09-10T15-47-40-01a08a49-6362-7cc1-b12f-577719219eaf.jsonl")
        let lines = [
            """
            {"timestamp":"2026-09-10T07:47:40.000Z","ordinal":0,"type":"session_meta","payload":{"id":"01a08a49-6362-7cc1-b12f-577719219eaf","cwd":"/Users/test/mt-shop","timestamp":"2026-09-10T07:47:40.000Z"}}
            """,
            """
            {"timestamp":"2026-09-10T07:47:45.000Z","ordinal":1,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"请重构 Technician 视图组件"}]}}
            """,
            """
            {"timestamp":"2026-09-10T07:47:50.000Z","ordinal":2,"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Planning code refactor"}]}}
            """,
            """
            {"timestamp":"2026-09-10T07:48:00.000Z","ordinal":3,"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"已按要求完成组件重构。"}]}}
            """,
            """
            {"timestamp":"2026-09-10T07:48:10.000Z","ordinal":4,"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"npm test"}}
            """
        ]
        try lines.joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let service = WorkspaceSessionService(homeDir: tempHomeURL.path)
        let sessions = await service.scanAllSessions(agentFilter: .codex)

        XCTAssertEqual(sessions.count, 1)
        let session = sessions[0]
        XCTAssertEqual(session.id, "01a08a49-6362-7cc1-b12f-577719219eaf")
        XCTAssertEqual(session.agent, .codex)
        XCTAssertEqual(session.projectName, "mt-shop")
        XCTAssertEqual(session.title, "请重构 Technician 视图组件")
        XCTAssertEqual(session.resumeCommand, "'codex' 'resume' '01a08a49-6362-7cc1-b12f-577719219eaf'")

        let messages = try await service.loadSessionMessages(session: session)
        XCTAssertEqual(messages.count, 4) // user, reasoning (assistant), assistant, tool
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "请重构 Technician 视图组件")
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertTrue(messages[1].content.contains("Planning code refactor"))
        XCTAssertEqual(messages[2].role, .assistant)
        XCTAssertEqual(messages[2].content, "已按要求完成组件重构。")
        XCTAssertEqual(messages[3].role, .tool)
    }

    func testCodexSubagentHierarchicalDiscovery() async throws {
        let codexSessionsDir = tempHomeURL.appendingPathComponent(".codex/sessions/2026/09/03")
        try fileManager.createDirectory(at: codexSessionsDir, withIntermediateDirectories: true)

        let parentFile = codexSessionsDir.appendingPathComponent("rollout-2026-09-03T17-26-31-01a06697-602c-7820-bb9c-036f39405abf.jsonl")
        let parentContent = """
        {"timestamp":"2026-09-03T09:26:31.000Z","ordinal":0,"type":"session_meta","payload":{"id":"01a06697-602c-7820-bb9c-036f39405abf","cwd":"/Users/test/ghk","timestamp":"2026-09-03T09:26:31.000Z"}}
        {"timestamp":"2026-09-03T09:26:35.000Z","ordinal":1,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"现在开始c 端微信小程序的开发工作"}]}}
        """
        try parentContent.write(to: parentFile, atomically: true, encoding: .utf8)

        let childFile = codexSessionsDir.appendingPathComponent("rollout-2026-09-03T22-55-31-01a06697-602c-7820-bb9c-036f39405abf_01a067c4-958a-7783-b037-4c4e246e570e.jsonl")
        let childContent = """
        {"timestamp":"2026-09-03T14:55:34.000Z","ordinal":1411,"type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"01a06697-602c-7820-bb9c-036f39405abf"}}
        {"timestamp":"2026-09-03T14:55:40.000Z","ordinal":1412,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"执行子任务：重构小程序导航栏"}]}}
        """
        try childContent.write(to: childFile, atomically: true, encoding: .utf8)

        let service = WorkspaceSessionService(homeDir: tempHomeURL.path)
        let sessions = await service.scanAllSessions(agentFilter: .codex)

        XCTAssertEqual(sessions.count, 2)
        // Ensure no duplicate IDs
        let uniqueIDs = Set(sessions.map(\.id))
        XCTAssertEqual(uniqueIDs.count, 2)

        let parent = sessions.first { $0.id == "01a06697-602c-7820-bb9c-036f39405abf" }
        XCTAssertNotNil(parent)
        XCTAssertNil(parent?.parentSessionID)
        XCTAssertFalse(parent?.isSubagent ?? true)

        let child = sessions.first { $0.id == "01a067c4-958a-7783-b037-4c4e246e570e" }
        XCTAssertNotNil(child)
        XCTAssertEqual(child?.parentSessionID, "01a06697-602c-7820-bb9c-036f39405abf")
        XCTAssertTrue(child?.isSubagent ?? false)
    }

    func testAGYSessionDiscovery() async throws {
        let agyBrainDir = tempHomeURL.appendingPathComponent(".gemini/antigravity-cli/brain/agy-test-789/.system_generated/logs")
        let agyConvsDir = tempHomeURL.appendingPathComponent(".gemini/antigravity-cli/conversations")
        try fileManager.createDirectory(at: agyBrainDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: agyConvsDir, withIntermediateDirectories: true)

        let transcriptFile = agyBrainDir.appendingPathComponent("transcript.jsonl")
        let transcriptLines = [
            """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-09-10T08:00:00Z","content":"<USER_REQUEST>\\nBuild AGY integration for Quotio\\n</USER_REQUEST>"}
            """,
            """
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-09-10T08:00:05Z","content":"AGY integration successfully generated."}
            """
        ]
        try transcriptLines.joined(separator: "\n").write(to: transcriptFile, atomically: true, encoding: .utf8)

        let convFile = agyConvsDir.appendingPathComponent("agy-test-789.json")
        let convJson = """
        {
            "title": "Build AGY integration for Quotio",
            "project_dir": "/Users/test/quotio-app"
        }
        """
        try convJson.write(to: convFile, atomically: true, encoding: .utf8)

        let service = WorkspaceSessionService(homeDir: tempHomeURL.path)
        let sessions = await service.scanAllSessions(agentFilter: .agy)

        XCTAssertEqual(sessions.count, 1)
        let session = sessions[0]
        XCTAssertEqual(session.id, "agy-test-789")
        XCTAssertEqual(session.agent, .agy)
        XCTAssertEqual(session.projectName, "quotio-app")
        XCTAssertEqual(session.title, "Build AGY integration for Quotio")
        XCTAssertEqual(session.resumeCommand, "'agy' '--conversation' 'agy-test-789'")

        let messages = try await service.loadSessionMessages(session: session)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "Build AGY integration for Quotio")
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].content, "AGY integration successfully generated.")
    }

    // MARK: - Skills SSOT and Symlink Tests

    func testSkillSSOTAndSymlinkManagement() async throws {
        let service = WorkspaceSkillService(homeDir: tempHomeURL.path)
        try await service.prepareStorage()

        // 1. Verify SQLite skill_repos persistence
        let initialRepos = try await service.loadRepos()
        XCTAssertFalse(initialRepos.isEmpty)
        let customRepo = SkillRepo(owner: "custom-org", name: "custom-skills", branch: "main", isEnabled: true)
        try await service.addRepo(customRepo)
        let reposAfter = try await service.loadRepos()
        XCTAssertTrue(reposAfter.contains(where: { $0.owner == "custom-org" && $0.name == "custom-skills" }))

        // 统一库必须位于私有目录，未启用时客户端不应自动发现它。
        let ssotSkillDir = tempHomeURL.appendingPathComponent(".quotio/skills/swiftui-glass")
        try fileManager.createDirectory(at: ssotSkillDir, withIntermediateDirectories: true)

        let skillMdContent = """
        ---
        name: Liquid Glass
        description: Implement iOS 26+ Liquid Glass in SwiftUI
        ---
        # Liquid Glass Guide
        Use glassBackgroundEffect().
        """
        try skillMdContent.write(to: ssotSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // 3. Load installed skills
        var skills = try await service.loadInstalledSkills()
        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills[0].name, "Liquid Glass")
        XCTAssertEqual(skills[0].directory, "swiftui-glass")
        XCTAssertTrue(skills[0].enabledAgents.isEmpty)

        // 4. Toggle Claude & Codex ON
        try await service.toggleAgent(skillDirectory: "swiftui-glass", agent: .claude, enable: true)
        try await service.toggleAgent(skillDirectory: "swiftui-glass", agent: .codex, enable: true)

        skills = try await service.loadInstalledSkills()
        XCTAssertEqual(skills[0].enabledAgents, [.claude, .codex])

        // Verify filesystem symlink exists
        let claudeLink = tempHomeURL.appendingPathComponent(".claude/skills/swiftui-glass")
        XCTAssertTrue(fileManager.fileExists(atPath: claudeLink.path))

        // 5. Toggle Claude OFF
        try await service.toggleAgent(skillDirectory: "swiftui-glass", agent: .claude, enable: false)
        skills = try await service.loadInstalledSkills()
        XCTAssertEqual(skills[0].enabledAgents, [.codex])
        XCTAssertFalse(fileManager.fileExists(atPath: claudeLink.path))

        // 6. Bulk toggle ALL agents ON
        try await service.bulkToggleAllAgents(skillDirectory: "swiftui-glass", enable: true)
        skills = try await service.loadInstalledSkills()
        XCTAssertEqual(skills[0].enabledAgents.count, WorkspaceAgent.allCases.count)

        // 7. Uninstall skill and verify safe backup
        try await service.uninstallSkill(skillDirectory: "swiftui-glass")
        skills = try await service.loadInstalledSkills()
        XCTAssertTrue(skills.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: ssotSkillDir.path))
        XCTAssertFalse(fileManager.fileExists(atPath: tempHomeURL.appendingPathComponent(".codex/skills/swiftui-glass").path))

        // Verify backup exists in ~/.quotio/skill_backups
        let backupDir = tempHomeURL.appendingPathComponent(".quotio/skill_backups")
        let backups = try fileManager.contentsOfDirectory(atPath: backupDir.path)
        XCTAssertTrue(backups.contains(where: { $0.contains("swiftui-glass") }))
    }

    func testSkillLockImportPreservesExistingPrivateLibrary() async throws {
        // 已有私有技能不得在初始化或元数据同步时被搬回共享发现目录。
        let legacySkillDir = tempHomeURL.appendingPathComponent(".quotio/skills/legacy-skill")
        try fileManager.createDirectory(at: legacySkillDir, withIntermediateDirectories: true)
        try "name: Legacy Skill\n".write(to: legacySkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // Prepare ~/.agents/.skill-lock.json
        let agentsDir = tempHomeURL.appendingPathComponent(".agents")
        try fileManager.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let skillLockContent = """
        {
          "version": 3,
          "skills": {
            "grill-me": {
              "source": "mattpocock/skills",
              "sourceType": "github",
              "sourceUrl": "https://github.com/mattpocock/skills.git",
              "skillPath": "skills/productivity/grill-me/SKILL.md",
              "installedAt": "2026-08-08T03:49:22.152Z"
            }
          }
        }
        """
        try skillLockContent.write(to: agentsDir.appendingPathComponent(".skill-lock.json"), atomically: true, encoding: .utf8)

        // Initialize service
        let service = WorkspaceSkillService(homeDir: tempHomeURL.path)
        try await service.prepareStorage()

        XCTAssertTrue(fileManager.fileExists(atPath: legacySkillDir.path))
        XCTAssertFalse(fileManager.fileExists(atPath: tempHomeURL.appendingPathComponent(".agents/skills/legacy-skill").path))

        // 外部锁文件只补技能来源；不擅自增加用户仓库，也不复活用户移除的来源。
        let repos = try await service.loadRepos()
        XCTAssertFalse(repos.contains(where: { $0.owner == "mattpocock" && $0.name == "skills" }))
    }

    // MARK: - Storage Analysis Tests

    func testStorageAnalysisAndCacheClean() async throws {
        let service = WorkspaceStorageService(homeDir: tempHomeURL.path)

        // Create dummy cache files
        let claudeCache = tempHomeURL.appendingPathComponent(".claude/cache")
        try fileManager.createDirectory(at: claudeCache, withIntermediateDirectories: true)
        let dummyData = Data(repeating: 0x41, count: 1024 * 50) // 50 KB
        try dummyData.write(to: claudeCache.appendingPathComponent("cached_model.bin"))

        var report = await service.analyzeStorage()
        let claudeItem = report.items.first { $0.agent == .claude }
        XCTAssertNotNil(claudeItem)
        XCTAssertGreaterThanOrEqual(claudeItem?.cacheBytes ?? 0, 50 * 1024)

        // Clear cache
        let freed = try await service.clearCaches(for: .claude)
        XCTAssertGreaterThanOrEqual(freed, 50 * 1024)

        report = await service.analyzeStorage()
        let claudeItemAfter = report.items.first { $0.agent == .claude }
        XCTAssertEqual(claudeItemAfter?.cacheBytes, 0)
    }

    // MARK: - Cascade Deletion Tests

    func testCodexSessionCascadeDeletion() async throws {
        let codexDir = tempHomeURL.appendingPathComponent(".codex")
        let sessionsDir = codexDir.appendingPathComponent("sessions")
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let dbPath = codexDir.appendingPathComponent("state_5.sqlite").path

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)

        let createTables = """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            source TEXT NOT NULL,
            model_provider TEXT NOT NULL,
            cwd TEXT NOT NULL,
            title TEXT NOT NULL,
            archived INTEGER NOT NULL DEFAULT 0,
            first_user_message TEXT NOT NULL DEFAULT '',
            agent_nickname TEXT,
            agent_role TEXT
        );
        CREATE TABLE thread_spawn_edges (
            parent_thread_id TEXT NOT NULL,
            child_thread_id TEXT NOT NULL PRIMARY KEY,
            status TEXT NOT NULL
        );
        CREATE TABLE thread_artifacts (
            id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            artifact_type TEXT NOT NULL,
            identity_key TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at INTEGER NOT NULL
        );
        CREATE TABLE thread_dynamic_tools (
            thread_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            name TEXT NOT NULL,
            description TEXT NOT NULL,
            input_schema TEXT NOT NULL,
            PRIMARY KEY(thread_id, position)
        );
        """
        XCTAssertEqual(sqlite3_exec(db, createTables, nil, nil, nil), SQLITE_OK)

        // Create dummy rollout files on disk
        let parentRollout = sessionsDir.appendingPathComponent("rollout-parent.jsonl").path
        let childRollout = sessionsDir.appendingPathComponent("rollout-child.jsonl").path
        try "{}".write(toFile: parentRollout, atomically: true, encoding: .utf8)
        try "{}".write(toFile: childRollout, atomically: true, encoding: .utf8)

        let insertData = """
        INSERT INTO threads VALUES ('p-1', '\(parentRollout)', 1700000000, 1700000010, 'cli', 'openai', '/test', 'Parent Session', 0, 'Hi', NULL, NULL);
        INSERT INTO threads VALUES ('c-1', '\(childRollout)', 1700000005, 1700000015, 'subagent', 'openai', '/test', 'Child Subagent', 0, 'Sub', 'Darwin', 'coder');
        INSERT INTO thread_spawn_edges VALUES ('p-1', 'c-1', 'done');
        INSERT INTO thread_artifacts VALUES ('a-1', 'p-1', 'code', 'k1', '{}', 1700000000);
        INSERT INTO thread_dynamic_tools VALUES ('p-1', 0, 'exec', 'desc', '{}');
        """
        XCTAssertEqual(sqlite3_exec(db, insertData, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let service = WorkspaceSessionService(homeDir: tempHomeURL.path)
        let sessionsBefore = await service.scanAllSessions(agentFilter: .codex)
        XCTAssertEqual(sessionsBefore.count, 2)

        guard let parent = sessionsBefore.first(where: { $0.id == "p-1" }) else {
            XCTFail("Parent session not found")
            return
        }

        // Execute delete
        let success = try await service.deleteSession(parent)
        XCTAssertTrue(success)

        // Verify rollout files removed
        XCTAssertFalse(fileManager.fileExists(atPath: parentRollout))
        XCTAssertFalse(fileManager.fileExists(atPath: childRollout))

        // Verify SQLite tables cleaned
        XCTAssertEqual(sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM threads;", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 0)
        sqlite3_finalize(stmt)

        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM thread_spawn_edges;", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 0)
        sqlite3_finalize(stmt)
        sqlite3_close(db)

        // Verify rescan returns 0 sessions (no ghost sessions)
        let sessionsAfter = await service.scanAllSessions(agentFilter: .codex)
        XCTAssertEqual(sessionsAfter.count, 0)
    }

    func testOpenCodeSQLiteDiscoveryAndCascadeDeletion() async throws {
        let opencodeDir = tempHomeURL.appendingPathComponent(".local/share/opencode")
        try fileManager.createDirectory(at: opencodeDir, withIntermediateDirectories: true)
        let dbPath = opencodeDir.appendingPathComponent("opencode.db").path

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)

        let createTables = """
        CREATE TABLE session (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            directory TEXT,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL
        );
        CREATE TABLE message (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL,
            FOREIGN KEY (session_id) REFERENCES session(id) ON DELETE CASCADE
        );
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL,
            FOREIGN KEY (session_id) REFERENCES session(id) ON DELETE CASCADE
        );
        """
        XCTAssertEqual(sqlite3_exec(db, createTables, nil, nil, nil), SQLITE_OK)

        let insertData = """
        INSERT INTO session VALUES ('ses_1', 'Build API', '/Users/test/api-service', 1700000000000, 1700000010000);
        INSERT INTO message VALUES ('msg_1', 'ses_1', 1700000000000, 1700000000000, '{"role":"user"}');
        INSERT INTO part VALUES ('prt_1', 'msg_1', 'ses_1', 1700000000000, 1700000000000, '{"type":"text","text":"Create FastAPI backend"}');
        """
        XCTAssertEqual(sqlite3_exec(db, insertData, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let service = WorkspaceSessionService(homeDir: tempHomeURL.path)
        let sessions = await service.scanAllSessions(agentFilter: .opencode)
        XCTAssertEqual(sessions.count, 1)

        let session = sessions[0]
        XCTAssertEqual(session.id, "ses_1")
        XCTAssertEqual(session.title, "Build API")
        XCTAssertEqual(session.projectName, "api-service")

        let messages = try await service.loadSessionMessages(session: session)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "Create FastAPI backend")

        // Delete session
        let deleted = try await service.deleteSession(session)
        XCTAssertTrue(deleted)

        // Rescan verifies deleted
        let sessionsAfter = await service.scanAllSessions(agentFilter: .opencode)
        XCTAssertEqual(sessionsAfter.count, 0)
    }

    func testClaudeSessionWithSidecarDeletion() async throws {
        let claudeProjectsDir = tempHomeURL.appendingPathComponent(".claude/projects/test-project")
        try fileManager.createDirectory(at: claudeProjectsDir, withIntermediateDirectories: true)

        let sessionFile = claudeProjectsDir.appendingPathComponent("session-xyz.jsonl")
        try "{}".write(to: sessionFile, atomically: true, encoding: .utf8)

        let sidecarDir = claudeProjectsDir.appendingPathComponent("session-xyz")
        try fileManager.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
        let subFile = sidecarDir.appendingPathComponent("subagent-data.json")
        try "{}".write(to: subFile, atomically: true, encoding: .utf8)

        let session = WorkspaceSession(
            id: "session-xyz",
            agent: .claude,
            title: "Test Session",
            projectName: "test-project",
            lastActiveAt: Date(),
            filePath: sessionFile.path,
            fileSizeBytes: 2,
            messageCount: 1,
            resumeCommand: "claude resume session-xyz"
        )

        let service = WorkspaceSessionService(homeDir: tempHomeURL.path)
        let deleted = try await service.deleteSession(session)
        XCTAssertTrue(deleted)

        XCTAssertFalse(fileManager.fileExists(atPath: sessionFile.path))
        XCTAssertFalse(fileManager.fileExists(atPath: sidecarDir.path))
    }

    func testAGYSessionCascadeDeletion() async throws {
        let agyDir = tempHomeURL.appendingPathComponent(".gemini/antigravity-cli")
        let brainDir = agyDir.appendingPathComponent("brain/agy-del-1")
        let convsDir = agyDir.appendingPathComponent("conversations")
        try fileManager.createDirectory(at: brainDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: convsDir, withIntermediateDirectories: true)

        let dbPath = agyDir.appendingPathComponent("conversation_summaries.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)

        let schema = """
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            title TEXT,
            preview TEXT,
            step_count INTEGER,
            last_modified_time TEXT,
            workspace_uris TEXT
        );
        INSERT INTO conversation_summaries VALUES ('agy-del-1', 'AGY Title', 'Preview', 2, '2026-09-10T10:00:00Z', '["/Users/test/agy-proj"]');
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let convJson = convsDir.appendingPathComponent("agy-del-1.json")
        try "{}".write(to: convJson, atomically: true, encoding: .utf8)

        let service = WorkspaceSessionService(homeDir: tempHomeURL.path)
        let sessions = await service.scanAllSessions(agentFilter: .agy)
        XCTAssertEqual(sessions.count, 1)

        let deleted = try await service.deleteSession(sessions[0])
        XCTAssertTrue(deleted)

        XCTAssertFalse(fileManager.fileExists(atPath: brainDir.path))
        XCTAssertFalse(fileManager.fileExists(atPath: convJson.path))

        let sessionsAfter = await service.scanAllSessions(agentFilter: .agy)
        XCTAssertEqual(sessionsAfter.count, 0)
    }

    func testOpenCodeSubagentDiscoveryAndFolding() async throws {
        let opencodeDir = tempHomeURL.appendingPathComponent(".local/share/opencode")
        try fileManager.createDirectory(at: opencodeDir, withIntermediateDirectories: true)
        let dbPath = opencodeDir.appendingPathComponent("opencode.db").path

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        let schema = """
        CREATE TABLE session (
            id TEXT PRIMARY KEY,
            title TEXT,
            directory TEXT,
            time_created INTEGER,
            time_updated INTEGER,
            parent_id TEXT
        );
        INSERT INTO session VALUES ('ses_root', '主任务: 架构重构', '/Users/test/opencode-proj', 1720000000, 1720000100, NULL);
        INSERT INTO session VALUES ('ses_sub_1', '修复数据库连接池', '/Users/test/opencode-proj', 1720000050, 1720000090, 'ses_root');
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let service = WorkspaceSessionService(homeDir: tempHomeURL.path)
        let sessions = await service.scanAllSessions(agentFilter: .opencode)
        XCTAssertEqual(sessions.count, 2)

        let root = sessions.first { $0.id == "ses_root" }
        XCTAssertNotNil(root)
        XCTAssertFalse(root?.isSubagent ?? true)
        XCTAssertNil(root?.parentSessionID)
        XCTAssertEqual(root?.title, "主任务: 架构重构")

        let sub = sessions.first { $0.id == "ses_sub_1" }
        XCTAssertNotNil(sub)
        XCTAssertTrue(sub?.isSubagent ?? false)
        XCTAssertEqual(sub?.parentSessionID, "ses_root")

        // Test ViewModel tree folding
        let vm = await WorkspaceViewModel(sessionService: service, skillService: WorkspaceSkillService(homeDir: tempHomeURL.path), storageService: WorkspaceStorageService(homeDir: tempHomeURL.path))
        await MainActor.run {
            vm.sessions = sessions
            vm.selectedAgentFilter = .opencode

            // Root list should only contain the root session
            XCTAssertEqual(vm.rootFilteredSessions.count, 1)
            XCTAssertEqual(vm.rootFilteredSessions.first?.id, "ses_root")

            // Subagents helper should find the child
            let children = vm.subagents(for: "ses_root")
            XCTAssertEqual(children.count, 1)
            XCTAssertEqual(children.first?.id, "ses_sub_1")

            // Test expansion toggle
            XCTAssertFalse(vm.isSubagentExpanded("ses_root"))
            vm.toggleSubagentExpansion("ses_root")
            XCTAssertTrue(vm.isSubagentExpanded("ses_root"))
            vm.toggleSubagentExpansion("ses_root")
            XCTAssertFalse(vm.isSubagentExpanded("ses_root"))
        }

        // Test cascade deletion
        guard let parentSession = root else { return }
        let deleted = try await service.deleteSession(parentSession)
        XCTAssertTrue(deleted)

        let sessionsAfter = await service.scanAllSessions(agentFilter: .opencode)
        XCTAssertEqual(sessionsAfter.count, 0)
    }

    func testClaudeSubagentDirectoryDiscoveryAndFolding() async throws {
        let claudeProjectsDir = tempHomeURL.appendingPathComponent(".claude/projects/test-project")
        try fileManager.createDirectory(at: claudeProjectsDir, withIntermediateDirectories: true)

        let parentFile = claudeProjectsDir.appendingPathComponent("parent-uuid-001.jsonl")
        let parentLine = """
        {"sessionId": "parent-uuid-001", "cwd": "/Users/test/claude-proj", "timestamp": "2026-09-08T10:00:00Z", "type": "user", "message": {"role": "user", "content": "Root Claude Task"}}
        """
        try parentLine.write(to: parentFile, atomically: true, encoding: .utf8)

        let subagentsDir = claudeProjectsDir.appendingPathComponent("parent-uuid-001/subagents")
        try fileManager.createDirectory(at: subagentsDir, withIntermediateDirectories: true)

        let childFile = subagentsDir.appendingPathComponent("agent-sub-001.jsonl")
        let childLine = """
        {"sessionId": "agent-sub-001", "cwd": "/Users/test/claude-proj", "timestamp": "2026-09-08T10:05:00Z", "type": "user", "message": {"role": "user", "content": "Subagent step"}}
        """
        try childLine.write(to: childFile, atomically: true, encoding: .utf8)

        let childMetaFile = subagentsDir.appendingPathComponent("agent-sub-001.meta.json")
        let childMetaJson = """
        {
            "agentType": "researcher",
            "description": "API 性能深入分析",
            "spawnDepth": 1
        }
        """
        try childMetaJson.write(to: childMetaFile, atomically: true, encoding: .utf8)

        let service = WorkspaceSessionService(homeDir: tempHomeURL.path)
        let sessions = await service.scanAllSessions(agentFilter: .claude)
        XCTAssertEqual(sessions.count, 2)

        let parent = sessions.first { $0.id == "parent-uuid-001" }
        XCTAssertNotNil(parent)
        XCTAssertFalse(parent?.isSubagent ?? true)
        XCTAssertNil(parent?.parentSessionID)

        let child = sessions.first { $0.id == "agent-sub-001" }
        XCTAssertNotNil(child)
        XCTAssertTrue(child?.isSubagent ?? false)
        XCTAssertEqual(child?.parentSessionID, "parent-uuid-001")
        XCTAssertTrue(child?.title.contains("[researcher]") ?? false)
        XCTAssertTrue(child?.title.contains("API 性能深入分析") ?? false)

        // Test ViewModel tree folding
        let vm = await WorkspaceViewModel(sessionService: service, skillService: WorkspaceSkillService(homeDir: tempHomeURL.path), storageService: WorkspaceStorageService(homeDir: tempHomeURL.path))
        await MainActor.run {
            vm.sessions = sessions
            vm.selectedAgentFilter = .claude

            XCTAssertEqual(vm.rootFilteredSessions.count, 1)
            XCTAssertEqual(vm.rootFilteredSessions.first?.id, "parent-uuid-001")

            let children = vm.subagents(for: "parent-uuid-001")
            XCTAssertEqual(children.count, 1)
            XCTAssertEqual(children.first?.id, "agent-sub-001")
        }

        // Test cascade deletion removes parent and subagents folder
        guard let parentSession = parent else { return }
        let deleted = try await service.deleteSession(parentSession)
        XCTAssertTrue(deleted)

        let sessionsAfter = await service.scanAllSessions(agentFilter: .claude)
        XCTAssertEqual(sessionsAfter.count, 0)
        XCTAssertFalse(fileManager.fileExists(atPath: parentFile.path))
        XCTAssertFalse(fileManager.fileExists(atPath: subagentsDir.path))
    }

    func testAGYSubagentHierarchicalDiscoveryAndFolding() async throws {
        let agyDir = tempHomeURL.appendingPathComponent(".gemini/antigravity-cli")
        let brainDir1 = agyDir.appendingPathComponent("brain/agy-parent-1")
        let brainDir2 = agyDir.appendingPathComponent("brain/agy-child-1")
        try fileManager.createDirectory(at: brainDir1, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: brainDir2, withIntermediateDirectories: true)

        let dbPath = agyDir.appendingPathComponent("conversation_summaries.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        let schema = """
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            title TEXT,
            preview TEXT,
            step_count INTEGER,
            last_modified_time TEXT,
            workspace_uris TEXT,
            parent_conversation_id TEXT,
            nesting_depth INTEGER,
            agent_name TEXT
        );
        INSERT INTO conversation_summaries VALUES ('agy-parent-1', 'Root Planner', 'Main plan', 5, '2026-09-10T10:00:00Z', '["/Users/test/agy-proj"]', NULL, 0, NULL);
        INSERT INTO conversation_summaries VALUES ('agy-child-1', 'Review PR', 'Checking diffs', 2, '2026-09-10T10:05:00Z', '["/Users/test/agy-proj"]', 'agy-parent-1', 1, 'code-reviewer');
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let service = WorkspaceSessionService(homeDir: tempHomeURL.path)
        let sessions = await service.scanAllSessions(agentFilter: .agy)
        XCTAssertEqual(sessions.count, 2)

        let parent = sessions.first { $0.id == "agy-parent-1" }
        XCTAssertNotNil(parent)
        XCTAssertFalse(parent?.isSubagent ?? true)
        XCTAssertNil(parent?.parentSessionID)
        XCTAssertEqual(parent?.title, "Root Planner")

        let child = sessions.first { $0.id == "agy-child-1" }
        XCTAssertNotNil(child)
        XCTAssertTrue(child?.isSubagent ?? false)
        XCTAssertEqual(child?.parentSessionID, "agy-parent-1")
        XCTAssertEqual(child?.title, "[code-reviewer] Review PR")

        // Test ViewModel tree folding
        let vm = await WorkspaceViewModel(sessionService: service, skillService: WorkspaceSkillService(homeDir: tempHomeURL.path), storageService: WorkspaceStorageService(homeDir: tempHomeURL.path))
        await MainActor.run {
            vm.sessions = sessions
            vm.selectedAgentFilter = .agy

            XCTAssertEqual(vm.rootFilteredSessions.count, 1)
            XCTAssertEqual(vm.rootFilteredSessions.first?.id, "agy-parent-1")

            let children = vm.subagents(for: "agy-parent-1")
            XCTAssertEqual(children.count, 1)
            XCTAssertEqual(children.first?.id, "agy-child-1")
        }

        // Test cascade deletion: deleting parent deletes child brain and db entry
        guard let parentSession = parent else { return }
        let deleted = try await service.deleteSession(parentSession)
        XCTAssertTrue(deleted)

        let sessionsAfter = await service.scanAllSessions(agentFilter: .agy)
        XCTAssertEqual(sessionsAfter.count, 0)
        XCTAssertFalse(fileManager.fileExists(atPath: brainDir1.path))
        XCTAssertFalse(fileManager.fileExists(atPath: brainDir2.path))
    }
}
