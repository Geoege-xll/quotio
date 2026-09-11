import AppKit
import SwiftUI
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

    @MainActor
    func testRenderCurrentUsageStatisticsInsights() async throws {
        let output = URL(fileURLWithPath: "/Users/liqunmacmini/Desktop/quotio/build/UsageReview", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var buckets: [UsageBucket] = []

        let modelData: [(String, String, Int, Int, Int, Int)] = [
            ("claude-3-7-sonnet-20250219", "Claude", 2_450_000_000, 320_000_000, 1_800_000_000, 180_000_000),
            ("gpt-4o", "OpenAI", 1_120_000_000, 190_000_000, 450_000_000, 0),
            ("claude-3-5-haiku-20241022", "Claude", 850_000_000, 95_000_000, 600_000_000, 0),
            ("o3-mini", "OpenAI", 620_000_000, 110_000_000, 210_000_000, 95_000_000),
            ("deepseek-r1", "DeepSeek", 430_000_000, 80_000_000, 150_000_000, 60_000_000),
            ("gemini-2.0-flash", "Google", 190_000_000, 45_000_000, 50_000_000, 0)
        ]

        for (modelName, provider, input, outputTokens, cached, reasoning) in modelData {
            for dayOffset in 0..<14 {
                guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
                var bucket = UsageBucket(day: day, provider: provider, model: modelName)
                let factor = Double(14 - dayOffset) / 14.0 * Double.random(in: 0.7...1.3)
                bucket.inputTokens = Int(Double(input) / 14.0 * factor)
                bucket.outputTokens = Int(Double(outputTokens) / 14.0 * factor)
                bucket.cachedTokens = Int(Double(cached) / 14.0 * factor)
                bucket.reasoningTokens = Int(Double(reasoning) / 14.0 * factor)
                bucket.totalTokens = bucket.inputTokens + bucket.outputTokens
                bucket.requests = max(1, Int(factor * 20))
                buckets.append(bucket)
            }
        }

        let presentation = UsageStatisticsPresentation(buckets: buckets, interval: nil, provider: nil, model: nil)

        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = UsageStatisticsInsights(presentation: presentation, contentWidth: 1000)
                .padding(20)
                .frame(width: 1000)
                .background(QuotioTheme.Colors.cardBackground(for: scheme))
                .environment(\.colorScheme, scheme)

            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()

            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]))
            try png.write(to: output.appendingPathComponent("usage-insights-\(name).png"))
        }
    }
}


