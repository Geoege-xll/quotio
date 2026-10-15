import SwiftUI

/// 筛选与总览共用等宽布局，优先使用可以排满的列数：六项筛选为三列或两列，
/// 四项指标为四列或两列。避免自适应网格在中间宽度形成「三项＋一项」的孤行。
/// 直接消费父级宽度并测量文本高度，不通过 GeometryReader 回写状态，也不复制控件树。
struct CPAUsageAdaptiveGrid: Layout {
    var maximumColumns: Int
    var minimumColumnWidth: CGFloat
    var spacing: CGFloat = 12
    /// 轻量次级指标可保留最后一行空位；主卡和原筛选默认仍要求整行排满。
    var allowsIncompleteLastRow = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = arrangement(width: proposal.width, subviews: subviews)
        return CGSize(width: layout.width, height: layout.rowHeights.reduce(0, +)
            + CGFloat(max(0, layout.rowHeights.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in layout.rowHeights.enumerated() {
            for column in 0..<layout.columns {
                let index = row * layout.columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (layout.columnWidth + spacing), y: y),
                    anchor: .topLeading, proposal: ProposedViewSize(width: layout.columnWidth, height: height))
            }
            y += height + spacing
        }
    }

    private func arrangement(width proposedWidth: CGFloat?, subviews: Subviews)
        -> (width: CGFloat, columns: Int, columnWidth: CGFloat, rowHeights: [CGFloat]) {
        let maximum = max(1, min(maximumColumns, subviews.count))
        let idealWidth = CGFloat(maximum) * minimumColumnWidth + CGFloat(maximum - 1) * spacing
        let width = max(0, proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth)
        var columns = 1
        for candidate in (1...maximum).reversed() {
            let requiredWidth = CGFloat(candidate) * minimumColumnWidth + CGFloat(candidate - 1) * spacing
            if (allowsIncompleteLastRow || subviews.count.isMultiple(of: candidate)), requiredWidth <= width {
                columns = candidate
                break
            }
        }
        let columnWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var heights: [CGFloat] = []
        for (index, view) in subviews.enumerated() {
            let height = view.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            if index.isMultiple(of: columns) { heights.append(height) }
            else { heights[heights.count - 1] = max(heights[heights.count - 1], height) }
        }
        return (width, columns, columnWidth, heights)
    }
}

/// 字段名称放在系统控件上方，长模型名不再和标签争用同一行。
/// 外层标签只负责视觉排版，原生控件自身仍保留完整无障碍名称与焦点行为。
struct CPAUsageFilterField<Content: View>: View {
    let titleKey: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleKey.localized())
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            content
                .modifier(CPAUsageFlexibleControlSizing())
                .frame(maxWidth: .infinity, alignment: .leading)
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// macOS 26 使用系统提供的可伸缩按钮布局，不通过绘制背景模拟等宽菜单。
/// 较早系统保留自身控件尺寸和交互，避免为了视觉一致性替换原生行为。
private struct CPAUsageFlexibleControlSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.buttonSizing(.flexible) }
        else { content }
    }
}

/// 系统菜单使用原生按钮样式填满字段宽度，避免 macOS 的独立弹出式 Picker
/// 只按选中文字收缩，造成搜索按钮与下拉选择器宽窄不一。选择内容仍由原生 Picker 管理。
struct CPAUsageFilterMenu<Content: View>: View {
    let titleKey: String
    let value: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            // 外层 Menu 已经提供下拉入口，内部 Picker 必须将选项平铺到当前菜单。
            // 仅隐藏 Picker 标签不会消除子菜单；显式指定 inline，避免提供商、结果、
            // 图表分组和指标再次嵌套一层，同时保留系统的选中标记与键盘选择行为。
            content.pickerStyle(.inline)
        } label: {
            Text(value).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.button).buttonStyle(.bordered)
        .help(value)
        .accessibilityLabel(titleKey.localized()).accessibilityValue(value)
    }
}
