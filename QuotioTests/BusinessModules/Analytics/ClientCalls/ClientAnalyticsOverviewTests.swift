import SwiftUI
import XCTest
@testable import QuotioPlus

/// 本轮只验证融合概览的可用性契约及真实布局。夹具全部在内存中，
/// 不启动 CPA、不读取真实客户端日志，也不写入用户的账号和设置。
@MainActor
final class ClientAnalyticsOverviewTests: XCTestCase {
    private func client(available: Bool = true, lacksReasoning: Bool = false) -> ClientUsageViewModel.Presentation {
        var bucket = UsageBucket(day: Calendar.current.startOfDay(for: Date()), provider: "Claude Code", model: "fixture-model")
        bucket.inputTokens = 150_700_000_000
        bucket.outputTokens = 489_000_000
        bucket.cachedTokens = 145_800_000_000
        bucket.reasoningTokens = 145_000_000
        bucket.totalTokens = bucket.inputTokens + bucket.outputTokens
        return .init(statistics: UsageStatisticsPresentation(buckets: [bucket], interval: nil, provider: nil, model: nil),
                     available: available, lacksReasoning: lacksReasoning)
    }

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
        let overview = ClientAnalyticsOverview(client: client(), calls: calls())
        let values = Dictionary(uniqueKeysWithValues: overview.metrics.map { ($0.id, $0) })
        XCTAssertEqual(values.count, 11, "六项 Token 与模型指标、五项调用指标应同时可见")
        XCTAssertEqual(values["usage.tokens"]?.number, 151_189_000_000)
        XCTAssertEqual(values["usage.cachedTokens"]?.number, 145_800_000_000,
            "融合展示不能把缓存额外加到总 Token 上")
        XCTAssertEqual(values["callReplica.total"]?.number, 337_421)
        XCTAssertEqual(values["callReplica.unusedSkills"]?.number, 0)
        let missing = ClientAnalyticsOverview(client: client(lacksReasoning: true),
                                             calls: calls(available: false, populated: false))
        XCTAssertEqual(missing.metrics.first { $0.id == "usage.reasoningTokens" }?.value, "—")
        XCTAssertEqual(missing.metrics.first { $0.id == "usage.tokens" }?.number, 151_189_000_000)
        XCTAssertTrue(missing.metrics.filter { $0.id.hasPrefix("callReplica.") }.allSatisfy { $0.number == nil },
            "调用来源未读到时不能把未知显示成零，也不能影响可用的 Token")
        let tokensMissing = ClientAnalyticsOverview(client: client(available: false), calls: calls(populated: false))
        XCTAssertTrue(tokensMissing.metrics.filter { $0.id.hasPrefix("usage.") }.allSatisfy { $0.number == nil })
        XCTAssertTrue(tokensMissing.metrics.filter { $0.id.hasPrefix("callReplica.") && $0.id != "callReplica.unusedSkills" }
            .allSatisfy { $0.number == 0 },
            "来源成功读取且没有事件时仍应显示确切的零调用")
        XCTAssertEqual(tokensMissing.metrics.first { $0.id == "callReplica.unusedSkills" }?.number, 1,
            "夹具已安装一个技能且没有调用；未调用数应为一，不能随调用总数清零")
        let partial = ClientAnalyticsOverview(client: client(), calls: calls(failed: true))
        XCTAssertNil(partial.metrics.first { $0.id == "callReplica.unusedSkills" }?.number,
            "部分读取失败时不能声称未调用清单已经完整")
    }

}
