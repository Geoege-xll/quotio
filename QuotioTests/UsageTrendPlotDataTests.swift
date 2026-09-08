import XCTest
@testable import Quotio

/// 绘图抽样不能改变原始统计，也不能漏掉峰值、首尾日期或返回虚构的悬停读数。
final class UsageTrendPlotDataTests: XCTestCase {
    private func days(_ values: [Int]) -> [UsageStatisticsDay] {
        values.enumerated().map { index, tokens in
            var bucket = UsageBucket(day: Date(timeIntervalSince1970: Double(index * 86_400)), provider: "Codex", model: "m")
            bucket.totalTokens = tokens
            return UsageStatisticsDay(day: bucket.day, totals: UsageTotals(buckets: [bucket]))
        }
    }

    func testLongHistoryIsBoundedAndPreservesExtremesAndOrder() {
        var values = Array(repeating: 1_000, count: 10_000)
        values[5_031] = 90_000_000
        values[5_032] = 0
        let original = days(values)
        let sampled = UsageTrendPlotData.sampled(original)
        XCTAssertLessThanOrEqual(sampled.count, 240)
        XCTAssertEqual(sampled.first, original.first)
        XCTAssertEqual(sampled.last, original.last)
        XCTAssertTrue(sampled.contains(original[5_031]))
        XCTAssertTrue(sampled.contains(original[5_032]))
        XCTAssertEqual(sampled.map(\.day), sampled.map(\.day).sorted())
        XCTAssertEqual(Set(sampled.map(\.day)).count, sampled.count)
        XCTAssertEqual(original.count, 10_000)
        XCTAssertTrue(sampled.allSatisfy { original.contains($0) })
    }

    func testSmallAndFlatHistoriesKeepRealValuesWithoutDuplicateDates() {
        XCTAssertTrue(UsageTrendPlotData.sampled([]).isEmpty)
        for count in [1, 2, 31, 240] {
            let original = days(Array(repeating: 0, count: count))
            XCTAssertEqual(UsageTrendPlotData.sampled(original), original)
        }
        let sampled = UsageTrendPlotData.sampled(days(Array(repeating: 7, count: 1_000)), maximumPoints: 64)
        XCTAssertLessThanOrEqual(sampled.count, 64)
        XCTAssertEqual(Set(sampled.map(\.day)).count, sampled.count)
        XCTAssertTrue(sampled.allSatisfy { $0.totals.totalTokens == 7 })
    }

    func testHoverReadsCompleteHistoryIncludingUnsampledDays() throws {
        let original = days((0..<1_000).map { $0 })
        let sampledDates = Set(UsageTrendPlotData.sampled(original).map(\.day))
        let omitted = try XCTUnwrap(original.first { !sampledDates.contains($0.day) })
        XCTAssertEqual(UsageTrendPlotData.nearest(to: omitted.day, in: original), omitted)
        XCTAssertEqual(UsageTrendPlotData.nearest(to: omitted.day.addingTimeInterval(1_000), in: original), omitted)
        XCTAssertEqual(UsageTrendPlotData.nearest(to: .distantPast, in: original), original.first)
        XCTAssertEqual(UsageTrendPlotData.nearest(to: .distantFuture, in: original), original.last)
        XCTAssertNil(UsageTrendPlotData.nearest(to: Date(), in: []))
    }
}
