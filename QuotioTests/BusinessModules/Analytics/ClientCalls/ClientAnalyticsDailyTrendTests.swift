import AppKit
import SwiftUI
import Charts
import XCTest
@testable import QuotioPlus

/// 日期缺口、时区、独立刻度和真实卡片交互的定向验证。
/// 全部数据为内存夹具；不扫描真实日志、不请求 CPA、不写用户筛选配置。
@MainActor
final class ClientAnalyticsDailyTrendTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    private func date(_ day: Int, month: Int = 10, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    private func tokens(_ day: Date, count: Int) -> UsageStatisticsDay {
        var bucket = UsageBucket(day: day, provider: "Claude Code", model: "fixture-model")
        bucket.totalTokens = count
        return UsageStatisticsDay(day: day, totals: UsageTotals(buckets: [bucket]))
    }

    private func fixture() -> ClientAnalyticsDailyTrendData {
        let cal = calendar()
        return ClientAnalyticsDailyTrendData(tokenDays: [tokens(date(1, calendar: cal), count: 1_000),
            tokens(date(3, calendar: cal), count: 90_000), tokens(date(4, calendar: cal), count: 12_000)],
            tokensAvailable: true, calls: [.init(day: "2026-10-01", count: 4), .init(day: "2026-10-04", count: 20)],
            toolsAvailable: true, lowerDay: "2026-10-01", upperDay: "2026-10-04",
            now: date(4, calendar: cal), calendar: cal)
    }

    func testGapsSharedDatesAndDaylightSavingPreserveFacts() throws {
        let data = fixture()
        XCTAssertEqual(data.days.count, 4)
        XCTAssertEqual(data.days.map(\.tokens), [1_000, 0, 90_000, 12_000])
        XCTAssertEqual(data.days.map(\.tools), [4, 0, 0, 20])
        XCTAssertEqual(data.days.compactMap(\.tokens).reduce(0, +), 103_000)
        XCTAssertEqual(data.days.compactMap(\.tools).reduce(0, +), 24)
        XCTAssertEqual(data.axisDates, data.days.map(\.date))
        XCTAssertEqual(data.maximum(.tokens), 90_000)
        XCTAssertEqual(data.maximum(.tools), 20, "工具纵轴不能沿用 Token 的数量级")
        let cal = calendar("America/Los_Angeles")
        let local = ClientAnalyticsDailyTrendData(tokenDays: [tokens(date(8, month: 3, calendar: cal), count: 10)],
            tokensAvailable: true, calls: [.init(day: "2026-03-08", count: 2)], toolsAvailable: true,
            lowerDay: "2026-03-07", upperDay: "2026-03-09", now: date(9, month: 3, calendar: cal), calendar: cal)
        XCTAssertEqual(local.days.count, 3)
        XCTAssertEqual(local.days[2].date.timeIntervalSince(local.days[1].date), 23 * 3600)
        XCTAssertEqual(local.days[1].tokens, 10)
        XCTAssertEqual(local.days[1].tools, 2, "同一个本地日不能因 UTC 解析而错位")
        XCTAssertEqual(local.days[1].date.timeIntervalSince(local.days[1].barStart),
                       local.days[1].barEnd.timeIntervalSince(local.days[1].date), accuracy: 0.001,
            "夏令时两侧日长不同时，柱体仍必须以同日折线的零点为中心")
    }

    func testUnknownSingleDayAndHoverReadFullUnsampledHistory() throws {
        let cal = calendar()
        let one = ClientAnalyticsDailyTrendData(tokenDays: [], tokensAvailable: false,
            calls: [.init(day: "2026-10-14", count: 2)], toolsAvailable: true,
            lowerDay: "2026-10-14", upperDay: "2026-10-14", now: date(14, calendar: cal), calendar: cal)
        XCTAssertEqual(one.days.count, 1)
        XCTAssertNil(one.days[0].tokens)
        XCTAssertEqual(one.days[0].tools, 2)
        XCTAssertLessThan(one.domain.lowerBound, one.days[0].barStart)
        XCTAssertGreaterThan(one.domain.upperBound, one.days[0].barEnd)
        let start = date(1, calendar: cal)
        let history = (0..<1_000).map { tokens(cal.date(byAdding: .day, value: $0, to: start)!, count: $0 + 1) }
        let data = ClientAnalyticsDailyTrendData(tokenDays: history, tokensAvailable: true,
            calls: [], toolsAvailable: false, lowerDay: nil, upperDay: nil, now: start, calendar: cal)
        XCTAssertTrue(data.spansYears, "跨年历史的日期轴需要显示年份")
        let sampled = data.plottedDays(.tokens)
        XCTAssertLessThanOrEqual(sampled.count, 240)
        let omitted = try XCTUnwrap(data.days.first { day in !sampled.contains { $0.date == day.date } })
        XCTAssertEqual(data.nearest(to: omitted.date.addingTimeInterval(600)), omitted,
            "悬停必须返回未抽样日的真实数值，不能跳到邻近的已绘制点")
        XCTAssertNil(data.nearest(to: omitted.date)?.tools)
    }
}
