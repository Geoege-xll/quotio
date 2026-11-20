import XCTest
@testable import QuotioPlus

/// 固定日历测试网格和筛选规则，不接触真实账本或网络；特意使用周日开周地区复现边界差异。
final class UsageHeatmapPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 1
        return calendar
    }
    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day))!
    }
    private func bucket(_ day: Int, provider: String = "a", model: String = "model",
                        tokens: Int, requests: Int = 1) -> UsageBucket {
        var bucket = UsageBucket(day: date(day), provider: provider, model: model)
        bucket.totalTokens = tokens
        bucket.requests = requests
        return bucket
    }
    func testWeekStartsOnMondayEvenWhenLocaleStartsOnSunday() {
        let interval = UsageStatisticsPeriod.week.interval(now: date(8), start: date(8), end: date(8), calendar: calendar)!
        XCTAssertEqual(interval.start, date(2))
        XCTAssertEqual(interval.end, date(9))
        XCTAssertEqual(interval.duration, 167 * 3600, "跨夏令时仍以日历周为准")
    }
    func testHeatmapHas52MondayWeeksWithoutDuplicateDaysAcrossDST() {
        let presentation = UsageHeatmapPresentation(buckets: [], now: date(10), firstCollectedAt: date(8), calendar: calendar)
        XCTAssertEqual(presentation.weeks.count, 52)
        let days = presentation.weeks.flatMap(\.days)
        XCTAssertEqual(days.count, 364)
        XCTAssertEqual(Set(days.map(\.date)).count, 364)
        XCTAssertTrue(presentation.weeks.allSatisfy { calendar.component(.weekday, from: $0.days[0].date) == 2 })
        XCTAssertEqual(days.filter(\.isFuture).count, 5)
        XCTAssertTrue(days.first!.isBeforeCollection)
    }
    func testHeatmapTotalsExcludeFutureAndKeepAllProviderModelValues() {
        let buckets = [bucket(8, tokens: 10), bucket(8, provider: "b", tokens: 20), bucket(9, tokens: 40), bucket(11, tokens: 900)]
        let presentation = UsageHeatmapPresentation(buckets: buckets, now: date(10), firstCollectedAt: date(8), calendar: calendar)
        XCTAssertEqual(presentation.totals.totalTokens, 70)
        XCTAssertEqual(presentation.activeDays, 2)
        XCTAssertEqual(presentation.peak?.totals.totalTokens, 40)
        let day = presentation.weeks.flatMap(\.days).first { $0.date == date(8) }!
        XCTAssertEqual(day.models.count, 2)
        XCTAssertEqual(day.totals.totalTokens, 30)
        XCTAssertFalse(day.isBeforeCollection)
        XCTAssertEqual(presentation.intensity(0), 0)
        XCTAssertEqual(presentation.intensity(40), 4)
    }
    func testSourceFilteringDoesNotDependOnPeriodUsedBySummary() {
        let buckets = [bucket(2, tokens: 10), bucket(9, tokens: 20), bucket(9, provider: "b", tokens: 30)]
        let interval = UsageStatisticsPeriod.today.interval(now: date(9), start: date(9), end: date(9), calendar: calendar)
        let summary = UsageStatisticsPresentation(buckets: buckets, interval: interval, provider: "a", model: nil)
        let history = UsageStatisticsPresentation(buckets: buckets, interval: nil, provider: "a", model: nil)
        XCTAssertEqual(summary.totals.totalTokens, 20)
        XCTAssertEqual(history.totals.totalTokens, 30, "热力图保留来源全年数据，不被今日筛选裁掉")
    }

    func testRequestsMetricUsesRequestCountsThresholdsPeakAndModelSorting() {
        let buckets = [
            bucket(8, provider: "a", model: "low-req-high-tok", tokens: 9_000, requests: 2),
            bucket(8, provider: "b", model: "high-req-low-tok", tokens: 100, requests: 25),
            bucket(9, provider: "a", model: "zero-tok-active-req", tokens: 0, requests: 50)
        ]
        let requestsView = UsageHeatmapPresentation(
            buckets: buckets,
            now: date(10),
            firstCollectedAt: date(8),
            metric: .requests,
            calendar: calendar
        )
        XCTAssertEqual(requestsView.totals.requests, 77)
        XCTAssertEqual(requestsView.activeDays, 2, "0 Token 但有请求的日子在请求口径下仍算作活跃日")
        XCTAssertEqual(requestsView.peak?.date, date(9))
        XCTAssertEqual(requestsView.peak?.totals.requests, 50)
        XCTAssertEqual(requestsView.intensity(0), 0)
        XCTAssertEqual(requestsView.intensity(50), 4)

        let day8 = requestsView.weeks.flatMap(\.days).first { $0.date == date(8) }!
        XCTAssertEqual(day8.models.map(\.model), ["high-req-low-tok", "low-req-high-tok"],
                       "请求口径下当日模型列表应按请求数降序排列")

        let tokensView = UsageHeatmapPresentation(
            buckets: buckets,
            now: date(10),
            firstCollectedAt: date(8),
            metric: .tokens,
            calendar: calendar
        )
        XCTAssertEqual(tokensView.activeDays, 1, "Token 口径下 0 Token 日不计入活跃日")
        XCTAssertEqual(tokensView.peak?.date, date(8))
        let tokenDay8 = tokensView.weeks.flatMap(\.days).first { $0.date == date(8) }!
        XCTAssertEqual(tokenDay8.models.map(\.model), ["low-req-high-tok", "high-req-low-tok"])
    }

    func testReversedPartialWindowMarksBothMidnightDaysWithoutClippingBuckets() {
        let selection = CPAUsageSelection(range: .custom, start: date(9), end: date(8).addingTimeInterval(3600))
        let query = selection.query(now: date(10), page: 1, pageSize: 1)
        let wholeDay = bucket(8, tokens: 200)
        let previous = bucket(7, tokens: 100)
        let presentation = UsageHeatmapPresentation(buckets: [wholeDay, previous], now: date(10), firstCollectedAt: date(7),
            metric: .cost, calendar: calendar, costs: [wholeDay.id: .init(amount: 0.25, isPartial: true), previous.id: .init(amount: 0)],
            selectedStart: query.start, selectedEnd: query.end)
        let days = presentation.weeks.flatMap(\.days)
        XCTAssertEqual(days.count, 364)
        XCTAssertEqual(days.filter(\.isInSelection).map(\.date), [date(8), date(9)], "精确端点包含次日午夜")
        XCTAssertEqual(days.first { $0.date == date(8) }?.totals.totalTokens, 200)
        XCTAssertEqual(presentation.peak?.cost, .init(amount: 0.25, isPartial: true))
        XCTAssertEqual(presentation.cost, .init(amount: 0.25, isPartial: true))
        XCTAssertEqual(presentation.activeDays, 1, "显式零不是未知，也不制造活跃天")

        let all = UsageHeatmapPresentation(buckets: [wholeDay], now: date(10), firstCollectedAt: date(7), calendar: calendar)
        XCTAssertFalse(all.hasSelection)
        XCTAssertTrue(all.weeks.flatMap(\.days).allSatisfy(\.isInSelection))
    }

}
