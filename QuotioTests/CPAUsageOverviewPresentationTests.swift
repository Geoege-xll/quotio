import XCTest
@testable import Quotio

/// 覆盖常显指标的统计口径，不通过截图文字或视图层级断言复制布局实现。
final class CPAUsageOverviewPresentationTests: XCTestCase {
    private func completeMetrics() -> CPAUsageEventMetrics {
        var metrics = CPAUsageEventMetrics()
        metrics.requests = 10; metrics.successes = 7; metrics.failures = 2; metrics.canceled = 1
        metrics.input = 15_000; metrics.output = 4_500; metrics.reasoning = 500; metrics.tokens = 20_000
        metrics.cacheRead = 8_000; metrics.cacheReadSamples = 10
        metrics.cacheWrite = 1_000; metrics.cacheWriteSamples = 10
        metrics.latencyTotal = 12_000; metrics.latencySamples = 8
        metrics.ttftTotal = 6_000; metrics.ttftSamples = 6
        metrics.generationTokens = 300; metrics.generationMilliseconds = 2_000; metrics.generationSamples = 3
        metrics.minutes = 2
        return metrics
    }

    private func secondary(_ presentation: CPAUsageOverviewPresentation) -> [CPAUsageOverviewPresentation.Metric] {
        presentation.tokenAndCache + presentation.performance + presentation.requestOutcomes
    }

    private func metric(_ key: String, in presentation: CPAUsageOverviewPresentation) throws -> CPAUsageOverviewPresentation.Metric {
        try XCTUnwrap(secondary(presentation).first { $0.id == key })
    }

    func testAllThirteenSecondaryMetricsAppearExactlyOnceWithoutRepeatingPrimaryMetrics() {
        let presentation = CPAUsageOverviewPresentation(metrics: completeMetrics(), isIncomplete: false)
        let expected: Set<String> = [
            "usage.inputTokens", "usage.outputTokens", "usage.reasoningTokens",
            "usage.records.cacheRead", "usage.records.cacheWrite", "usage.records.cacheRate",
            "usage.records.ttft", "usage.records.tps", "usage.records.rpm", "usage.records.tpm",
            "usage.records.outcome.success", "usage.records.outcome.failed", "usage.records.outcome.canceled"
        ]
        let details = secondary(presentation)
        XCTAssertEqual(details.count, 13)
        XCTAssertEqual(Set(details.map(\.id)), expected)
        XCTAssertEqual(presentation.tokenAndCache.count, 6)
        XCTAssertEqual(presentation.performance.count, 4)
        XCTAssertEqual(presentation.requestOutcomes.count, 3)
        let main = [presentation.requests, presentation.tokens, presentation.successRate, presentation.latency]
        XCTAssertTrue(Set(main.map(\.id)).isDisjoint(with: expected))
    }

    func testCompleteStatisticsKeepCancellationAndIndependentSampleDenominators() throws {
        let metrics = completeMetrics()
        let presentation = CPAUsageOverviewPresentation(metrics: metrics, isIncomplete: false)
        XCTAssertEqual(presentation.requests.value, "10")
        XCTAssertEqual(presentation.tokens.exactValue, metrics.tokens.formatted())
        XCTAssertEqual(presentation.successRate.value, "77.8%", "取消请求不应进入成功率分母")
        XCTAssertEqual(presentation.latency.value, "1500.0 ms")
        XCTAssertEqual(try metric("usage.records.ttft", in: presentation).value, "1000.0 ms")
        XCTAssertEqual(try metric("usage.records.tps", in: presentation).value, "150.0 t/s")
        XCTAssertEqual(try metric("usage.records.rpm", in: presentation).value, "5.0")
        XCTAssertEqual(try metric("usage.records.tpm", in: presentation).value, "10000.0")
        XCTAssertEqual(try metric("usage.records.cacheRate", in: presentation).value, "53.3%")
        XCTAssertEqual(try metric("usage.records.outcome.canceled", in: presentation).value, "1")
    }

    func testIncompleteCoverageUsesLowerBoundsForCountsButNotForRatiosOrMeans() throws {
        let metrics = completeMetrics()
        let presentation = CPAUsageOverviewPresentation(metrics: metrics, isIncomplete: true)
        XCTAssertEqual(presentation.requests.value, "≥ 10")
        XCTAssertEqual(presentation.tokens.exactValue, "≥ " + metrics.tokens.formatted())
        XCTAssertEqual(presentation.successRate.value, "—")
        for key in ["usage.inputTokens", "usage.outputTokens", "usage.reasoningTokens", "usage.records.cacheRead",
                    "usage.records.cacheWrite", "usage.records.outcome.success", "usage.records.outcome.failed", "usage.records.outcome.canceled"] {
            let item = try metric(key, in: presentation)
            XCTAssertTrue(item.value.hasPrefix("≥ "), key)
            XCTAssertTrue(item.exactValue.hasPrefix("≥ "), key)
        }
        for key in ["usage.records.cacheRate", "usage.records.rpm", "usage.records.tpm"] {
            XCTAssertEqual(try metric(key, in: presentation).value, "—", key)
        }
        XCTAssertEqual(presentation.latency.value, "1500.0 ms", "有报告样本的平均值仍可显示，不能加下界标记")
        XCTAssertEqual(try metric("usage.records.ttft", in: presentation).value, "1000.0 ms")
        XCTAssertEqual(try metric("usage.records.tps", in: presentation).value, "150.0 t/s")
    }

    func testIncompleteZeroCannotBecomeAnExactZeroOrInventCacheCoverage() {
        let presentation = CPAUsageOverviewPresentation(metrics: CPAUsageEventMetrics(), isIncomplete: true)
        XCTAssertEqual(presentation.requests.value, "—")
        XCTAssertEqual(presentation.tokens.value, "—")
        XCTAssertTrue(secondary(presentation).allSatisfy { $0.value == "—" && $0.exactValue == "—" })
    }

    func testHistoricalUnknownFailuresAndCacheSplitsRemainUnavailable() throws {
        var metrics = completeMetrics()
        metrics.failures = 0; metrics.canceled = 0; metrics.unclassifiedFailures = 3
        metrics.cacheReadSamples = 7; metrics.cacheWriteSamples = 8
        let presentation = CPAUsageOverviewPresentation(metrics: metrics, isIncomplete: false)
        XCTAssertEqual(presentation.successRate.value, "—")
        XCTAssertEqual(try metric("usage.records.outcome.success", in: presentation).value, "7")
        for key in ["usage.records.outcome.failed", "usage.records.outcome.canceled", "usage.records.cacheRead",
                    "usage.records.cacheWrite", "usage.records.cacheRate"] {
            XCTAssertEqual(try metric(key, in: presentation).value, "—", key)
        }
    }

    func testKnownEmptyRangePreservesTrueZeroWhileMissingSignalsStayUnavailable() throws {
        let presentation = CPAUsageOverviewPresentation(metrics: CPAUsageEventMetrics(), isIncomplete: false)
        XCTAssertEqual(presentation.requests.value, "0")
        XCTAssertEqual(presentation.tokens.value, "0")
        XCTAssertEqual(try metric("usage.records.outcome.success", in: presentation).value, "0")
        XCTAssertEqual(try metric("usage.records.outcome.failed", in: presentation).value, "0")
        XCTAssertEqual(try metric("usage.records.outcome.canceled", in: presentation).value, "0")
        XCTAssertEqual(try metric("usage.records.cacheRead", in: presentation).value, "—")
        XCTAssertEqual(try metric("usage.records.cacheWrite", in: presentation).value, "—")
        XCTAssertEqual(presentation.latency.value, "—")
    }
}
