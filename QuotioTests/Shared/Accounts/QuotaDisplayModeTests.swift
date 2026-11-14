import XCTest
@testable import QuotioPlus

/// Regression tests for issue #219: a "no data" sentinel of -1 remaining percent
/// must never be converted into a fake display value (100 - (-1) = 101%).
@MainActor
final class QuotaDisplayModeTests: XCTestCase {
    // MARK: - No-data sentinel propagation

    /// The exact defect from issue #219: an unfetched quota item carries
    /// remaining = -1, and "used" mode displayed 100 - (-1) = 101%.
    func testUsedModePropagatesNoDataSentinelInsteadOf101() {
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: -1), -1)
    }

    func testRemainingModePropagatesNoDataSentinel() {
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: -1), -1)
    }

    func testAnyNegativeInputIsTreatedAsNoData() {
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: -0.5), -1)
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: -100), -1)
    }

    // MARK: - Valid values are unchanged

    func testUsedModeConvertsRemainingToUsed() {
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: 100), 0)
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: 70), 30)
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: 0), 100)
    }

    func testRemainingModePassesValueThrough() {
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: 100), 100)
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: 25), 25)
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: 0), 0)
    }

    // MARK: - Out-of-range values are clamped at the display boundary

    func testOverOneHundredRemainingIsClamped() {
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: 150), 0)
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: 150), 100)
    }

    // MARK: - Toward-zero rounding truncation

    /// 验证向零取整截断（.towardZero）：已用与剩余百分比之和始终精确等于 100
    func testTowardZeroTruncationPreservesComplement() {
        let remainingInput = 65.8
        let remaining = QuotaDisplayMode.remaining.displayValue(from: remainingInput)
        let used = QuotaDisplayMode.used.displayValue(from: remainingInput)

        XCTAssertEqual(remaining, 65.0)
        XCTAssertEqual(used, 35.0)
        XCTAssertEqual(remaining + used, 100.0)

        // 极限边界小数
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: 99.9), 99.0)
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: 99.9), 1.0)
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: 0.9), 0.0)
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: 0.9), 100.0)
    }
}
