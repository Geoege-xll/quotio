import AppKit
import SwiftUI
import XCTest
@testable import Quotio

/// 在真实承载窗口中反复切换数据、尺寸并滚动图表，检查 Swift Charts 布局是否持续占用主线程。
/// 使用合成的日汇总，不启动客户端采集、不访问用户数据库或请求任何录屏权限。
@MainActor
final class UsageStatisticsChartRenderingTests: XCTestCase {
    func testContinuousHoverUpdatesKeepChartResponsive() async throws {
        let days = (0..<1_095).map { index in
            var bucket = UsageBucket(day: Date(timeIntervalSince1970: Double(index * 86_400)), provider: "Codex", model: "hover-fixture")
            bucket.totalTokens = index == 517 ? 20_000_000 : 1_000 + index
            return UsageStatisticsDay(day: bucket.day, totals: UsageTotals(buckets: [bucket]))
        }
        let selection = UsageTrendHoverState()
        let controller = NSHostingController(rootView:
            UsageStatisticsTrendPlot(days: days, accent: .blue, hoverState: selection).equatable())
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 650, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        for index in 0..<80 {
            let day = days[(index * 37) % days.count].day
            // 同一日连续上千次移动后跨到下一日；每次让主线程真正执行一轮图表覆盖层事务。
            for _ in 0..<1_000 { selection.select(day) }
            try await Task.sleep(for: .milliseconds(2))
            controller.view.layoutSubtreeIfNeeded()
        }
        selection.select(nil)
        XCTAssertNil(selection.date)
        XCTAssertLessThan(start.duration(to: .now), .seconds(5), "连续悬停不能令 Charts 布局占满主线程")
    }

    func testChartsRemainResponsiveWhenScrollingAndChangingData() async throws {
        let controller = NSHostingController(rootView: chartPage(days: 90, models: 8, width: 650))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 650, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }
        for configuration in [(365, 12, 650.0), (1, 1, 820.0), (30, 6, 620.0), (1_095, 20, 900.0)] {
            let start = ContinuousClock.now
            controller.rootView = chartPage(days: configuration.0, models: configuration.1, width: configuration.2)
            window.setContentSize(CGSize(width: configuration.2, height: 600))
            // 允许布局事务与滚动任务执行，主线程若陷入图表反馈循环，将无法及时恢复到这里。
            try await Task.sleep(for: .milliseconds(200))
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertLessThan(start.duration(to: .now), .seconds(5), "切换统计数据后，主线程应及时恢复响应")
        }
    }

    private func chartPage(days: Int, models: Int, width: CGFloat) -> some View {
        let beginning = Date(timeIntervalSince1970: 1_700_000_000)
        let buckets = (0..<days).flatMap { day in
            (0..<models).map { model in
                var bucket = UsageBucket(day: beginning.addingTimeInterval(Double(day * 86_400)),
                                         provider: "Codex", model: "fixture-model-\(model)")
                bucket.totalTokens = model == 0 ? 1_000_000 + day * 100 : (model + 1) * 3_700
                return bucket
            }
        }
        let presentation = UsageStatisticsPresentation(buckets: buckets, interval: nil, provider: nil, model: nil)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    Color.clear.frame(height: 700)
                    UsageStatisticsTrend(days: presentation.days).id("trend")
                    UsageStatisticsInsights(presentation: presentation, contentWidth: width - 40).id("insights")
                }.padding(20)
            }
            .task(id: days) {
                proxy.scrollTo("trend", anchor: .top)
                try? await Task.sleep(for: .milliseconds(60))
                proxy.scrollTo("insights", anchor: .top)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }
}
