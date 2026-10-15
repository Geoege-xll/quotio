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

    /// 仅测试包装层记录原生 Charts 的 plotFrame，不在生产代码添加测试回调或布局状态。
    private struct Probe: Equatable {
        let frame: CGRect
        let selectedX: CGFloat
    }
    private struct ProbesKey: PreferenceKey {
        static let defaultValue: [String: Probe] = [:]
        static func reduce(value: inout [String: Probe], nextValue: () -> [String: Probe]) {
            value.merge(nextValue()) { _, new in new }
        }
    }
    private struct CardFrameKey: PreferenceKey {
        static let defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            let next = nextValue()
            if next != .zero { value = next }
        }
    }
    private final class Recorder {
        var probes: [String: Probe] = [:]
        var card = CGRect.zero
    }
    @Observable final class DetailsState {
        var expanded = false
    }

    private func window<Content: View>(_ view: Content, width: CGFloat, scheme: ColorScheme) -> (NSWindow, NSHostingView<some View>) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return (window, host)
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    @discardableResult
    private func capture(_ host: NSView) throws -> Data {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)
        return png
    }

    private func measuredPlot(_ metric: ClientAnalyticsDailyTrendData.Metric,
                              data: ClientAnalyticsDailyTrendData, state: UsageTrendHoverState) -> some View {
        ClientAnalyticsTrendPlot(data: data, metric: metric, accent: .blue, state: state)
            .chartBackground { proxy in
                GeometryReader { geometry in
                    if let anchor = proxy.plotFrame, let x = proxy.position(forX: data.days[2].date) {
                        Color.clear.preference(key: ProbesKey.self,
                            value: [metric.rawValue: Probe(frame: geometry[anchor], selectedX: x)])
                    }
                }
            }
            .frame(height: metric == .tokens ? 170 : 110)
    }

    func testNativeAlignedPlotsAndLinkedReadout() async throws {
        let data = fixture()
        let state = UsageTrendHoverState()
        let recorder = Recorder()
        let content = VStack(spacing: 12) {
            measuredPlot(.tokens, data: data, state: state)
            measuredPlot(.tools, data: data, state: state)
            ClientAnalyticsTrendReadout(data: data, state: state)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .quotioPage()
        .onPreferenceChange(ProbesKey.self) { recorder.probes = $0 }
        let (window, host) = window(content, width: 840, scheme: .light)
        defer { window.close() }
        try await settle(window)
        let tokens = try XCTUnwrap(recorder.probes["tokens"])
        let tools = try XCTUnwrap(recorder.probes["tools"])
        XCTAssertEqual(tokens.frame.minX, tools.frame.minX, accuracy: 0.5)
        XCTAssertEqual(tokens.frame.width, tools.frame.width, accuracy: 0.5)
        XCTAssertEqual(tokens.selectedX, tools.selectedX, accuracy: 0.5,
            "独立纵轴下同一天的折线点和柱子必须在同一横坐标")
        let before = try capture(host)
        // 驱动生产共用的日期状态，验证两图提示线和完整读数确实更新；
        // 日期命中与未抽样读数由上面的日期测试验证，不依赖系统鼠标位置。
        state.select(data.days[2].date)
        try await settle(window)
        let selected = try capture(host)
        XCTAssertNotEqual(before, selected)
        XCTAssertEqual(state.date, data.days[2].date)
        XCTAssertEqual(data.nearest(to: try XCTUnwrap(state.date))?.tokens, 90_000)
        XCTAssertEqual(data.nearest(to: try XCTUnwrap(state.date))?.tools, 0)
        state.select(nil)
    }

    func testNativeCardThemesAndDetailsExpansion() async throws {
        let data = fixture()
        for (width, scheme) in [(840.0, ColorScheme.light), (580.0, ColorScheme.dark)] {
            let recorder = Recorder()
            let content = ClientAnalyticsDailyTrend(data: data, subtitle: "2026-10-01 → 10-04", accent: .blue)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: CardFrameKey.self,
                            value: geometry.frame(in: .named("testDailyTrend")))
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .coordinateSpace(.named("testDailyTrend"))
                .quotioPage()
                .onPreferenceChange(CardFrameKey.self) { recorder.card = $0 }
            let (window, host) = window(content, width: width, scheme: scheme)
            defer { window.close() }
            try await settle(window)
            try capture(host)
            let foldedHeight = recorder.card.height
            XCTAssertGreaterThan(foldedHeight, 300, "必须获得真实卡片布局，而不是空窗口")
            window.close()

            // XCTest 合成鼠标事件不能稳定触发 SwiftUI 跟踪层。这里驱动生产
            // DisclosureGroup 使用的同一 Binding，验证真实展开／收起后的原生布局，
            // 不模拟另一份明细实现，也不暴露或修改用户页面的展开状态。
            let detailsState = DetailsState()
            let detailsRecorder = Recorder()
            let detailsContent = ClientAnalyticsTrendDetailsDisclosure(days: data.days,
                isExpanded: Binding(get: { detailsState.expanded }, set: { detailsState.expanded = $0 }))
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: CardFrameKey.self, value: geometry.frame(in: .local))
                    }
                }
                .quotioCard().padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .quotioPage()
                .onPreferenceChange(CardFrameKey.self) { detailsRecorder.card = $0 }
            let (detailsWindow, detailsHost) = self.window(detailsContent, width: width, scheme: scheme)
            defer { detailsWindow.close() }
            try await settle(detailsWindow)
            let collapsed = detailsRecorder.card.height
            detailsState.expanded = true
            try await settle(detailsWindow)
            XCTAssertGreaterThan(detailsRecorder.card.height, collapsed + 50,
                "展开后必须实际显示日期、Token 和调用次数三列明细")
            try capture(detailsHost)
            detailsState.expanded = false
            try await settle(detailsWindow)
            XCTAssertEqual(detailsRecorder.card.height, collapsed, accuracy: 0.5,
                "收起后恢复原布局，不能遗留空白高度")
        }
    }
}
