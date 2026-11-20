// 使用隔离临时目录验证日志格式、日摘要与权限；禁止接触开发机真实会话和配置。
import XCTest
import SQLite3
@testable import QuotioPlus

final class CallAnalyticsMigrationTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quotio-calls-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func writeLines(_ lines: [[String: Any]], path: String, home: URL) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try lines.reduce(into: Data()) { data, object in
            data.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: url)
        return url
    }

    private func claudeCall(id: String, name: String, input: [String: Any] = [:]) -> [String: Any] {
        ["type": "assistant", "timestamp": "2026-09-04T12:00:00Z", "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]]
    }

    /// WAL 也属于唯一数据库的组成部分；隐私断言同时覆盖尚未 checkpoint 到主文件的写入。
    private func databaseContents(home: URL) throws -> Data {
        let path = AnalyticsDatabase.defaultURL(homeDirectory: home.path).path
        return try [path, path + "-wal", path + "-shm"].reduce(into: Data()) { data, file in
            if FileManager.default.fileExists(atPath: file) { data.append(try Data(contentsOf: URL(fileURLWithPath: file))) }
        }
    }

    /// 纯文本会话与工具日志走相同日期证据；复制、同步引起的 mtime 变化不得移动会话日期。
    func testPureTextSubagentDateAndCountSurviveCopyAndChangedModificationTime() throws {
        let home = try temporaryHome()
        let text: [String: Any] = ["type": "assistant", "timestamp": "2026-08-02T12:00:00Z",
            "sessionId": "parent-session", "agentId": "agent-unique",
            "message": ["content": [["type": "text", "text": "PRIVATE_TEXT_NOT_ARCHIVED"]]]]
        let file = try writeLines([text], path: ".claude/projects/p/subagents/agent-one.jsonl", home: home)
        try Data(#"{"agentType":"Explore"}"#.utf8).write(to: file.deletingPathExtension().appendingPathExtension("meta.json"))
        let source = ClaudeCallEventSource(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:])
        let first = try source.collect(cutoff: nil)
        XCTAssertTrue(first.entries.isEmpty)
        XCTAssertEqual(first.agentInvocationsByDay["2026-08-02"]?.first?.count, 1)
        XCTAssertEqual(first.agentInvocationsByDay["2026-08-02"]?.first?.agent, "Explore")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        let duplicate = try writeLines([text], path: ".claude/projects/copy/subagents/agent-renamed.jsonl", home: home)
        try Data(#"{"agentType":"Explore"}"#.utf8).write(to: duplicate.deletingPathExtension().appendingPathExtension("meta.json"))
        let second = try source.collect(cutoff: nil)
        XCTAssertEqual(Set(second.agentInvocationsByDay.keys), ["2026-08-02"])
        XCTAssertEqual(second.agentInvocationsByDay["2026-08-02"]?.first?.count, 1)
    }

    func testSessionWithoutTimestampRemainsUndatedDespiteRecentModificationTime() throws {
        let home = try temporaryHome()
        try writeLines([["type": "assistant", "sessionId": "undated", "message": ["content": "plain text"]]],
            path: ".claude/projects/p/subagents/agent-undated.jsonl", home: home)
        let result = try ClaudeCallEventSource(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:]).collect(cutoff: nil)
        XCTAssertEqual(Set(result.agentInvocationsByDay.keys), [""])
        XCTAssertEqual(result.agentInvocationsByDay[""]?.first?.count, 1)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testEngineArchivesPureTextSessionsByDayWithoutRescanOrDeletionLoss() async throws {
        let home = try temporaryHome()
        let file = try writeLines([["type": "assistant", "timestamp": "2026-08-02T12:00:00Z", "sessionId": "private-session-id",
            "message": ["content": "PRIVATE_TEXT_NOT_ARCHIVED"]]], path: ".claude/projects/p/subagents/agent-pure.jsonl", home: home)
        let engine = CallAnalyticsEngine(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:])
        let first = try await engine.refresh()
        let second = try await engine.refresh()
        try FileManager.default.removeItem(at: file)
        let third = try await engine.refresh()
        for snapshot in [first, second, third] {
            XCTAssertEqual(snapshot.agentInvocations.first?.count, 1)
            XCTAssertEqual(snapshot.agentInvocations.first?.dayKey, "2026-08-02")
            XCTAssertTrue(snapshot.entries.isEmpty)
        }
        let store = CallAnalyticsArchiveStore(homeDirectory: home.path)
        XCTAssertEqual(try store.load().agentInvocations.first?.dayKey, "2026-08-02")
        let raw = try databaseContents(home: home)
        XCTAssertNil(raw.range(of: Data("PRIVATE_TEXT_NOT_ARCHIVED".utf8)))
        XCTAssertNil(raw.range(of: Data("private-session-id".utf8)))
    }

    /// v6 的无日摘要可读；新扫描补回日期只消解未知余量，不叠加同批会话。
    func testLegacyAgentArchiveMigratesWithoutInventingDateOrDoubleCounting() throws {
        let home = try temporaryHome()
        let legacy = CallAnalyticsSnapshot(schemaVersion: 6, generatedAt: Date(), rangeKey: "all", entries: [],
            installedSkills: [], installedMCPServers: [],
            agentInvocations: [AgentInvocationCount(source: .claude, agent: "Explore", count: 3)], sources: [])
        let path = home.appendingPathComponent("Library/Application Support/Quotio/CallAnalytics/summary-v1.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(legacy).write(to: path)
        let store = CallAnalyticsArchiveStore(homeDirectory: home.path)
        XCTAssertNil(try store.load().agentInvocations.first?.dayKey)
        let fresh = CallAnalyticsSnapshot(generatedAt: Date(), rangeKey: "all", entries: [], installedSkills: [],
            installedMCPServers: [], agentInvocations: [AgentInvocationCount(source: .claude, agent: "Explore", count: 2, dayKey: "2026-08-02")], sources: [])
        let merged = try store.merge(fresh)
        XCTAssertEqual(merged.schemaVersion, CallAnalyticsSnapshot.currentSchemaVersion)
        XCTAssertEqual(merged.agentInvocations.reduce(0) { $0 + $1.count }, 3)
        XCTAssertEqual(merged.agentInvocations.first { $0.dayKey == nil }?.count, 1)
        XCTAssertEqual(try store.merge(fresh).agentInvocations.reduce(0) { $0 + $1.count }, 3)
        XCTAssertEqual(try store.merge(.empty).agentInvocations.reduce(0) { $0 + $1.count }, 3)
    }

    func testClaudePairsResultAndDeduplicatesRepeatedToolUse() throws {
        let home = try temporaryHome()
        let call = claudeCall(id: "call1", name: "mcp__demo__search", input: ["secret": "NEVER_PERSIST_THIS_ARGUMENT"])
        try writeLines([call, call, ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "call1", "is_error": true]]]], claudeCall(id: "call2", name: "Read")], path: ".claude/projects/p/session.jsonl", home: home)
        let result = try ClaudeCallEventSource(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:]).collect(cutoff: nil)
        XCTAssertEqual(result.status.eventCount, 2)
        let mcp = try XCTUnwrap(result.entries.first { $0.kind == .mcp })
        XCTAssertEqual(mcp.name, "demo/search")
        XCTAssertEqual(mcp.successRate, 0)
        XCTAssertNil(mcp.avgDurationMs)
        XCTAssertNil(result.entries.first { $0.name == "Read" }?.successRate)
    }

    func testCodexUsesStructuredEventsDeduplicatesAndDetectsSkillReads() throws {
        let home = try temporaryHome()
        let call: [String: Any] = ["type": "response_item", "timestamp": "2026-09-04T12:00:00Z", "payload": ["type": "function_call", "call_id": "c1", "name": "mcp__demo__search", "arguments": "{}"]]
        let end: [String: Any] = ["type": "event_msg", "timestamp": "2026-09-04T12:00:01Z", "payload": ["type": "mcp_tool_call_end", "call_id": "c1", "invocation": ["server": "demo", "tool": "search"], "result": ["Ok": [:]], "duration": ["secs": 1, "nanos": 500_000_000]]]
        let skill: [String: Any] = ["type": "response_item", "timestamp": "2026-09-04T12:00:02Z", "payload": ["type": "function_call", "call_id": "c2", "name": "exec_command", "arguments": "{\"cmd\":\"cat /tmp/skills/review/SKILL.md\"}"]]
        let fake: [String: Any] = ["type": "response_item", "payload": ["type": "function_call_output", "output": "function_call mcp_tool_call_end"]]
        try writeLines([call, end, skill, fake], path: ".codex/sessions/s.jsonl", home: home)
        try writeLines([call, end], path: ".codex/archived_sessions/s.jsonl", home: home)
        let result = try CodexCallEventSource(homeDirectory: home.path, timeZone: .current, environment: [:]).collect(cutoff: nil)
        XCTAssertEqual(result.status.eventCount, 3)
        let mcp = try XCTUnwrap(result.entries.first { $0.kind == .mcp })
        XCTAssertEqual(mcp.count, 1)
        XCTAssertEqual(mcp.successRate, 1)
        XCTAssertEqual(mcp.avgDurationMs, 1500)
        XCTAssertEqual(result.entries.first { $0.kind == .skill }?.name, "review")
    }

    func testOpenCodeReadsSpacedJSONThroughReadOnlyDatabase() throws {
        let home = try temporaryHome()
        let dbURL = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE part (time_created INTEGER, data TEXT)", nil, nil, nil), SQLITE_OK)
        let raw = #"{"type": "tool", "tool": "my_server_search", "state": {"status": "completed", "time": {"start": 100, "end": 400}}}"#
        XCTAssertEqual(sqlite3_exec(database, "INSERT INTO part VALUES (1788523200000, '" + raw + "')", nil, nil, nil), SQLITE_OK)
        let before = try Data(contentsOf: dbURL)
        let result = try OpenCodeCallEventSource(homeDirectory: home.path, timeZone: .current, environment: [:], knownMCPServers: ["my_server"]).collect(cutoff: nil)
        XCTAssertNil(result.status.errorCode)
        XCTAssertEqual(result.entries.first?.name, "my_server/search")
        XCTAssertEqual(result.entries.first?.successRate, 1)
        XCTAssertEqual(result.entries.first?.avgDurationMs, 300)
        XCTAssertEqual(try Data(contentsOf: dbURL), before)
    }

    /// 同一个毫秒内的前、等、后边界均来自声明；迟到结果和文件修改时间都不能补发起时间。
    func testClaudeResetFiltersDeclarationsAndDoesNotRestartOldAgents() throws {
        let home = try temporaryHome()
        let zone = TimeZone(secondsFromGMT: 0)!
        let clock = CallAnalyticsClock(timeZone: zone)
        let reset = try XCTUnwrap(clock.invocationDate(fromISO: "2026-09-04T12:00:00.123500Z", cutoff: .distantPast))
        func call(_ id: String, _ fraction: String?) -> [String: Any] {
            var event = claudeCall(id: id, name: id)
            event["timestamp"] = fraction.map { "2026-09-04T12:00:00.\($0)Z" }
            event["sessionId"] = "same-session"
            return event
        }
        func result(_ id: String) -> [String: Any] {
            ["type": "user", "timestamp": "2026-09-04T12:00:01Z",
             "message": ["content": [["type": "tool_result", "tool_use_id": id]]]]
        }
        try writeLines([call("old", "123400"), call("equal", "123500"), call("undated", nil),
                        result("old"), result("undated"), call("new", "123600"), result("new")],
                       path: ".claude/projects/p/session.jsonl", home: home)
        try writeLines([result("missing-declaration")], path: ".claude/projects/p/subagents/agent-orphan.jsonl", home: home)
        try writeLines([["type": "assistant", "timestamp": "2026-09-04T12:01:00Z",
                         "message": ["content": "new text-only agent"]]],
                       path: ".claude/projects/p/subagents/agent-new.jsonl", home: home)
        let scan = try ClaudeCallEventSource(homeDirectory: home.path, timeZone: zone, environment: [:]).collect(cutoff: reset)
        XCTAssertEqual(scan.entries.map(\.name), ["new"])
        XCTAssertEqual(scan.entries.first?.successCount, 1)
        XCTAssertEqual(scan.status.eventCount, 1)
        let started = scan.agentInvocationsByDay["2026-09-04", default: []]
        XCTAssertEqual(started.map(\.agent), ["subagent"])
        XCTAssertEqual(started.map(\.count), [1])
    }

    /// MCP 结果先读到也只能补全同 ID 的新声明；跨午夜的完成时间不能重分发起日。
    func testCodexResetRejectsOldOrMissingDeclarationsAndPreservesInvocationDay() throws {
        let home = try temporaryHome()
        let zone = TimeZone(secondsFromGMT: 0)!
        let reset = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-04T23:59:58Z"))
        func call(_ id: String, _ timestamp: String?, type: String = "function_call", name: String = "mcp__demo__search") -> [String: Any] {
            var event: [String: Any] = ["type": "response_item", "payload": ["type": type, "call_id": id,
                "name": name, "input": "read /tmp/skills/review/SKILL.md"]]
            event["timestamp"] = timestamp
            return event
        }
        func end(_ id: String) -> [String: Any] {
            ["type": "event_msg", "timestamp": "2026-09-05T00:00:01Z", "payload": ["type": "mcp_tool_call_end", "call_id": id,
             "invocation": ["server": "demo", "tool": "search"], "result": ["Ok": [:]], "duration": ["secs": 2]]]
        }
        let new = call("new", "2026-09-04T23:59:59Z")
        let file = try writeLines([end("new"), call("old", "2026-09-04T23:59:57Z"), end("old"),
            call("equal", "2026-09-04T23:59:58Z"), end("equal"), call("undated", nil), end("undated"), end("orphan"), new,
            call("skill", "2026-09-04T23:59:59Z", type: "custom_tool_call", name: "exec_command")],
            path: ".codex/sessions/s.jsonl", home: home)
        try writeLines([new], path: ".codex/archived_sessions/s.jsonl", home: home)
        try FileManager.default.setAttributes([.modificationDate: reset.addingTimeInterval(-60)], ofItemAtPath: file.path)
        let scan = try CodexCallEventSource(homeDirectory: home.path, timeZone: zone, environment: [:]).collect(cutoff: reset)
        XCTAssertNil(scan.status.errorCode)
        XCTAssertEqual(scan.status.eventCount, 3, "一个通用执行调用、一个技能使用信号和一个 MCP 调用")
        XCTAssertEqual(Set(scan.entries.map(\.dayKey)), ["2026-09-04"])
        let mcp = try XCTUnwrap(scan.entries.first { $0.kind == .mcp })
        XCTAssertEqual(mcp.count, 1)
        XCTAssertEqual(mcp.successRate, 1)
        XCTAssertEqual(mcp.avgDurationMs, 2_000)
        XCTAssertEqual(scan.entries.first { $0.kind == .skill }?.name, "review")
    }

    func testOpenCodeResetUsesStrictPartCreationTimeNotStateTime() throws {
        let home = try temporaryHome()
        let url = home.appendingPathComponent(".local/share/opencode/opencode.db")
        let database = AnalyticsDatabase(url: url)
        try database.execute("CREATE TABLE part (time_created INTEGER, data TEXT)")
        let resetMillis: Int64 = 1_788_523_200_123
        let reset = Date(timeIntervalSince1970: Double(resetMillis) / 1000)
        for (created, name) in [(resetMillis - 1, "write"), (resetMillis, "bash"), (resetMillis + 1, "read")] {
            // 所有 part 的 state 都在水位之后完成；资格仍只看创建列。
            let part = #"{"type":"tool","tool":"\#(name)","state":{"status":"completed","time":{"start":\#(resetMillis+1),"end":\#(resetMillis+501)}}}"#
            try database.execute("INSERT INTO part VALUES (?,?)", [.integer(created), .text(part)])
        }
        let scan = try OpenCodeCallEventSource(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:]).collect(cutoff: reset)
        XCTAssertNil(scan.status.errorCode)
        XCTAssertEqual(scan.status.eventCount, 1)
        XCTAssertEqual(scan.entries.map(\.name), ["read"])
        XCTAssertEqual(scan.entries.first?.successRate, 1)
        XCTAssertEqual(scan.entries.first?.avgDurationMs, 500)
    }

    /// 验证 Pi 原有的 ISO 条目优先级和消息毫秒回退，不从 toolResult 产生新调用。
    func testPiResetUsesAssistantInvocationAndKeepsMatchingResult() throws {
        let home = try temporaryHome()
        let zone = TimeZone(secondsFromGMT: 0)!
        let resetMillis: Int64 = 1_788_523_200_123
        let reset = Date(timeIntervalSince1970: Double(resetMillis) / 1000)
        func call(_ id: String, iso: String? = nil, millis: Int64) -> [String: Any] {
            var event: [String: Any] = ["type": "message", "id": "entry-\(id)", "message": ["role": "assistant", "timestamp": millis,
                "content": [["type": "toolCall", "id": id, "name": id]]]]
            event["timestamp"] = iso
            return event
        }
        func result(_ id: String, failed: Bool) -> [String: Any] {
            ["type": "message", "timestamp": "2026-09-04T12:01:00Z", "message": ["role": "toolResult", "toolCallId": id, "isError": failed]]
        }
        try writeLines([call("old-iso", iso: "2026-09-04T12:00:00.122Z", millis: resetMillis + 1), result("old-iso", failed: false),
                        call("equal", millis: resetMillis), result("equal", failed: false), result("orphan", failed: false),
                        call("new-ms", millis: resetMillis + 1), result("new-ms", failed: true),
                        call("new-iso", iso: "2026-09-04T12:00:00.123600Z", millis: resetMillis - 1)],
                       path: ".pi/agent/sessions/p/session.jsonl", home: home)
        let scan = try PiCallEventSource(homeDirectory: home.path, timeZone: zone, environment: [:]).collect(cutoff: reset)
        XCTAssertNil(scan.status.errorCode)
        XCTAssertEqual(scan.status.eventCount, 2)
        XCTAssertEqual(Set(scan.entries.map(\.name)), ["new-ms", "new-iso"])
        XCTAssertEqual(scan.entries.first { $0.name == "new-ms" }?.successRate, 0)
        XCTAssertNil(scan.entries.first { $0.name == "new-iso" }?.successRate)
    }

    func testInvalidDatabaseReportsFailureInsteadOfEmptySuccess() throws {
        let home = try temporaryHome()
        let url = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: url)
        let result = try OpenCodeCallEventSource(homeDirectory: home.path, timeZone: .current, environment: [:]).collect(cutoff: nil)
        XCTAssertNotNil(result.status.errorCode)
        XCTAssertTrue(result.status.available)
    }

    func testEnginePersistsPrivateSummaryWithoutRawArgumentsAndDoesNotDoubleCount() async throws {
        let home = try temporaryHome()
        let file = try writeLines([claudeCall(id: "c1", name: "Skill", input: ["skill": "review", "arguments": "NEVER_PERSIST_THIS_ARGUMENT"])], path: ".claude/projects/p/session.jsonl", home: home)
        let engine = CallAnalyticsEngine(homeDirectory: home.path, timeZone: .current, environment: [:])
        let first = try await engine.refresh()
        let second = try await engine.refresh()
        XCTAssertEqual(first.totalCalls, 1)
        XCTAssertEqual(second.totalCalls, 1)
        try FileManager.default.removeItem(at: file)
        let afterRemoval = try await engine.refresh()
        XCTAssertEqual(afterRemoval.totalCalls, 1)
        let freshEngine = CallAnalyticsEngine(homeDirectory: home.path, timeZone: .current, environment: [:])
        let cached = try await freshEngine.cachedSnapshot()
        XCTAssertEqual(cached.totalCalls, 1)
        let cacheURL = AnalyticsDatabase.defaultURL(homeDirectory: home.path)
        let raw = try databaseContents(home: home)
        XCTAssertNil(raw.range(of: Data("NEVER_PERSIST_THIS_ARGUMENT".utf8)))
        XCTAssertNil(raw.range(of: Data("tool_use".utf8)))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Quotio/CallAnalytics/summary-v1.json").path))
    }

    func testArchiveAcceptsLateCountButNeverAddsSameSnapshotAgain() throws {
        let home = try temporaryHome()
        let archive = CallAnalyticsArchiveStore(homeDirectory: home.path)
        func snapshot(_ count: Int) -> CallAnalyticsSnapshot {
            CallAnalyticsSnapshot(generatedAt: Date(), rangeKey: "all", entries: [CallAnalyticsEntry(source: .claude, kind: .builtin, name: "Read", server: nil, dayKey: "2026-09-01", count: count)], installedSkills: [], installedMCPServers: [], sources: [])
        }
        XCTAssertEqual(try archive.merge(snapshot(1)).totalCalls, 1)
        XCTAssertEqual(try archive.merge(snapshot(2)).totalCalls, 2)
        XCTAssertEqual(try archive.merge(snapshot(2)).totalCalls, 2)
        XCTAssertEqual(try archive.merge(snapshot(0)).totalCalls, 2)
    }

    /// 冷库清理先发布边界和迁移墓碑，首次引擎初始化同时拒绝旧 JSON 和会话中的旧调用。
    func testColdCallClearPreventsLegacyAndSourceLogReimport() async throws {
        let home = try temporaryHome()
        let log = try writeLines([claudeCall(id: "old", name: "Read")], path: ".claude/projects/p/session.jsonl", home: home)
        let logsBefore = try Data(contentsOf: log)
        let legacy = CallAnalyticsSnapshot(generatedAt: Date(), rangeKey: "all",
            entries: [CallAnalyticsEntry(source: .claude, kind: .builtin, name: "Read", server: nil, dayKey: "2026-09-04", count: 9)],
            installedSkills: [], installedMCPServers: [], sources: [])
        let legacyURL = home.appendingPathComponent("Library/Application Support/Quotio/CallAnalytics/summary-v1.json")
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyBytes = try JSONEncoder().encode(legacy)
        try legacyBytes.write(to: legacyURL)
        let url = AnalyticsDatabase.defaultURL(homeDirectory: home.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        _ = try await StorageMaintenanceStore(databaseURL: url).clearStatistics([.callAnalytics])
        // 在首次引擎初始化之前，冷库中的提交边界已经可供独立连接读取。
        XCTAssertGreaterThan(try XCTUnwrap(CallAnalyticsArchiveStore(homeDirectory: home.path).lastReset()).generation, 0)
        let engine = CallAnalyticsEngine(homeDirectory: home.path, environment: [:])
        let cached = try await engine.cachedSnapshot()
        let refreshed = try await engine.refresh()
        XCTAssertEqual(cached.generatedAt, .distantPast)
        XCTAssertEqual(cached.totalCalls, 0)
        XCTAssertEqual(refreshed.totalCalls, 0)
        XCTAssertTrue(refreshed.agentInvocations.isEmpty)
        XCTAssertEqual(refreshed.sources.first { $0.source == .claude }?.filesScanned, 1)
        XCTAssertEqual(try Data(contentsOf: log), logsBefore)
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyBytes)
    }

    /// 模拟清理前已开始但清理后才写入的扫描，旧汇总和成功指纹都不能重新提交。
    func testArchiveRejectsMergeFromBeforeCommittedReset() async throws {
        let home = try temporaryHome()
        let archive = CallAnalyticsArchiveStore(homeDirectory: home.path)
        let fresh = CallAnalyticsSnapshot(generatedAt: Date(), rangeKey: "all",
            entries: [CallAnalyticsEntry(source: .claude, kind: .builtin, name: "Read", server: nil, dayKey: "2026-09-04", count: 1)],
            installedSkills: [], installedMCPServers: [], sources: [])
        let before = try archive.lastReset()
        XCTAssertNil(before)
        XCTAssertEqual(try archive.merge(fresh, observedReset: before).totalCalls, 1)
        _ = try await StorageMaintenanceStore(databaseURL: AnalyticsDatabase.defaultURL(homeDirectory: home.path)).clearStatistics([.callAnalytics])
        XCTAssertThrowsError(try archive.merge(fresh, scannedSources: [.claude],
                                               successfulFingerprints: [.claude: "stale"], observedReset: before)) {
            guard case CallAnalyticsReadError.resetDuringScan = $0 else { return XCTFail("应拒绝使用旧重置边界的扫描") }
        }
        XCTAssertEqual(try archive.load().totalCalls, 0)
        XCTAssertNil(try archive.successfulFingerprint(for: .claude))
    }

    /// 两个维护连接固定在同一墙钟时刻；重新打开归档也必须读到新代次，而不是复用相同时间。
    func testEqualTimeClearsRejectStalePublicationAcrossConnections() async throws {
        let home = try temporaryHome()
        let url = AnalyticsDatabase.defaultURL(homeDirectory: home.path)
        let cutoff = Date(timeIntervalSince1970: 200)
        var declaration = claudeCall(id: "between", name: "Read")
        declaration["timestamp"] = "1970-01-01T00:03:21Z"
        let log = try writeLines([declaration], path: ".claude/projects/p/session.jsonl", home: home)
        let originalLog = try Data(contentsOf: log)

        _ = try await StorageMaintenanceStore(databaseURL: url, callResetClock: { cutoff }).clearStatistics([.callAnalytics])
        let archive = CallAnalyticsArchiveStore(homeDirectory: home.path)
        let first = try XCTUnwrap(archive.lastReset())
        let scan = try await CallAnalyticsEngine(homeDirectory: home.path, environment: [:]).refresh()
        XCTAssertEqual(scan.totalCalls, 1)
        XCTAssertEqual(scan.sources.first { $0.source == .claude }?.eventCount, 1)
        let fingerprint = try XCTUnwrap(archive.successfulFingerprint(for: .claude))

        _ = try await StorageMaintenanceStore(databaseURL: url, callResetClock: { cutoff }).clearStatistics([.callAnalytics])
        let reopened = CallAnalyticsArchiveStore(homeDirectory: home.path)
        let second = try XCTUnwrap(reopened.lastReset())
        XCTAssertEqual(first.clearedAt, cutoff)
        XCTAssertEqual(second.clearedAt, first.clearedAt)
        XCTAssertGreaterThan(second.generation, first.generation)
        XCTAssertEqual(try archive.lastReset(), second)

        XCTAssertThrowsError(try archive.merge(scan, scannedSources: [.claude],
                                               successfulFingerprints: [.claude: fingerprint], observedReset: first)) {
            guard case CallAnalyticsReadError.resetDuringScan = $0 else { return XCTFail("同一时间戳不能让旧代次提交") }
        }
        let cached = try reopened.load()
        XCTAssertEqual(cached.totalCalls, 0)
        XCTAssertTrue(cached.agentInvocations.isEmpty)
        XCTAssertTrue(cached.sources.isEmpty)
        XCTAssertEqual(cached.generatedAt, .distantPast)
        XCTAssertNil(try reopened.successfulFingerprint(for: .claude))
        XCTAssertEqual(try Data(contentsOf: log), originalLog)
    }

    /// 旧版只有 cleared_at：读取不迁移，首次清理在原事务中升级同一行，且时间相同也会拒绝旧扫描。
    func testTimestampOnlyResetRetainsCutoffUntilNextClear() async throws {
        let home = try temporaryHome()
        let url = AnalyticsDatabase.defaultURL(homeDirectory: home.path)
        let database = AnalyticsDatabase(url: url)
        try database.execute("CREATE TABLE call_analytics_reset(id INTEGER PRIMARY KEY CHECK(id=1), cleared_at REAL NOT NULL)")
        let cutoff = Date(timeIntervalSince1970: 200)
        try database.execute("INSERT INTO call_analytics_reset VALUES(1,?)", [.real(cutoff.timeIntervalSince1970)])
        var old = claudeCall(id: "old", name: "old")
        old["timestamp"] = "1970-01-01T00:03:10Z"
        var new = claudeCall(id: "new", name: "new")
        new["timestamp"] = "1970-01-01T00:03:21Z"
        try writeLines([old, new], path: ".claude/projects/p/session.jsonl", home: home)

        let archive = CallAnalyticsArchiveStore(homeDirectory: home.path)
        let legacy = try XCTUnwrap(archive.lastReset())
        XCTAssertEqual(legacy.clearedAt, cutoff)
        let scan = try await CallAnalyticsEngine(homeDirectory: home.path, environment: [:]).refresh()
        XCTAssertEqual(scan.entries.map(\.name), ["new"])
        XCTAssertNil(try database.scalarInt("SELECT 1 FROM pragma_table_info('call_analytics_reset') WHERE name='generation'"))

        _ = try await StorageMaintenanceStore(databaseURL: url, callResetClock: { cutoff }).clearStatistics([.callAnalytics])
        let upgraded = try XCTUnwrap(archive.lastReset())
        XCTAssertEqual(upgraded.clearedAt, cutoff)
        XCTAssertGreaterThan(upgraded.generation, legacy.generation)
        XCTAssertThrowsError(try archive.merge(scan, observedReset: legacy)) {
            guard case CallAnalyticsReadError.resetDuringScan = $0 else { return XCTFail("旧时间表生成的扫描不能跨升级清理提交") }
        }
        XCTAssertEqual(try archive.load().totalCalls, 0)
    }

    func testCalendarRangesAndReversedCustomDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-05T12:00:00Z"))
        let week = CallAnalyticsDateRange.week.bounds(now: now, start: now, end: now, calendar: calendar)
        XCTAssertEqual(week.0, "2026-08-31")
        XCTAssertEqual(week.1, "2026-09-05")
        let month = CallAnalyticsDateRange.month.bounds(now: now, start: now, end: now, calendar: calendar)
        XCTAssertEqual(month.0, "2026-09-01")
        let earlier = now.addingTimeInterval(-86400)
        let custom = CallAnalyticsDateRange.custom.bounds(now: now, start: now, end: earlier, calendar: calendar)
        XCTAssertEqual(custom.0, "2026-09-04")
        XCTAssertEqual(custom.1, "2026-09-05")
    }

    func testReportFiltersSourcesDaysAndUsesOnlyKnownOutcomeSamples() {
        let snapshot = CallAnalyticsSnapshot(generatedAt: Date(), rangeKey: "all", entries: [
            CallAnalyticsEntry(source: .claude, kind: .skill, name: "review", server: nil, dayKey: "2026-09-04", count: 10, outcomeKnownCount: 2, successCount: 1),
            CallAnalyticsEntry(source: .codex, kind: .builtin, name: "exec_command", server: nil, dayKey: "2026-09-03", count: 100)
        ], installedSkills: [InstalledItem(source: .claude, name: "review"), InstalledItem(source: .claude, name: "unused")], installedMCPServers: [], sources: [CallSourceStatus(source: .claude, available: true, eventCount: 10, filesScanned: 1, errorCode: nil)])
        let report = CallAnalyticsReport(snapshot: snapshot, lowerDay: "2026-09-04", upperDay: "2026-09-04", source: .claude, kind: nil)
        XCTAssertEqual(report.totalCalls, 10)
        XCTAssertEqual(report.successRate, 0.5)
        XCTAssertNil(report.averageDuration)
        XCTAssertEqual(report.trend.count, 1)
        XCTAssertEqual(report.unused.map(\.name), ["unused"])
    }

    func testOversizedLogLineReportsErrorRatherThanSilentlyLosingCalls() throws {
        let home = try temporaryHome()
        let file = home.appendingPathComponent("huge.jsonl")
        try Data((String(repeating: "a", count: 2048) + "\n").utf8).write(to: file)
        XCTAssertThrowsError(try CallAnalyticsLineReader.forEachLine(path: file.path, needles: [], maxLineBytes: 128) { _ in })
    }

    func testCancelledScanDoesNotCreateArchive() async throws {
        let home = try temporaryHome()
        let engine = CallAnalyticsEngine(homeDirectory: home.path, environment: [:])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.refresh()
        }
        do { _ = try await task.value; XCTFail("取消扫描不应返回成功结果") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: AnalyticsDatabase.defaultURL(homeDirectory: home.path).path))
    }

    func testColdFailureDoesNotPresentZeroOrUnusedConclusions() {
        let snapshot = CallAnalyticsSnapshot(generatedAt: Date(), rangeKey: "all", entries: [],
            installedSkills: [InstalledItem(source: .claude, name: "review")],
            installedMCPServers: [InstalledItem(source: .claude, name: "demo")],
            sources: [CallSourceStatus(source: .claude, available: true, eventCount: 0, filesScanned: 0, errorCode: "read_failed")])
        let report = CallAnalyticsReport(snapshot: snapshot, lowerDay: nil, upperDay: nil, source: nil, kind: nil)
        XCTAssertFalse(report.canDisplayTotals)
        XCTAssertTrue(report.hasReadFailures)
        XCTAssertTrue(report.unused.isEmpty)
    }

    func testPartialFailureRetainsCountsButExcludesFailedSourceFromUnused() {
        let snapshot = CallAnalyticsSnapshot(generatedAt: Date(), rangeKey: "all", entries: [
            CallAnalyticsEntry(source: .claude, kind: .builtin, name: "Read", server: nil, dayKey: "2026-09-04", count: 5)
        ], installedSkills: [InstalledItem(source: .claude, name: "failed-source"), InstalledItem(source: .codex, name: "readable-source")],
        installedMCPServers: [], sources: [
            CallSourceStatus(source: .claude, available: true, eventCount: 0, filesScanned: 0, errorCode: "read_failed"),
            CallSourceStatus(source: .codex, available: true, eventCount: 0, filesScanned: 1, errorCode: nil)
        ])
        let report = CallAnalyticsReport(snapshot: snapshot, lowerDay: nil, upperDay: nil, source: nil, kind: nil)
        XCTAssertTrue(report.canDisplayTotals)
        XCTAssertTrue(report.hasReadFailures)
        XCTAssertEqual(report.totalCalls, 5)
        XCTAssertEqual(report.unused.map(\.name), ["readable-source"])
    }

    func testSuccessfullyReadEmptySourceCanPresentTrueZero() {
        let snapshot = CallAnalyticsSnapshot(generatedAt: Date(), rangeKey: "all", entries: [], installedSkills: [],
            installedMCPServers: [], sources: [CallSourceStatus(source: .codex, available: true, eventCount: 0, filesScanned: 1, errorCode: nil)])
        let report = CallAnalyticsReport(snapshot: snapshot, lowerDay: nil, upperDay: nil, source: nil, kind: nil)
        XCTAssertTrue(report.canDisplayTotals)
        XCTAssertFalse(report.hasReadFailures)
        XCTAssertEqual(report.totalCalls, 0)
    }


    func testUnreadableDirectoryIsReportedAsFailureInsteadOfZeroCalls() throws {
        let home = try temporaryHome()
        let file = try writeLines([claudeCall(id: "c1", name: "Read")], path: ".claude/projects/p/session.jsonl", home: home)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let source = ClaudeCallEventSource(homeDirectory: home.path, timeZone: .current, environment: [:])
        XCTAssertThrowsError(try source.collect(cutoff: nil))
    }

    /// 旧文件只导入一次；后续实例从结构化 SQL 行恢复，不因旧备份变化覆盖新数据。
    func testSQLiteMigrationPreservesColumnsAndDoesNotReimportLegacyFile() throws {
        let home = try temporaryHome()
        let legacyURL = home.appendingPathComponent("Library/Application Support/Quotio/CallAnalytics/summary-v1.json")
        let entries = [
            CallAnalyticsEntry(source: .claude, kind: .mcp, name: "引用'与中文", server: nil, agent: "", dayKey: "2026-08-01",
                count: 8, outcomeKnownCount: 5, successCount: 4, durationSampleCount: 3, durationMsTotal: 42.5),
            CallAnalyticsEntry(source: .claude, kind: .mcp, name: "引用'与中文", server: "", agent: nil, dayKey: "2026-08-01", count: 2)
        ]
        let legacy = CallAnalyticsSnapshot(generatedAt: Date(timeIntervalSince1970: 123), rangeKey: "all", entries: entries,
            installedSkills: [InstalledItem(source: .claude, name: "review")],
            installedMCPServers: [InstalledItem(source: .codex, name: "demo")],
            agentInvocations: [AgentInvocationCount(source: .claude, agent: "Explore", count: 3)],
            sources: [CallSourceStatus(source: .claude, available: true, eventCount: 10, filesScanned: 2, errorCode: "read_partial")])
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(legacy).write(to: legacyURL)
        let store = CallAnalyticsArchiveStore(homeDirectory: home.path)
        let imported = try store.load()
        XCTAssertEqual(Set(imported.entries), Set(entries))
        XCTAssertEqual(imported.agentInvocations, legacy.agentInvocations)
        XCTAssertEqual(imported.installedSkills, legacy.installedSkills)
        XCTAssertEqual(imported.installedMCPServers, legacy.installedMCPServers)
        XCTAssertEqual(imported.sources.first?.errorCode, "read_partial")
        XCTAssertEqual(imported.generatedAt, legacy.generatedAt)
        try Data("已迁移的备份可以不再解码".utf8).write(to: legacyURL)
        XCTAssertEqual(try CallAnalyticsArchiveStore(homeDirectory: home.path).load().totalCalls, 10)
        let database = AnalyticsDatabase(url: AnalyticsDatabase.defaultURL(homeDirectory: home.path))
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM call_daily"), 2)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM analytics_migrations WHERE id='call_analytics_json_v1'"), 1)
    }

    func testFailedJSONMigrationCanRetryWithoutLosingHistory() throws {
        let home = try temporaryHome()
        let legacyURL = home.appendingPathComponent("Library/Application Support/Quotio/CallAnalytics/summary-v1.json")
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: legacyURL)
        let store = CallAnalyticsArchiveStore(homeDirectory: home.path)
        XCTAssertThrowsError(try store.load())
        let database = AnalyticsDatabase(url: AnalyticsDatabase.defaultURL(homeDirectory: home.path))
        XCTAssertFalse(try database.hasMigration("call_analytics_json_v1"))
        let fixed = CallAnalyticsSnapshot(generatedAt: Date(), rangeKey: "all",
            entries: [CallAnalyticsEntry(source: .pi, kind: .builtin, name: "read", server: nil, dayKey: "2026-08-01", count: 6)],
            installedSkills: [], installedMCPServers: [], sources: [])
        try JSONEncoder().encode(fixed).write(to: legacyURL)
        XCTAssertEqual(try store.load().totalCalls, 6)
        XCTAssertTrue(try database.hasMigration("call_analytics_json_v1"))
    }

    /// 不变来源不解析日志，追加一个来源时其他来源也不重扫；进程重建仍使用同一 SQL 指纹。
    func testEngineSkipsUnchangedSourcesAndRestoresCheckpointAfterRestart() async throws {
        let home = try temporaryHome()
        try writeLines([claudeCall(id: "one", name: "Read")], path: ".claude/projects/p/a.jsonl", home: home)
        let codex: [String: Any] = ["type": "response_item", "timestamp": "2026-09-04T12:00:00Z",
            "payload": ["type": "function_call", "call_id": "codex-one", "name": "exec_command", "arguments": "{}"]]
        try writeLines([codex], path: ".codex/sessions/a.jsonl", home: home)
        let engine = CallAnalyticsEngine(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:])
        let first = try await engine.refresh()
        XCTAssertEqual(first.totalCalls, 2)
        XCTAssertEqual(first.sources.first { $0.source == .claude }?.filesScanned, 1)
        XCTAssertEqual(first.sources.first { $0.source == .codex }?.filesScanned, 1)
        let unchanged = try await engine.refresh()
        XCTAssertTrue(unchanged.sources.allSatisfy { $0.filesScanned == 0 })
        XCTAssertEqual(unchanged.totalCalls, 2)
        try writeLines([claudeCall(id: "one", name: "Read"), claudeCall(id: "two", name: "Read")],
            path: ".claude/projects/p/a.jsonl", home: home)
        let changed = try await engine.refresh()
        XCTAssertEqual(changed.totalCalls, 3)
        XCTAssertEqual(changed.sources.first { $0.source == .claude }?.filesScanned, 1)
        XCTAssertEqual(changed.sources.first { $0.source == .codex }?.filesScanned, 0)
        let restarted = CallAnalyticsEngine(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:])
        let restored = try await restarted.refresh()
        XCTAssertEqual(restored.totalCalls, 3)
        XCTAssertTrue(restored.sources.allSatisfy { $0.filesScanned == 0 })
    }

    func testFailedOrUnstableScanClearsCheckpointAndPreservesSummary() throws {
        let home = try temporaryHome()
        let archive = CallAnalyticsArchiveStore(homeDirectory: home.path)
        let fresh = CallAnalyticsSnapshot(generatedAt: Date(), rangeKey: "all",
            entries: [CallAnalyticsEntry(source: .claude, kind: .builtin, name: "Read", server: nil, dayKey: "2026-09-01", count: 5)],
            installedSkills: [], installedMCPServers: [], sources: [])
        _ = try archive.merge(fresh, scannedSources: [.claude], successfulFingerprints: [.claude: "successful"])
        XCTAssertEqual(try archive.successfulFingerprint(for: .claude), "successful")
        let retained = try archive.merge(.empty, scannedSources: [.claude])
        XCTAssertEqual(retained.totalCalls, 5)
        XCTAssertNil(try archive.successfulFingerprint(for: .claude))
    }

    /// 日期桶不能在切换系统时区后重复归档；即使随后有新日志，也继续按已记录的统计时区聚合。
    func testArchiveTimeZoneSurvivesRestartWithoutDuplicatingDailyHighWater() async throws {
        let home = try temporaryHome()
        let utc = TimeZone(secondsFromGMT: 0)!
        let east = TimeZone(secondsFromGMT: 8 * 3600)!
        func call(_ id: String) -> [String: Any] {
            ["type": "assistant", "timestamp": "2026-09-04T23:30:00Z", "sessionId": "session-one",
             "message": ["content": [["type": "tool_use", "id": id, "name": "Read"]]]]
        }
        try writeLines([call("one")], path: ".claude/projects/p/a.jsonl", home: home)
        let initial = CallAnalyticsEngine(homeDirectory: home.path, timeZone: utc, environment: [:])
        let first = try await initial.refresh()
        XCTAssertEqual(first.entries.first?.dayKey, "2026-09-04")
        XCTAssertEqual(first.aggregationTimeZoneIdentifier, utc.identifier)
        let moved = CallAnalyticsEngine(homeDirectory: home.path, timeZone: east, environment: [:])
        let unchanged = try await moved.refresh()
        XCTAssertEqual(unchanged.totalCalls, 1)
        XCTAssertEqual(unchanged.aggregationTimeZoneIdentifier, utc.identifier)
        XCTAssertTrue(unchanged.sources.allSatisfy { $0.filesScanned == 0 })
        try writeLines([call("one"), call("two")], path: ".claude/projects/p/a.jsonl", home: home)
        let appended = try await moved.refresh()
        XCTAssertEqual(appended.totalCalls, 2)
        XCTAssertEqual(Set(appended.entries.map(\.dayKey)), ["2026-09-04"])
        XCTAssertEqual(appended.agentInvocations.reduce(0) { $0 + $1.count }, 1)
        XCTAssertEqual(try CallAnalyticsArchiveStore(homeDirectory: home.path).load().aggregationTimeZoneIdentifier, utc.identifier)
    }

    /// 归类配置、边车、WAL 和统计时区都是有效输入，不能只以日志文件大小判断是否可复用。
    func testFingerprintsIncludeSidecarDatabaseWALClassificationAndTimeZone() throws {
        let home = try temporaryHome()
        let file = try writeLines([["type": "assistant", "sessionId": "one", "message": ["content": "text"]]],
            path: ".claude/projects/p/subagents/agent-one.jsonl", home: home)
        let checkpoint = CallAnalyticsScanCheckpoint(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:])
        let original = try checkpoint.fingerprint(for: .claude, knownMCPServers: [])
        try Data(#"{"agentType":"Explore"}"#.utf8).write(to: file.deletingPathExtension().appendingPathExtension("meta.json"))
        XCTAssertNotEqual(try checkpoint.fingerprint(for: .claude, knownMCPServers: []), original)
        let otherZone = CallAnalyticsScanCheckpoint(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 3600)!, environment: [:])
        XCTAssertNotEqual(try checkpoint.fingerprint(for: .claude, knownMCPServers: []),
                          try otherZone.fingerprint(for: .claude, knownMCPServers: []))
        let path = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("database".utf8).write(to: path)
        let beforeWAL = try checkpoint.fingerprint(for: .opencode, knownMCPServers: [])
        try Data("new transaction".utf8).write(to: URL(fileURLWithPath: path.path + "-wal"))
        let afterWAL = try checkpoint.fingerprint(for: .opencode, knownMCPServers: [])
        XCTAssertNotEqual(beforeWAL, afterWAL)
        XCTAssertNotEqual(afterWAL, try checkpoint.fingerprint(for: .opencode, knownMCPServers: ["server_with_underscores"]))
    }

}
