import AppKit
import SwiftUI
import XCTest
@testable import QuotioPlus

/// 只检验明细页的滚轮和内容高度行为；不锁定已定版界面的固定像素外观。
@MainActor
final class CPAUsageDetailInteractionTests: XCTestCase {
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

        // 鼠标处于原生表格内时，纵向滚轮仍应滚动整页，避免筛选和底栏被表格截断。
        inner.scrollWheel(with: try wheel(vertical: -80, horizontal: 0))
        try await settleLayout()
        XCTAssertGreaterThan(outer.contentView.bounds.minY, outerY + 20)
        XCTAssertEqual(inner.contentView.bounds.minY, innerY, accuracy: 1)

        // 横向滚轮应只移动表格本身，不应改变外层页面的纵向位置。
        let newOuterY = outer.contentView.bounds.minY
        let innerX = inner.contentView.bounds.minX
        inner.scrollWheel(with: try wheel(vertical: 0, horizontal: -80))
        try await settleLayout()
        XCTAssertGreaterThan(inner.contentView.bounds.minX, innerX + 20)
        XCTAssertEqual(outer.contentView.bounds.minY, newOuterY, accuracy: 1)
    }

    func testChangingPageAndReplacingTableRecomputesContentHeight() async throws {
        let (window, controller) = makeWindow(TableFixture(count: 20))
        defer { window.close() }
        try await settleLayout()
        let longHeight = try tableHeight(in: controller.view)

        // 翻到只剩一行的末页时，内层表格应立即收缩，避免留下上一页的空白。
        controller.rootView = TableFixture(count: 1)
        try await settleLayout()
        let shortHeight = try tableHeight(in: controller.view)
        XCTAssertLessThan(shortHeight, longHeight - 100)

        // 相同行数的行内容增高也必须重新测量，不能只依赖行数变化。
        controller.rootView = TableFixture(count: 1, rowHeight: 80)
        try await settleLayout()
        XCTAssertGreaterThan(try tableHeight(in: controller.view), shortHeight + 20)

        // 切换统计类别会替换原生 Table；测量器应跟随新实例并保留空态提示空间。
        controller.rootView = TableFixture(count: 0, tableIdentity: 1)
        try await settleLayout()
        let emptyTable = try XCTUnwrap(tables(in: controller.view).first)
        XCTAssertEqual(emptyTable.numberOfRows, 0)
        XCTAssertGreaterThan(try tableHeight(in: controller.view), 100)
    }

    /// 使用合成表格行测试事件传递，不读取用户的统计数据库。
    private struct TableFixture: View {
        let count: Int
        var rowHeight: CGFloat = 38
        var tableIdentity = 0
        private struct Row: Identifiable { let id: Int }

        var body: some View {
            CPAUsageDetailPage {
                Text("筛选和摘要").frame(height: 200)
            } content: {
                CPAUsageTableCard(layoutIdentity: "interaction-\(count)-\(rowHeight)-\(tableIdentity)") {
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
        // 原生 Table 在 SwiftUI 提交后异步加载可见行，给主运行循环完成事务的时间。
        try await Task.sleep(for: .milliseconds(500))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func tables(in view: NSView) -> [NSTableView] { descendants(view).compactMap { $0 as? NSTableView } }

    private func tableHeight(in view: NSView) throws -> CGFloat {
        let table = try XCTUnwrap(tables(in: view).first)
        return try XCTUnwrap(table.enclosingScrollView).frame.height
    }

    private func wheel(vertical: Int32, horizontal: Int32) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                         wheel1: vertical, wheel2: horizontal, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }
}
