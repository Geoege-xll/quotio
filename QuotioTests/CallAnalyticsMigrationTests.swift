// 使用隔离临时目录验证日志格式、日摘要与权限；禁止接触开发机真实会话和配置。
import XCTest
import SQLite3
@testable import Quotio

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
