import XCTest
@testable import Quotio

/// 只构造模型日汇总，验证可视扇区没有丢数据；不创建 SwiftUI 或访问用户账本。
final class UsageStatisticsDistributionTests: XCTestCase {
    private func model(_ name: String, provider: String = "provider", tokens: Int) -> UsageStatisticsModel {
        var bucket = UsageBucket(day: Date(timeIntervalSince1970: 0), provider: provider, model: name)
        bucket.totalTokens = tokens
        return UsageStatisticsModel(provider: provider, model: name, totals: UsageTotals(buckets: [bucket]))
    }

    func testMoreThanSixModelsKeepsAllTokensAndSharesSumToOne() {
        let models = (1...12).map { model("model-\($0)", tokens: $0 * 100) }
        let slices = UsageDistributionData.slices(models: models)
        let total = models.reduce(0) { $0 + $1.totals.totalTokens }
        XCTAssertEqual(slices.count, 6)
        XCTAssertEqual(slices.filter(\.isOther).count, 1)
        XCTAssertEqual(slices.last?.tokens, models.dropFirst(5).reduce(0) { $0 + $1.totals.totalTokens })
        XCTAssertEqual(slices.reduce(0) { $0 + $1.tokens }, total)
        XCTAssertEqual(slices.reduce(0.0) { $0 + Double($1.tokens) / Double(total) }, 1, accuracy: 0.000001)
    }

    func testZeroTokenModelsNeverProducePlaceholderSectorsOrOther() {
        let empty = (0..<10).map { model("zero-\($0)", tokens: 0) }
        XCTAssertTrue(UsageDistributionData.slices(models: empty).isEmpty)
        let mixed = UsageDistributionData.slices(models: empty + [model("positive", tokens: 7)])
        XCTAssertEqual(mixed.count, 1)
        XCTAssertEqual(mixed.first?.tokens, 7)
        XCTAssertFalse(mixed[0].isOther)
    }

    func testSameModelFromDifferentProvidersRetainsSeparateIdentityAndValues() {
        let models = [model("shared", provider: "a", tokens: 20), model("shared", provider: "b", tokens: 30)]
        let slices = UsageDistributionData.slices(models: models)
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(Set(slices.map(\.id)).count, 2)
        XCTAssertEqual(slices.map(\.provider), ["a", "b"])
        XCTAssertEqual(slices.map(\.tokens), [20, 30])
        XCTAssertTrue(slices.allSatisfy { !$0.isOther })
    }
}
