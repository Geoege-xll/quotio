import XCTest
@testable import Quotio

/// 展示层只用构造的日桶，测试不触碰真实凭据、队列或用户账本。
final class UsageStatisticsPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return result
    }
    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day))!
    }
    private func bucket(_ day: Int, provider: String = "a", model: String = "shared", requests: Int = 1, tokens: Int = 10) -> UsageBucket {
        var result = UsageBucket(day: date(day), provider: provider, model: model)
        result.requests = requests; result.totalTokens = tokens
        return result
    }
    func testCustomRangeIncludesLastDayAndExcludesNextDayAcrossDaylightSaving() {
        let interval = UsageStatisticsPeriod.custom.interval(now: date(8), start: date(7), end: date(9), calendar: calendar)!
        XCTAssertEqual(interval.duration, 71 * 3600)
        let presentation = UsageStatisticsPresentation(buckets: [bucket(7), bucket(8), bucket(9), bucket(10)], interval: interval, provider: nil, model: nil)
        XCTAssertEqual(presentation.totals.requests, 3)
    }
    func testProviderAndModelFiltersIntersectWithoutMutatingSource() {
        let original = [bucket(8), bucket(8, provider: "b"), bucket(8, model: "other")]
        let presentation = UsageStatisticsPresentation(buckets: original, interval: nil, provider: "a", model: "shared")
        XCTAssertEqual(presentation.totals.requests, 1)
        XCTAssertEqual(original.count, 3)
    }
    func testSameModelFromDifferentProvidersRemainsSeparateAndRankingIsComplete() {
        let buckets = (0..<30).map { bucket(8, provider: "provider-\($0)", tokens: $0 + 1) }
        let presentation = UsageStatisticsPresentation(buckets: buckets, interval: nil, provider: nil, model: nil)
        XCTAssertEqual(presentation.models.count, 30)
        XCTAssertEqual(presentation.models.first?.totals.totalTokens, 30)
        XCTAssertEqual(Set(presentation.models.map(\.id)).count, 30)
    }
    func testDailyValuesAndSummaryUseTheSameFilteredBuckets() {
        let presentation = UsageStatisticsPresentation(buckets: [bucket(9, requests: 3), bucket(8), bucket(8, provider: "b", requests: 2)], interval: nil, provider: nil, model: nil)
        XCTAssertEqual(presentation.days.map(\.day), [date(8), date(9)])
        XCTAssertEqual(presentation.days.map(\.totals.requests), [3, 3])
        XCTAssertEqual(presentation.totals.requests, presentation.days.reduce(0) { $0 + $1.totals.requests })
    }
    func testEmptySelectionHasNoInventedSuccessRateOrLatency() {
        let presentation = UsageStatisticsPresentation(buckets: [], interval: nil, provider: nil, model: nil)
        XCTAssertNil(presentation.totals.successRate)
        XCTAssertNil(presentation.totals.averageLatencyMilliseconds)
        XCTAssertTrue(presentation.models.isEmpty)
    }
    func testLegacySummarySurvivesStoppedAndFailedCollectionWithoutFallingBackToEmptyLedger() {
        let legacy = UsageTotals(buckets: [bucket(8, requests: 8, tokens: 100)])
        // 未匹配的筛选结果故意为空，复现旧版数据被错误换成日账本零值的场景。
        let filtered = UsageStatisticsPresentation(buckets: [bucket(8)], interval: nil, provider: "missing", model: nil)
        for state: UsageCollectionState in [.legacy, .stopped, .failed] {
            let result = filtered.summary(legacyTotals: legacy, hasSavedData: true, state: state)
            XCTAssertEqual(result.totals.requests, 8)
            XCTAssertEqual(result.totals.totalTokens, 100)
            XCTAssertTrue(result.isLegacy, "停止和失败时也必须禁用旧版不支持的筛选")
            XCTAssertTrue(result.available)
        }
    }

    func testQueueSummaryUsesFilteredLedgerAndDistinguishesUnknownFromConfirmedZero() {
        let filtered = UsageStatisticsPresentation(buckets: [bucket(8, requests: 3, tokens: 40)], interval: nil, provider: nil, model: nil)
        let saved = filtered.summary(legacyTotals: nil, hasSavedData: true, state: .stopped)
        XCTAssertFalse(saved.isLegacy)
        XCTAssertTrue(saved.available)
        XCTAssertEqual(saved.totals.totalTokens, 40)
        let empty = UsageStatisticsPresentation(buckets: [], interval: nil, provider: nil, model: nil)
        XCTAssertFalse(empty.summary(legacyTotals: nil, hasSavedData: false, state: .failed).available)
        XCTAssertTrue(empty.summary(legacyTotals: nil, hasSavedData: false, state: .live).available)
    }

}
