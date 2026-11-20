// Copyright 2026 AIUsage contributors. Licensed under Apache-2.0.
// 参考 DashboardView+Heatmap.swift（bdb83bbe）：保留全年网格、色阶、月份和悬浮明细。
// 修改：接入客户端日账本；窄窗口保留全部周并横向滚动；补充键盘选择和采集前未知状态。
import SwiftUI

/// 悬浮信息交给页面根层绘制，避免后面的图表卡片遮住明细；不保存原始请求或凭据。
struct UsageHeatmapHover {
    let day: UsageHeatmapPresentation.Day
    let title: String
    let accent: Color
    let anchor: CGRect
    var metric: CPAUsageChartMetric = .tokens
}

struct UsageStatisticsHeatmap: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let presentation: UsageHeatmapPresentation
    let accent: Color
    var availableWidth: CGFloat = 720
    let onHover: (UsageHeatmapHover?) -> Void
    @State private var hoveredDate: Date?
    @State private var selectedDay: UsageHeatmapPresentation.Day?

    var body: some View {
        AnalyticsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3.fill")
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(presentation.metric.titleKey.localized() + " · " + "usage.replica.lastYear".localized())
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .foregroundStyle(accent)
                // 根据真实周数计算方格，不把全年硬编码成 52 列；给末月标签预留右侧空间。
                // 高度跟随格子尺寸变化，避免窄窗口中留下大块空白或宽窗口中截断最后一行。
                ScrollView(.horizontal) {
                    grid(side: cellSide).padding(.trailing, 24)
                }
                .defaultScrollAnchor(.trailing)
                .frame(height: gridHeight)
                footer
                if presentation.hasSelection {
                    Label("usage.analytics.selectedDates".localized(), systemImage: "circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if presentation.metric == .cost {
                    HStack(spacing: 8) {
                        Label("usage.records.unknown".localized(), systemImage: "line.diagonal")
                        Label("usage.analytics.partialEstimate".localized(), systemImage: "minus")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
                .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .popover(item: $selectedDay) { day in
            UsageHeatmapDetail(day: day, title: title, accent: accent, metric: presentation.metric)
                .padding(16).frame(width: 360)
        }
        .onChange(of: presentation.metric) { clearDetails() }
        .onChange(of: presentation.costIdentity) { clearDetails() }
        .onDisappear { onHover(nil) }
    }

    private func clearDetails() {
        selectedDay = nil
        hoveredDate = nil
        onHover(nil)
    }

    private var cellSide: CGFloat {
        let columns = max(1, presentation.weeks.count)
        let gaps = CGFloat(max(0, columns - 1)) * 3
        return min(16, max(7, (availableWidth - 32 - 28 - 24 - gaps) / CGFloat(columns)))
    }

    /// 将尺寸运算与 ViewBuilder 的泛型推断分开，避免 Xcode 26.1 在 Release
    /// 构建中对混合整数常量与 CGFloat 的长表达式发生类型检查超时。
    /// 固定高度 40pt = 月份标签 15pt + 标签间距 3pt + 六处行间距 18pt + 上下留白 4pt。
    private var gridHeight: CGFloat {
        let fixedHeight: CGFloat = 40
        let rowCount: CGFloat = 7
        return fixedHeight + rowCount * cellSide
    }

    /// 周和日都用真实日期作为身份；窗口缩放不会把某一天的悬浮状态错误复用到另一格。
    private func grid(side: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 3) {
                Color.clear.frame(height: 15)
                ForEach(0..<7, id: \.self) { row in
                    Text([0, 2, 4].contains(row) ? weekday(row) : "")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .frame(width: 28, height: side, alignment: .leading)
                }
            }
            HStack(alignment: .top, spacing: 3) {
                ForEach(presentation.weeks) { week in
                    VStack(spacing: 3) {
                        Text(monthLabel(week)).font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary).fixedSize()
                            .frame(width: side, height: 15, alignment: .leading)
                        ForEach(week.days) { day in cell(day, side: side) }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func cell(_ day: UsageHeatmapPresentation.Day, side: CGFloat) -> some View {
        let intensity = presentation.intensity(day.value(presentation.metric))
        let hovered = hoveredDate == day.date
        let isMarked = presentation.hasSelection && day.isInSelection && !day.isFuture
        let isDimmed = presentation.hasSelection && !day.isInSelection
        let costIndicator = day.cost.amount == nil ? "line.diagonal" : "minus"
        let radius = max(2, min(4, side * 0.24))
        return GeometryReader { geometry in
            Button {
                onHover(nil)
                selectedDay = day
            } label: {
                RoundedRectangle(cornerRadius: radius)
                    .fill(AnalyticsSurface.row(colorScheme))
                    .overlay(RoundedRectangle(cornerRadius: radius).fill(accent.opacity(opacity(intensity))))
                    .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(
                        hovered ? Color.primary : (Calendar.current.isDateInToday(day.date) ? accent : .clear),
                        lineWidth: hovered ? 1.5 : 1.2))
                    .opacity(day.isFuture || day.isBeforeCollection || isDimmed ? 0.4 : 1)
                    // 日期范围用实心点和淡化共同表达；色阶仍只表达日值的大小。
                    .overlay(alignment: .bottom) {
                        if isMarked {
                            Circle().fill(AnalyticsSurface.row(colorScheme))
                                .overlay { Circle().strokeBorder(Color.primary, lineWidth: 1) }
                                .frame(width: 4, height: 4).padding(.bottom, 1)
                        }
                    }
                    .overlay(alignment: .top) {
                        if presentation.metric == .cost, day.cost.isPartial, !day.isFuture {
                            Image(systemName: costIndicator).font(.system(size: 5, weight: .bold))
                                .foregroundStyle(.primary).accessibilityHidden(true)
                                .opacity(isDimmed ? 0.4 : 1)
                        }
                    }
                    .scaleEffect(hovered && !reduceMotion ? 1.12 : 1)
                    .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.72), value: hovered)
            }
            .buttonStyle(.plain)
            .disabled(day.isFuture)
            .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
            .accessibilityValue(UsageHeatmapDetail.accessibilityValue(day, metric: presentation.metric))
            .accessibilityAddTraits(isMarked ? .isSelected : [])
            .onHover { inside in
                guard !day.isFuture else { return }
                hoveredDate = inside ? day.date : nil
                onHover(inside ? UsageHeatmapHover(day: day, title: title, accent: accent,
                                                  anchor: geometry.frame(in: .named("usageHeatmapPage")),
                                                  metric: presentation.metric) : nil)
            }
        }
        .frame(width: side, height: side)
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { footerValues; Spacer(minLength: 4); legend }
            VStack(alignment: .leading, spacing: 6) { footerValues; legend }
        }
        .monospacedDigit()
    }
    @ViewBuilder private var footerValues: some View {
        Text(UsageHeatmapDetail.formattedValue(presentation.totals, cost: presentation.cost, metric: presentation.metric))
            .font(.caption.weight(.semibold))
        Text(String(format: "usage.replica.activeDays".localized(), presentation.activeDays))
            .font(.caption2).foregroundStyle(.secondary)
        if let peak = presentation.peak {
            Text("usage.replica.peak".localized() + " "
                 + UsageHeatmapDetail.formattedValue(peak.totals, cost: peak.cost, metric: presentation.metric)
                 + " · " + peak.date.formatted(.dateTime.month().day()))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var legend: some View {
        HStack(spacing: 3) {
            Text("usage.replica.less".localized())
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2).fill(AnalyticsSurface.row(colorScheme))
                    .overlay(RoundedRectangle(cornerRadius: 2).fill(accent.opacity(opacity(level))))
                    .frame(width: 9, height: 9).accessibilityHidden(true)
            }
            Text("usage.replica.more".localized())
        }.font(.system(size: 9)).foregroundStyle(.secondary)
    }
    private func opacity(_ level: Int) -> Double { level == 0 ? 0 : min(0.98, Double(level) * 0.18 + (colorScheme == .dark ? 0.26 : 0.20)) }
    private func weekday(_ row: Int) -> String {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        return symbols[(row + 1) % 7]
    }
    private func monthLabel(_ week: UsageHeatmapPresentation.Week) -> String {
        let day = week.days[0].date
        // 首列若临近月底省略标签，避免它与下一月标签重叠。
        let number = Calendar.current.component(.day, from: day)
        guard number <= 7 else { return "" }
        return day.formatted(.dateTime.month(.abbreviated))
    }
}

/// 点击弹层和悬浮层复用自然日内容；不从日格反推精确时间窗口的用量。
struct UsageHeatmapDetail: View {
    @Environment(\.colorScheme) private var colorScheme
    let day: UsageHeatmapPresentation.Day
    let title: String
    let accent: Color
    var metric: CPAUsageChartMetric = .tokens

    static func formattedValue(_ totals: UsageTotals, cost: CPAUsageCostEstimate, metric: CPAUsageChartMetric) -> String {
        switch metric {
        case .tokens: totals.totalTokens.formatted() + " " + "usage.tokens".localized()
        case .requests: totals.requests.formatted() + " " + "usage.cpa.requests.unit".localized()
        case .cost: cost.formatted
        }
    }

    static func accessibilityValue(_ day: UsageHeatmapPresentation.Day, metric: CPAUsageChartMetric) -> String {
        if day.isBeforeCollection { return "usage.replica.beforeCollection".localized() }
        if metric == .cost {
            let amount = day.cost.amount == nil ? "usage.records.unknown".localized() : day.cost.formatted
            return "usage.pricing.estimated".localized() + ": " + amount + ". " + "usage.analytics.calendarDay".localized()
        }
        return formattedValue(day.totals, cost: day.cost, metric: metric) + ". " + "usage.analytics.calendarDay".localized()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).foregroundStyle(accent); Spacer(); Text(day.date, format: .dateTime.month().day().weekday()) }
                .font(.caption.weight(.semibold))
            Text(day.isBeforeCollection ? "—" : Self.formattedValue(day.totals, cost: day.cost, metric: metric))
                .font(.title3.weight(.bold)).monospacedDigit()
                .accessibilityLabel(Self.accessibilityValue(day, metric: metric))
            Text("usage.analytics.calendarDay".localized())
                .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            if metric == .cost, day.cost.isPartial {
                Text("usage.pricing.partialNotice".localized()).font(.caption2).foregroundStyle(.secondary)
            }
            if day.isBeforeCollection {
                Text("usage.replica.beforeCollection".localized()).font(.caption).foregroundStyle(.secondary)
            } else if day.models.isEmpty || (metric == .requests && day.totals.requests == 0) {
                Text((metric == .tokens ? "usage.replica.noCollectedTokens" : "usage.replica.noCollectedRequests").localized())
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(day.models) { model in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top) {
                                    Text(model.model).font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    let estimate = day.modelCosts[model.id] ?? CPAUsageCostEstimate()
                                    Text(metric == .tokens ? model.totals.totalTokens.formatted()
                                         : Self.formattedValue(model.totals, cost: estimate, metric: metric))
                                        .font(.caption).monospacedDigit()
                                }
                                if metric == .tokens {
                                    Text(detailLine("usage.inputTokens", model.totals.inputTokens, "usage.outputTokens", model.totals.outputTokens))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(detailLine("usage.cachedTokens", model.totals.cachedTokens, "usage.reasoningTokens", model.totals.reasoningTokens))
                                        .font(.caption2).foregroundStyle(.secondary)
                                } else if metric == .requests {
                                    Text(requestDetailLine(model))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 180)
                .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous))
            }
        }
        .monospacedDigit()
        .textSelection(.enabled)
    }

    private func requestDetailLine(_ model: UsageStatisticsModel) -> String {
        let share = day.totals.requests > 0
            ? (Double(model.totals.requests) / Double(day.totals.requests)).formatted(.percent.precision(.fractionLength(1)))
            : "0%"
        var parts = [
            "usage.replica.share".localized(), share,
            "·", "usage.tokens".localized(), model.totals.totalTokens.formattedCompact
        ]
        if model.totals.failures > 0 {
            parts += ["·", "usage.records.outcome.failed".localized(), model.totals.failures.formatted()]
        }
        return parts.joined(separator: " ")
    }

    /// 先构造普通字符串，避免多次 Text/String 加法让 SwiftUI 泛型表达式类型检查膨胀。
    private func detailLine(_ leftKey: String, _ left: Int, _ rightKey: String, _ right: Int) -> String {
        [leftKey.localized(), left.formatted(), "·", rightKey.localized(), right.formatted()].joined(separator: " ")
    }
}

/// 悬浮状态只在根层浮窗内读取，避免鼠标跨格时重新聚合全年账本和重绘下面所有图表。
@MainActor @Observable
final class UsageHeatmapHoverState {
    var selection: UsageHeatmapHover?
}

struct UsageHeatmapOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    let state: UsageHeatmapHoverState
    let viewportSize: CGSize
    var body: some View {
        if let hover = state.selection {
            UsageHeatmapDetail(day: hover.day, title: hover.title, accent: hover.accent, metric: hover.metric)
                .padding(14).frame(width: min(360, max(240, viewportSize.width - 24)))
                .background(AnalyticsSurface.floatingPanel(colorScheme), in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous))
                .shadow(color: AnalyticsShadow.floatingPanel(colorScheme), radius: 12, y: 5)
                .offset(x: min(max(12, hover.anchor.midX - 180), max(12, viewportSize.width - 372)),
                        y: min(max(12, hover.anchor.maxY + 10), max(12, viewportSize.height - 320)))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
