import XCTest
@testable import Quotio

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
    private func bucket(_ day: Int, provider: String = "a", tokens: Int) -> UsageBucket {
        var bucket = UsageBucket(day: date(day), provider: provider, model: "model")
        bucket.totalTokens = tokens
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
}
