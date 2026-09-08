import XCTest
@testable import Quotio

/// 使用有序合成数据验证分页边界，防止漏行、重复行或把顶部汇总的来源截成当前页。
final class CPAUsageTablePageTests: XCTestCase {
    func testFortyFiveRowsHaveThreeBoundedPagesWithoutChangingSource() {
        let source = Array(0..<45)
        let pages = (1...3).map { CPAUsageTablePage(totalCount: source.count, number: $0).rows(from: source) }
        XCTAssertEqual(pages.map(\.count), [20, 20, 5])
        XCTAssertEqual(pages.flatMap { $0 }, source)
        XCTAssertEqual(source.count, 45)
    }

    func testEmptyExactAndPartialPagesClampRequestedNumber() {
        for (count, expectedPages) in [(0, 1), (20, 1), (21, 2), (40, 2)] {
            XCTAssertEqual(CPAUsageTablePage(totalCount: count, number: 999).number, expectedPages)
            XCTAssertEqual(CPAUsageTablePage(totalCount: count, number: -1).number, 1)
        }
        XCTAssertEqual(CPAUsageTablePage(totalCount: -10, number: 0).totalCount, 0)
        XCTAssertTrue(CPAUsageTablePage(totalCount: 0, number: 1).rows(from: [Int]()).isEmpty)
    }

    func testVeryLargeCountsAndShortenedSourceRemainSafe() {
        let page = CPAUsageTablePage(totalCount: Int.max, number: Int.max)
        XCTAssertEqual(page.totalPages, Int.max / 20 + 1)
        XCTAssertTrue(page.rows(from: [1, 2]).isEmpty)
        XCTAssertEqual(CPAUsageTablePage(totalCount: 45, number: 3).rows(from: Array(0..<42)), [40, 41])
    }
}
