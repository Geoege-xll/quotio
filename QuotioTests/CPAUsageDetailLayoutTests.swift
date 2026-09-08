import AppKit
import SwiftUI
import XCTest
@testable import Quotio

/// 使用真实 SwiftUI 承载器测量页面，防止原生表格与多行说明再次抬高窗口最小尺寸。
/// 数据库放在独立临时目录；布局验证不会读取或修改用户的统计记录。
@MainActor
final class CPAUsageDetailLayoutTests: XCTestCase {
    func testPricingPageFitsCompactWindow() throws {
        let store = try isolatedStore()
        let controller = NSHostingController(rootView:
            CPAUsagePricingView(store: store, selection: CPAUsageSelection(range: .all)))
        assertFitsWindow(controller)
    }

    func testRecordsPageFitsCompactWindow() throws {
        let store = try isolatedStore()
        let controller = NSHostingController(rootView:
            CPAUsageRecordsView(store: store, selection: CPAUsageSelection(range: .all)))
        assertFitsWindow(controller)
    }

    func testPricingColumnsFitDefaultWidthAndExpandOnWideWindows() async throws {
        let store = try await populatedStore(history: false)
        let page = CPAUsagePricingView(store: store, selection: CPAUsageSelection(range: .all))
            .environment(\.scenePhase, .active)
        let (window, controller) = makeWindow(page)
        defer { window.close() }
        try await settleLayout()
        try assertColumnsFit(in: controller.view, expectedColumns: 4)

        // 扩展单价列只改变展示，缩回默认宽度后列数恢复，分页仍保持 20 条。
        window.setContentSize(CGSize(width: 1000, height: 500))
        try await settleLayout()
        try assertColumnsFit(in: controller.view, expectedColumns: 6)
        window.setContentSize(CGSize(width: 600, height: 500))
        try await settleLayout()
        try assertColumnsFit(in: controller.view, expectedColumns: 4)
    }

    func testRequestAndHistoricalColumnsFitDefaultWidth() async throws {
        for history in [false, true] {
            let store = try await populatedStore(history: history)
            let (window, controller) = makeWindow(CPAUsageRecordsView(store: store, selection: CPAUsageSelection(range: .all)))
            defer { window.close() }
            try await settleLayout()
            try assertColumnsFit(in: controller.view, expectedColumns: history ? 4 : 5)
            if !history {
                window.setContentSize(CGSize(width: 1000, height: 500))
                try await settleLayout()
                try assertColumnsFit(in: controller.view, expectedColumns: 7)
                window.setContentSize(CGSize(width: 600, height: 500))
                try await settleLayout()
                try assertColumnsFit(in: controller.view, expectedColumns: 5)
            }
        }
    }

    private func assertColumnsFit(in view: NSView, expectedColumns: Int,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let table = try XCTUnwrap(tables(in: view).first, file: file, line: line)
        let scroll = try XCTUnwrap(table.enclosingScrollView, file: file, line: line)
        XCTAssertEqual(table.numberOfRows, 20, file: file, line: line)
        XCTAssertEqual(table.numberOfColumns, expectedColumns, file: file, line: line)
        XCTAssertLessThanOrEqual(table.frame.width, scroll.contentView.bounds.width + 1,
                                "默认内容区所有主要列应完整显示，不需要横向滚动", file: file, line: line)
    }

    /// 用较长模型名、混合价格和超过一页的数据承载真实业务页面，验证实际 Table 列配置。
    private func populatedStore(history: Bool) async throws -> UsageStatisticsStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let records = (0..<25).map { index in
            UsageRecord(timestamp: Date(), provider: "long-provider-name", model: "long-model-name-for-layout-\(index)",
                        requestID: "layout-\(index)", tokens: .init(input: 200_000, output: 2_000))
        }
        let ledger: UsageLedger
        if history {
            var snapshot = UsageLedgerSnapshot()
            snapshot.buckets = records.map { record in
                var bucket = UsageBucket(day: Calendar.current.startOfDay(for: record.timestamp), provider: record.provider, model: record.model)
                bucket.add(record)
                return bucket
            }
            let url = directory.appendingPathComponent("legacy.json")
            try JSONEncoder().encode(snapshot).write(to: url)
            ledger = UsageLedger(url: url)
        } else {
            ledger = UsageLedger(databaseURL: directory.appendingPathComponent("analytics.sqlite"))
            _ = try await ledger.ingest(records, collectedAt: Date())
            try await ledger.savePrice(CPAModelPrice(model: records[0].model, input: 2, output: 4))
        }
        return UsageStatisticsStore(ledger: ledger)
    }

    func testTableWheelScrollsWholePageAndKeepsHorizontalScrolling() async throws {
        let (window, controller) = makeWindow(TableFixture(count: 20))
        defer { window.close() }
        try await settleLayout()
        let table = try XCTUnwrap(tables(in: controller.view).first)
        let inner = try XCTUnwrap(table.enclosingScrollView)
        let outer = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSScrollView }.first { $0 !== inner })
        outer.contentView.scroll(to: CGPoint(x: 0, y: 180))
        outer.reflectScrolledClipView(outer.contentView)
        let innerY = inner.contentView.bounds.minY
        let outerY = outer.contentView.bounds.minY
        // 从原生表格接收滚轮事件，验证鼠标位于列表内时也能带动页面筛选、摘要和底栏。
        inner.scrollWheel(with: try wheel(vertical: -80, horizontal: 0))
        try await settleLayout()
        XCTAssertGreaterThan(outer.contentView.bounds.minY, outerY + 20)
        XCTAssertEqual(inner.contentView.bounds.minY, innerY, accuracy: 1)

        let newOuterY = outer.contentView.bounds.minY
        let innerX = inner.contentView.bounds.minX
        inner.scrollWheel(with: try wheel(vertical: 0, horizontal: -80))
        try await settleLayout()
        XCTAssertGreaterThan(inner.contentView.bounds.minX, innerX + 20)
        XCTAssertEqual(outer.contentView.bounds.minY, newOuterY, accuracy: 1)
        XCTAssertEqual(window.contentView?.frame.size, CGSize(width: 600, height: 500))
    }

    func testPageChangesShrinkHeightAndReplacedTableIsMeasured() async throws {
        let (window, controller) = makeWindow(TableFixture(count: 20))
        defer { window.close() }
        try await settleLayout()
        let fullHeight = try tableHeight(in: controller.view)
        XCTAssertGreaterThan(fullHeight, 500)

        controller.rootView = TableFixture(count: 1)
        try await settleLayout()
        let shortHeight = try tableHeight(in: controller.view)
        XCTAssertLessThan(shortHeight, 160, "末页只有一行时不能保留前一页的空白高度")

        // 同样一行新增第二行说明，也必须重新测量；不能只观察数据条数。
        controller.rootView = TableFixture(count: 1, rowHeight: 80)
        try await settleLayout()
        XCTAssertGreaterThan(try tableHeight(in: controller.view), shortHeight + 20)

        // 切换请求／历史会替换原生 Table，测量器必须转到新实例，空态保留提示所需空间。
        controller.rootView = TableFixture(count: 0, tableIdentity: 1)
        try await settleLayout()
        XCTAssertEqual(try XCTUnwrap(tables(in: controller.view).first).numberOfRows, 0)
        XCTAssertEqual(try tableHeight(in: controller.view), 220, accuracy: 1)
    }

    func testSeparateTablesMeasureTheirOwnContentAndLegacyScrollerFits() async throws {
        let fixture = HStack(spacing: 0) { TableFixture(count: 20); TableFixture(count: 1) }
        let (window, controller) = makeWindow(fixture)
        defer { window.close() }
        try await settleLayout()
        let allTables = tables(in: controller.view)
        XCTAssertEqual(allTables.count, 2)
        let longTable = try XCTUnwrap(allTables.first { $0.numberOfRows == 20 })
        let shortTable = try XCTUnwrap(allTables.first { $0.numberOfRows == 1 })
        XCTAssertGreaterThan(try XCTUnwrap(longTable.enclosingScrollView).frame.height, 500)
        XCTAssertLessThan(try XCTUnwrap(shortTable.enclosingScrollView).frame.height, 160)

        let inner = try XCTUnwrap(longTable.enclosingScrollView)
        inner.scrollerStyle = .legacy
        inner.tile()
        try await settleLayout()
        // 系统设置为始终显示滚动条时，水平滚动条占用的高度不能遮住本页最后一行。
        XCTAssertGreaterThanOrEqual(inner.contentView.bounds.maxY, longTable.rect(ofRow: 19).maxY)
    }

    /// 回归测试只承载合成行，不读用户数据库，也不启动采集或申请录屏权限。
    private struct TableFixture: View {
        let count: Int
        var rowHeight: CGFloat = 38
        var tableIdentity = 0
        private struct Row: Identifiable { let id: Int }

        var body: some View {
            CPAUsageDetailPage {
                Text("筛选和摘要").frame(height: 200)
            } content: {
                CPAUsageTableCard(layoutIdentity: "\(count)-\(rowHeight)-\(tableIdentity)") {
                    Text("明细")
                } content: {
                    Table((0..<count).map { Row(id: $0) }) {
                        TableColumn("模型") { row in Text("model-\(row.id)").frame(height: rowHeight) }.width(300)
                        TableColumn("Tokens") { _ in Text("203.0M") }.width(300)
                        TableColumn("请求") { _ in Text("2,728") }.width(180)
                    }
                    .id(tableIdentity)
                } footer: {
                    Text("每页 20 条")
                }
            }
        }
    }

    private func makeWindow<Content: View>(_ root: Content) -> (NSWindow, NSHostingController<Content>) {
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 600, height: 500))
        controller.view.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        window.orderFront(nil)
        return (window, controller)
    }

    private func settleLayout() async throws {
        // 原生 Table 在 SwiftUI 提交后异步加载可见行，再通知测量器；让主运行循环完成这些事务。
        try await Task.sleep(for: .milliseconds(500))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func tables(in view: NSView) -> [NSTableView] { descendants(view).compactMap { $0 as? NSTableView } }
    private func tableHeight(in view: NSView) throws -> CGFloat {
        try XCTUnwrap(tables(in: view).first?.enclosingScrollView).frame.height
    }
    private func wheel(vertical: Int32, horizontal: Int32) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                         wheel1: vertical, wheel2: horizontal, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func assertFitsWindow<Content: View>(_ controller: NSHostingController<Content>,
                                                file: StaticString = #filePath, line: UInt = #line) {
        // macOS 会先以零尺寸探测内容下限。即使最终窗口足够宽，探测阶段把说明文本
        // 折成极窄的长列，也会令系统自动放大窗口；因此同时检查下限与实际可用尺寸。
        let minimum = controller.sizeThatFits(in: .zero)
        XCTAssertLessThanOrEqual(minimum.height, 480, "页面不能要求超过紧凑窗口的最小高度", file: file, line: line)
        for size in [CGSize(width: 600, height: 480), CGSize(width: 780, height: 620)] {
            let measured = controller.sizeThatFits(in: size)
            XCTAssertLessThanOrEqual(measured.height, size.height, "内容应在窗口内部滚动", file: file, line: line)
            XCTAssertLessThanOrEqual(measured.width, size.width, "宽表应在表格内部滚动", file: file, line: line)
        }
    }

    private func isolatedStore() throws -> UsageStatisticsStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return UsageStatisticsStore(ledger: UsageLedger(databaseURL: directory.appendingPathComponent("analytics.sqlite")))
    }
}
