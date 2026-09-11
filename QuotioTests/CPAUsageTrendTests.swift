import AppKit
import SwiftUI
import XCTest
@testable import Quotio

/// 从真实 SQLite 查询到趋势结果验证分量，不使用生产数据库或按总量反推输入、输出、缓存。
final class CPAUsageTrendTests: XCTestCase {
    private var calendar: Calendar { Calendar.current }
    private var day: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_783_500_000)) }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func record(_ id: String, date: Date, provider: String = "p", failed: Bool = false) -> UsageRecord {
        UsageRecord(timestamp: date, provider: provider, model: "m", requestID: id, failed: failed,
                    tokens: .init(input: 100, output: 20, cached: 60, total: 120))
    }

    private func assertComponents(_ report: CPAUsageDashboardReport, file: StaticString = #filePath, line: UInt = #line) {
        let metrics = report.summary.metrics
        XCTAssertEqual(report.trend.reduce(0) { $0 + $1.requests }, metrics.requests, file: file, line: line)
        XCTAssertEqual(report.trend.reduce(0) { $0 + $1.tokens }, metrics.tokens, file: file, line: line)
        XCTAssertEqual(report.trend.reduce(0) { $0 + $1.input }, metrics.input, file: file, line: line)
        XCTAssertEqual(report.trend.reduce(0) { $0 + $1.output }, metrics.output, file: file, line: line)
        XCTAssertEqual(report.trend.reduce(0) { $0 + $1.cached }, metrics.cached, file: file, line: line)
    }

    func testHourlySeriesUseSameFiltersAndFillEmptyIntervalsWithoutDoubleCountingCache() throws {
        let store = CPAUsageEventStore(url: try directory().appendingPathComponent("analytics.sqlite"))
        let records = [record("one", date: day.addingTimeInterval(300)),
                       record("two", date: day.addingTimeInterval(7500)),
                       record("other-provider", date: day.addingTimeInterval(300), provider: "other"),
                       record("failed", date: day.addingTimeInterval(300), failed: true)]
        try store.ingest(records.map { CPAUsageEvent(record: $0) }, collectedAt: day.addingTimeInterval(10800))
        let query = CPAUsageQuery(start: day, end: day.addingTimeInterval(10800), provider: "p", outcome: .success)
        let report = try store.dashboard(query, dimension: .model, metric: .tokens, limit: 8)
        XCTAssertTrue(report.hourly)
        XCTAssertEqual(report.summary.metrics.requests, 2)
        XCTAssertEqual(report.trend.count, 4)
        assertComponents(report)
        let empty = try XCTUnwrap(report.trend.first { $0.date == day.addingTimeInterval(3600) })
        XCTAssertTrue(CPAUsageTrendSeries.allCases.allSatisfy { $0.value(in: empty) == 0 })
        let first = try XCTUnwrap(report.trend.first)
        XCTAssertEqual(CPAUsageTrendSeries.total.value(in: first), 120, "缓存属于输入，不应把总量变成 180")
        XCTAssertEqual(CPAUsageTrendSeries.input.value(in: first), 100)
        XCTAssertEqual(CPAUsageTrendSeries.output.value(in: first), 20)
        XCTAssertEqual(CPAUsageTrendSeries.cached.value(in: first), 60)
    }

    func testLongEventHistoryKeepsEveryComponentDuringCompression() throws {
        let store = CPAUsageEventStore(url: try directory().appendingPathComponent("analytics.sqlite"))
        let events = (0..<481).map { index in
            CPAUsageEvent(record: record("event-\(index)", date: calendar.date(byAdding: .day, value: index, to: day)!))
        }
        try store.ingest(events, collectedAt: events.last!.timestamp)
        let report = try store.dashboard(CPAUsageQuery(), dimension: .model, metric: .tokens, limit: 8)
        XCTAssertLessThanOrEqual(report.trend.count, 240)
        XCTAssertEqual(report.summary.metrics.requests, 481)
        assertComponents(report)
    }

    func testHistoricalMergeKeepsComponentsBeforeCompressionAndAfterReopen() async throws {
        let url = try directory().appendingPathComponent("legacy.json")
        var snapshot = UsageLedgerSnapshot()
        snapshot.buckets = (0..<381).map { index in
            var bucket = UsageBucket(day: calendar.date(byAdding: .day, value: index, to: day)!, provider: "p", model: "m")
            bucket.requests = 1; bucket.inputTokens = 100; bucket.outputTokens = 20
            bucket.cachedTokens = 60; bucket.totalTokens = 120
            return bucket
        }
        snapshot.lastCollectedAt = snapshot.buckets.last!.day.addingTimeInterval(60)
        try JSONEncoder().encode(snapshot).write(to: url)
        let ledger = UsageLedger(url: url)
        let newer = record("new", date: snapshot.buckets.last!.day.addingTimeInterval(120))
        _ = try await ledger.ingest([newer], collectedAt: newer.timestamp)
        for reader in [ledger, UsageLedger(url: url)] {
            let report = try await reader.queryDashboard(CPAUsageQuery(), dimension: .model, metric: .tokens, limit: 8)
            XCTAssertEqual(report.historicalRequests, 381)
            XCTAssertEqual(report.summary.metrics.requests, 382)
            XCTAssertLessThanOrEqual(report.trend.count, 240)
            assertComponents(report)
        }
    }
}

/// 真实 AppKit 窗口验证四系列图在紧凑宽度、单系列、空数据及明暗模式下的布局。
/// 导出合成数据图片供人工检查线型、图例和轴标签，不读取用户统计。
@MainActor
final class CPAUsageTrendRenderingTests: XCTestCase {
    func testMultiSeriesChartsFitCompactWindowInBothAppearances() async throws {
        let beginning = Date(timeIntervalSince1970: 1_783_500_000)
        let points = (0..<12).map { index in
            CPAUsageTrendPoint(date: beginning.addingTimeInterval(Double(index * 3600)), requests: index + 1,
                               tokens: 100_000 + (index % 4) * 50_000, input: 95_000 + (index % 4) * 45_000,
                               output: 5_000 + (index % 4) * 5_000, cached: 70_000 + (index % 3) * 25_000)
        }
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/CPATrendReview")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .light ? "light" : "dark"
            let fixtures: [(String, AnyView)] = [
                ("tokens-" + name, AnyView(CPAUsageTrendChart(points: points, hourly: true, metric: .tokens))),
                ("output-" + name, AnyView(CPAUsageTrendPlot(points: points, series: [.output], hourly: true)
                    .frame(height: 190).quotioCard())),
                ("requests-" + name, AnyView(CPAUsageTrendChart(points: points, hourly: true, metric: .requests))),
                ("empty-" + name, AnyView(CPAUsageTrendChart(points: [], hourly: true, metric: .tokens))),
                ("single-" + name, AnyView(CPAUsageTrendChart(points: Array(points.prefix(1)), hourly: true, metric: .tokens)))
            ]
            for (label, fixture) in fixtures {
                let controller = NSHostingController(rootView: fixture.padding(12)
                    .background(QuotioTheme.Colors.canvasBackground(for: scheme)).preferredColorScheme(scheme))
                // 主机窗口由用例控制外框；卡片仍可按自身内容缩短纵向留白。
                controller.sizingOptions = []
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 440),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentViewController = controller
                // NSHostingController 接入窗口时会采用自身最小尺寸；之后显式恢复测试宽度，
                // 避免把一张只有几十像素宽的图片误当作紧凑窗口验收结果。
                // 图例和说明允许随内容增高，宿主留足纵向空间；产品中该卡片位于可滚动页面。
                window.setContentSize(CGSize(width: 560, height: 440))
                window.orderFront(nil)
                let started = ContinuousClock.now
                try await Task.sleep(for: .milliseconds(100))
                controller.view.layoutSubtreeIfNeeded()
                XCTAssertLessThan(started.duration(to: .now), .seconds(5), "图表布局不能持续占用主线程")
                XCTAssertEqual(controller.view.bounds.width, 560, accuracy: 1)
                // 图表固定为 190pt，卡片高度还包含标题、图例及说明；
                // 验证能放入窗口且图形未被压扁，不要求内容必须撑满 440pt 外框。
                XCTAssertGreaterThan(controller.view.bounds.height, 190)
                XCTAssertLessThanOrEqual(controller.view.bounds.height, 440)
                XCTAssertLessThanOrEqual(controller.view.fittingSize.width, 560)
                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: destination.appendingPathComponent(label + ".png"))
                window.close()
            }
        }
    }
}
