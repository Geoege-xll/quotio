import SwiftUI
import XCTest
@testable import QuotioPlus

/// 本轮只验证去 Token 化后的工具调用概览契约及可用性语义。夹具全部在内存中，
/// 不启动 CPA、不读取真实客户端日志，也不写入用户的账号和设置。
@MainActor
final class ClientAnalyticsOverviewTests: XCTestCase {
    private func calls(available: Bool = true, failed: Bool = false, populated: Bool = true) -> CallReplicaDerived {
        let entries: [CallAnalyticsEntry] = populated ? [
            CallAnalyticsEntry(source: .claude, kind: .mcp, name: "fixture/search", server: "fixture", dayKey: "2026-10-14", count: 1_082),
            CallAnalyticsEntry(source: .claude, kind: .skill, name: "review", server: nil, dayKey: "2026-10-14", count: 9_409),
            CallAnalyticsEntry(source: .claude, kind: .builtin, name: "Read", server: nil, dayKey: "2026-10-14", count: 326_930)
        ] : []
        let snapshot = CallAnalyticsSnapshot(generatedAt: Date(), rangeKey: "all", entries: entries,
            installedSkills: [InstalledItem(source: .claude, name: "review")], installedMCPServers: [],
            sources: [CallSourceStatus(source: .claude, available: available, eventCount: entries.count,
                filesScanned: 1, errorCode: failed ? "read_failed" : nil)])
        let report = CallAnalyticsReport(snapshot: snapshot, lowerDay: nil, upperDay: nil, source: nil, kind: nil)
        return CallReplicaDerived(report: report, snapshot: snapshot, source: nil)
    }

    func testIndependentAvailabilityPreservesUnknownAndConfirmedZero() throws {
        let overview = ClientAnalyticsOverview(calls: calls())
        let values = Dictionary(uniqueKeysWithValues: overview.metrics.map { ($0.id, $0) })
        XCTAssertEqual(values.count, 4, "客户端调用概览保留四项工具调用指标，已移除未调用技能数与本地 Token")
        XCTAssertTrue(values.keys.allSatisfy { $0.hasPrefix("callReplica.") })
        XCTAssertNil(values["callReplica.unusedSkills"], "未调用技能标签已按要求从概览中移除")
        XCTAssertEqual(values["callReplica.total"]?.number, 337_421)
        XCTAssertEqual(values["callReplica.mcpCalls"]?.number, 1_082)
        XCTAssertEqual(values["callReplica.skillCalls"]?.number, 9_409)
        XCTAssertEqual(values["callReplica.activeMCP"]?.number, 1)

        let missing = ClientAnalyticsOverview(calls: calls(available: false, populated: false))
        XCTAssertTrue(missing.metrics.allSatisfy { $0.number == nil && $0.value == "—" },
            "调用来源未读到时不能把未知显示成零")

        let emptySuccess = ClientAnalyticsOverview(calls: calls(populated: false))
        XCTAssertTrue(emptySuccess.metrics.allSatisfy { $0.number == 0 },
            "来源成功读取且没有事件时仍应显示确切的零调用")
    }
}
