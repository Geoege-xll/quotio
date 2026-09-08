// 验证 AIUsage 页面复刻的统计派生：只使用内存 fixture，不读取真实会话或修改用户配置。
import XCTest
@testable import Quotio

final class CallAnalyticsReplicaTests: XCTestCase {
    private func entry(_ name: String, source: CallSourceKind = .claude, kind: CallKind = .mcp,
                       server: String? = "demo", count: Int = 1, known: Int = 0, success: Int = 0,
                       agent: String? = nil, day: String = "2026-09-04") -> CallAnalyticsEntry {
        CallAnalyticsEntry(source: source, kind: kind, name: name, server: server, agent: agent, dayKey: day,
            count: count, outcomeKnownCount: known, successCount: success)
    }

    /// 构造三个来源都存在的摘要；失败集合用于验证不可读来源不能被推断为零调用。
    private func derived(entries: [CallAnalyticsEntry], source: CallSourceKind? = nil, lower: String? = nil,
                         skills: [InstalledItem] = [], failures: Set<CallSourceKind> = [],
                         invocations: [AgentInvocationCount] = [], upper: String? = nil) -> CallReplicaDerived {
        let snapshot = CallAnalyticsSnapshot(generatedAt: Date(), rangeKey: "all", entries: entries, installedSkills: skills,
            installedMCPServers: [], agentInvocations: invocations, sources: CallSourceKind.allCases.map {
                CallSourceStatus(source: $0, available: true, eventCount: 0, filesScanned: 1,
                    errorCode: failures.contains($0) ? "read_failed" : nil)
            })
        let report = CallAnalyticsReport(snapshot: snapshot, lowerDay: lower, upperDay: upper, source: source, kind: nil)
        return CallReplicaDerived(report: report, snapshot: snapshot, source: source)
    }

    func testMCPServerRankingMergesSourcesAndDrillsDownWithoutDoubleCount() throws {
        let value = derived(entries: [entry("demo/search", count: 2, known: 2, success: 1),
            entry("demo/search", source: .codex, count: 3), entry("demo/read", count: 4)])
        let server = try XCTUnwrap(value.ranking(.mcp).first)
        XCTAssertEqual(server.name, "demo")
        XCTAssertEqual(server.count, 9)
        XCTAssertEqual(server.sources, [.claude, .codex])
        // 只有两条记录提供结果，成功率必须是 1/2，不能用全部九次调用作为分母。
        XCTAssertEqual(server.successRate, 0.5)
        XCTAssertNil(server.duration)
        XCTAssertTrue(server.drillable)
        let tools = value.tools(server: "demo")
        XCTAssertEqual(tools.map(\.name), ["search", "read"])
        XCTAssertEqual(tools.map(\.count), [5, 4])
        XCTAssertEqual(tools.reduce(0) { $0 + $1.count }, server.count)
    }

    func testLensOnlyChangesRankingAndPreservesKPIAndTrend() {
        let value = derived(entries: [entry("demo/search", count: 3),
            entry("review", kind: .skill, server: nil, count: 2),
            entry("Read", kind: .builtin, server: nil, count: 7)])
        XCTAssertEqual(value.ranking(.mcp).count, 1)
        XCTAssertEqual(value.ranking(.skill).map(\.name), ["review"])
        XCTAssertEqual(value.ranking(.tools).map(\.name), ["Read"])
        XCTAssertEqual(value.report.totalCalls, 12)
        XCTAssertEqual(value.report.trend.first?.count, 12)
        XCTAssertEqual(value.mcpCalls, 3)
        XCTAssertEqual(value.skillCalls, 2)
    }

    func testInventoryAllScopeMergesSameNameAndExcludesFailedSourceZeroConclusions() {
        let value = derived(entries: [entry("review", source: .codex, kind: .skill, server: nil, count: 2)],
            skills: [InstalledItem(source: .claude, name: "review"), InstalledItem(source: .codex, name: "review"),
                InstalledItem(source: .claude, name: "failed-only"), InstalledItem(source: .codex, name: "unused")],
            failures: [.claude])
        let rows = value.inventory(kind: .skill)
        XCTAssertEqual(rows.map(\.name), ["review", "unused"])
        XCTAssertEqual(rows.first?.count, 2)
        XCTAssertEqual(value.unusedSkills, 1)
        XCTAssertTrue(value.report.hasReadFailures)
    }

    /// 会话次数来自独立日桶；即使工具量很大，也不能把工具次数当成会话启动次数。
    func testAgentBreakdownUsesSessionCountsWithinInclusiveDateRange() {
        let counts = [AgentInvocationCount(source: .claude, agent: "main", count: 2, dayKey: "2026-09-04"),
            AgentInvocationCount(source: .claude, agent: "Explore", count: 1, dayKey: "2026-09-04"),
            AgentInvocationCount(source: .claude, agent: "OldAgent", count: 50, dayKey: "2026-09-03"),
            AgentInvocationCount(source: .claude, agent: "FutureAgent", count: 10, dayKey: "2026-09-05")]
        let value = derived(entries: [entry("Read", kind: .builtin, count: 999, agent: "Explore")],
            lower: "2026-09-04", invocations: counts, upper: "2026-09-04")
        XCTAssertEqual(value.agents.map(\.id), ["main", "Explore"])
        XCTAssertEqual(value.agents.map(\.count), [2, 1])
        XCTAssertEqual(value.report.totalCalls, 999)
        XCTAssertTrue(derived(entries: [], source: .codex, invocations: counts).agents.isEmpty)
    }

    func testPureTextSubagentAppearsWithoutAnyToolEvents() {
        let value = derived(entries: [], invocations: [
            AgentInvocationCount(source: .claude, agent: "Explore", count: 1, dayKey: "2026-09-04")])
        XCTAssertEqual(value.agents.map(\.id), ["Explore"])
        XCTAssertEqual(value.agents.map(\.count), [1])
        XCTAssertEqual(value.report.totalCalls, 0)
    }

    /// 旧账本的未知日期仅保留在全部范围，不能凭扫描日期声称本日启动过。
    func testUndatedLegacySessionsOnlyAppearInAllRange() {
        let counts = [AgentInvocationCount(source: .claude, agent: "Explore", count: 3)]
        let all = derived(entries: [], invocations: counts)
        XCTAssertEqual(all.agents.first?.count, 3)
        XCTAssertTrue(all.report.hasUndatedAgentInvocations)
        XCTAssertTrue(derived(entries: [], lower: "2026-09-04", invocations: counts).agents.isEmpty)
        XCTAssertTrue(derived(entries: [], invocations: counts, upper: "2026-09-04").agents.isEmpty)
        XCTAssertFalse(derived(entries: [], source: .codex, invocations: counts).report.hasUndatedAgentInvocations)
    }

    func testWeekAlwaysBeginsMondayEvenWhenLocaleStartsSunday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 1
        let sunday = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-06T12:00:00Z"))
        let bounds = CallAnalyticsDateRange.week.bounds(now: sunday, start: sunday, end: sunday, calendar: calendar)
        XCTAssertEqual(bounds.0, "2026-08-31")
        XCTAssertEqual(bounds.1, "2026-09-06")
    }
}
