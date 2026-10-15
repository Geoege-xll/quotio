import AppKit
import SwiftUI

/// 为整页滚动提供原生 Table 的内容高度。只读行几何，不接管 SwiftUI 的代理、数据源或自动行高。
/// NSTableView 的可见区仍受外层 ScrollView 剪裁，因此完整文档高度不会令所有历史行同时实例化。
struct CPAUsageTableContentHeightReader: NSViewRepresentable {
    @Binding var height: CGFloat
    let layoutIdentity: AnyHashable

    func makeNSView(context: Context) -> MeasurementView {
        MeasurementView()
    }

    func updateNSView(_ view: MeasurementView, context: Context) {
        view.onHeightChange = { value in
            guard abs(height - value) > 0.25 else { return }
            height = value
        }
        // 同样行数的数据也可能改变行高，例如价格行新增历史说明；每次内容更新都重新核对。
        view.scheduleMeasurement()
    }

    static func dismantleNSView(_ view: MeasurementView, coordinator: ()) {
        view.stopObserving()
        view.onHeightChange = nil
    }

    final class MeasurementView: NSView {
        var onHeightChange: ((CGFloat) -> Void)?
        private weak var table: NSTableView?
        private var measurementScheduled = false
        private var generation = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopObserving() }
            else { scheduleMeasurement() }
        }

        override func layout() {
            super.layout()
            scheduleMeasurement()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            table = nil
            // 使已排入主队列的旧测量失效；回调只弱引用视图，不延长页面生命周期。
            generation += 1
            measurementScheduled = false
        }

        func scheduleMeasurement() {
            guard !measurementScheduled else { return }
            measurementScheduled = true
            let currentGeneration = generation
            // 合并同一轮布局、行加载和列宽通知，避免在 SwiftUI 的更新事务中同步回写 State。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.measurementScheduled = false
                guard self.window != nil else { return }
                self.measureContent()
            }
        }

        @objc private func geometryDidChange(_ notification: Notification) {
            scheduleMeasurement()
        }

        private func measureContent() {
            guard let discovered = findLocalTable() else { return }
            if table !== discovered {
                stopObserving()
                table = discovered
                observe(discovered)
            }
            guard let table, let scrollView = table.enclosingScrollView else { return }
            guard table.numberOfRows > 0 else {
                onHeightChange?(220)
                return
            }

            // 不能使用 documentView.frame.height：原生文档可能被旧视口撑住，结果变少后无法收缩。
            // 未加载行使用系统估算值；后续原生行测量、列宽或文档几何变化都会再次校准。
            let lastRowBottom = table.rect(ofRow: table.numberOfRows - 1).maxY
            let topInset = max(scrollView.contentInsets.top, table.headerView?.frame.height ?? 0)
            let bottomInset = max(0, scrollView.contentInsets.bottom)
            let horizontalScrollerHeight: CGFloat
            if scrollView.scrollerStyle == .legacy, let scroller = scrollView.horizontalScroller, !scroller.isHidden {
                horizontalScrollerHeight = scroller.frame.height
            } else {
                horizontalScrollerHeight = 0
            }
            // inset 样式的尾部空隙与小数像素留出一档正常行间留白，避免末行落在内部滚动余量中。
            let trailingSpace = max(16, table.rect(ofRow: 0).minY * 2)
            let measured = lastRowBottom + topInset + bottomInset + horizontalScrollerHeight + trailingSpace
            guard measured.isFinite, measured > 0 else { return }
            let scale = window?.backingScaleFactor ?? 1
            onHeightChange?(ceil(measured * scale) / scale)
        }

        private func observe(_ table: NSTableView) {
            let center = NotificationCenter.default
            table.postsFrameChangedNotifications = true
            center.addObserver(self, selector: #selector(geometryDidChange), name: NSView.frameDidChangeNotification, object: table)
            center.addObserver(self, selector: #selector(geometryDidChange), name: NSTableView.columnDidResizeNotification, object: table)
            if let scrollView = table.enclosingScrollView {
                scrollView.contentView.postsFrameChangedNotifications = true
                center.addObserver(self, selector: #selector(geometryDidChange), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
            }
        }

        /// 背景测量视图只向上寻找包含自身 Table 的最近祖先，不跨窗口或扫描应用中的其他表格。
        private func findLocalTable() -> NSTableView? {
            var ancestor = superview
            while let container = ancestor {
                if let match = firstTable(in: container) { return match }
                if container === window?.contentView { break }
                ancestor = container.superview
            }
            return nil
        }

        private func firstTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, let scrollView = table.enclosingScrollView {
                // 同窗口可能同时保留导航过渡的旧页面；只有覆盖本测量背景的原生视口才属于此卡片。
                // 使用公开坐标转换限定归属，不依赖 SwiftUI 私有视图类名或 NSHostingView 的具体泛型。
                let localFrame = scrollView.convert(scrollView.bounds, to: self)
                guard bounds.width > 0, bounds.height > 0,
                      localFrame.contains(CGPoint(x: bounds.midX, y: bounds.midY)) else { return nil }
                return table
            }
            for child in view.subviews where child !== self {
                if let table = firstTable(in: child) { return table }
            }
            return nil
        }
    }
}
