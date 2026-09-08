import XCTest
@testable import Quotio

final class QuotaPercentagePresentationTests: XCTestCase {
    /// 同一个未知额度切换已用/剩余模式后都不能变成真实的 0% 或 100%。
    func testUnknownValuesKeepPlaceholderInBothModes() {
        for value in [-1.0, Double.nan, Double.infinity, -Double.infinity] {
            for showUsed in [false, true] {
                XCTAssertNil(QuotaPercentagePresentation.displayValue(value, showUsed: showUsed))
                XCTAssertEqual(QuotaPercentagePresentation.text(value, showUsed: showUsed), "—")
            }
        }
        XCTAssertEqual(QuotaPercentagePresentation.text(0), "0%")
        XCTAssertEqual(QuotaPercentagePresentation.text(0, showUsed: true), "100%")
    }

    /// 对应 Codex session 有数据、weekly 缺失的实际响应，未知周期不得成为主条。
    func testUnknownWindowSortsAfterKnownQuota() {
        let models = [
            ModelQuota(name: "codex-weekly", percentage: -1, resetTime: ""),
            ModelQuota(name: "codex-session", percentage: 65, resetTime: "")
        ]
        XCTAssertEqual(QuotaPercentagePresentation.sorted(models).map(\.name), ["codex-session", "codex-weekly"])
        XCTAssertEqual(QuotaPercentagePresentation.lowestRemaining(in: models), 65)
    }

    /// 独立金额即使带有旧缓存百分比，也不能使仪表盘误报额度耗尽。
    func testStandaloneBalancesDoNotParticipateInPercentageMinimum() {
        let balance = ModelQuota(name: "balance", percentage: 0, resetTime: "", presentation: .amount(value: 12, unit: .usd, semantics: .balance))
        let quota = ModelQuota(name: "session", percentage: 60, resetTime: "")
        XCTAssertNil(QuotaPercentagePresentation.lowestRemaining(in: [balance]))
        XCTAssertEqual(QuotaPercentagePresentation.lowestRemaining(in: [balance, quota]), 60)
        XCTAssertNil(QuotaPercentagePresentation.lowestRemaining(in: []))
        XCTAssertNil(QuotaPercentagePresentation.lowestRemaining(in: [ModelQuota(name: "unknown", percentage: -1, resetTime: "")]))
    }

    /// Antigravity 的独立模型额度不能平均成 50%，真实最低额度始终为 10%。
    func testIndependentModelPoolsUseMinimumAndNeverAverage() {
        let models = [
            ModelQuota(name: "gemini", percentage: 90, resetTime: ""),
            ModelQuota(name: "claude", percentage: 10, resetTime: "")
        ]
        XCTAssertEqual(QuotaPercentagePresentation.lowestRemaining(in: models), 10)
        XCTAssertEqual(QuotaPercentagePresentation.text(65, showUsed: true), "35%")
    }
}
