// Copyright 2026 AIUsage contributors. Licensed under Apache-2.0.
// 客户端调用每日趋势卡片：仅展示每日工具调用次数柱状图、悬停读数及可折叠逐日明细，
// 已按用户要求彻底移除本地会话 Token 折线图及 Token 明细列。
import SwiftUI
import Charts

/// 单层卡片承载工具调用每日柱状趋势。
/// 悬停状态仅由覆盖层与读数观察，鼠标移动不会重新聚合账本或构造整页图表。
struct ClientAnalyticsDailyTrend: View {
    let data: ClientAnalyticsDailyTrendData
    let subtitle: String
    let accent: Color
    @State private var hoverState = UsageTrendHoverState()
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("usage.dailyTrend".localized(), systemImage: "chart.bar.xaxis").font(.headline)
                Spacer()
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            plotSection(.tools, height: 140)
            ClientAnalyticsTrendReadout(data: data, state: hoverState)
            ClientAnalyticsTrendDetailsDisclosure(days: data.days, isExpanded: $detailsExpanded)
        }
        .quotioCard()
        .accessibilityIdentifier("clientDailyTrend")
        .onChange(of: data) { _, _ in hoverState.select(nil) }
        .onDisappear { hoverState.select(nil) }
    }

    private func plotSection(_ metric: ClientAnalyticsDailyTrendData.Metric, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(metric.titleKey.localized()).font(.caption.weight(.semibold))
                Spacer()
                Text("clientAnalytics.trend.toolsUnit".localized())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if data.available(metric) {
                ClientAnalyticsTrendPlot(data: data, metric: metric, accent: accent, state: hoverState)
                    .equatable().frame(height: height)
            } else {
                Text("usage.metric.unavailable".localized()).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            }
        }
    }
}

/// 展开状态由卡片持有，日期／来源变化不销毁用户已展开的明细。
/// 原生 DisclosureGroup 的鼠标、键盘和辅助功能动作均写入同一 Binding。
struct ClientAnalyticsTrendDetailsDisclosure: View {
    let days: [ClientAnalyticsDailyTrendData.Day]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup("usage.dailyDetails".localized(), isExpanded: $isExpanded) {
            ClientAnalyticsTrendDetails(days: days).padding(.top, 8)
        }
        .accessibilityIdentifier("clientDailyTrendDetails")
    }
}

/// 连续日期 domain、均匀日期刻度和固定宽度的纵轴标签，确保不同日期区间下柱体对齐稳定。
struct ClientAnalyticsTrendPlot: View, Equatable {
    let data: ClientAnalyticsDailyTrendData
    let metric: ClientAnalyticsDailyTrendData.Metric
    let accent: Color
    let state: UsageTrendHoverState
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data == rhs.data && lhs.metric == rhs.metric && lhs.accent == rhs.accent && lhs.state === rhs.state
    }

    var body: some View {
        let points = data.plottedDays(metric)
        let axisColor: Color = colorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.6)
        // 全部历史跨年时保留年份，避免同样的月／日刻度对应不同年份而无法区分。
        let dateFormat: Date.FormatStyle = data.spansYears
            ? .dateTime.year(.twoDigits).month(.twoDigits).day(.twoDigits)
            : .dateTime.month(.twoDigits).day(.twoDigits)
        Chart(points) { day in
            // 显式给出以该日零点为中心的左右边界及从零起的上下边界。
            // 日期分箱会默认移到中午，而 xStart／xEnd／y 的 BarMark 表示水平区间；
            // RectangleMark 四边界才能同时保证日期对齐和真实的竖向柱高。
            RectangleMark(xStart: .value("usage.day".localized(), day.barStart),
                    xEnd: .value("usage.day".localized(), day.barEnd),
                    yStart: .value(metric.titleKey.localized(), 0),
                    yEnd: .value(metric.titleKey.localized(), day.tools ?? 0))
                .foregroundStyle(accent.opacity(0.7)).cornerRadius(2)
                .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                .accessibilityValue((day.tools ?? 0).formatted())
        }
        .chartXScale(domain: data.domain)
        .chartYScale(domain: 0...data.maximum(metric))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(axisColor.opacity(0.15))
                AxisValueLabel {
                    Text(value.as(Int.self)?.formattedCompact ?? "")
                        .font(.caption2).foregroundStyle(axisColor)
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: data.axisDates) {
                AxisGridLine().foregroundStyle(axisColor.opacity(0.12))
                AxisValueLabel(format: dateFormat)
                    .font(.caption2).foregroundStyle(axisColor)
            }
        }
        .chartOverlay { proxy in
            ClientAnalyticsTrendHoverLayer(data: data, state: state, proxy: proxy)
        }
        .transaction { $0.animation = nil }
        .accessibilityIdentifier("clientDailyTrendPlot-" + metric.rawValue)
    }
}

/// 鼠标和点击均通过真实绘图区坐标命中完整日明细；
/// 提示线在覆盖层绘制，不把动态 RuleMark 插入图表而引发重复坐标布局。
private struct ClientAnalyticsTrendHoverLayer: View {
    let data: ClientAnalyticsDailyTrendData
    let state: UsageTrendHoverState
    let proxy: ChartProxy

    var body: some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plot = geometry[anchor]
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): select(at: location, plot: plot)
                            case .ended: state.select(nil)
                            }
                        }
                        .onTapGesture { location in select(at: location, plot: plot) }
                    if let date = state.date, let x = proxy.position(forX: date), x >= 0, x <= plot.width {
                        Path { path in
                            path.move(to: CGPoint(x: plot.minX + x, y: plot.minY))
                            path.addLine(to: CGPoint(x: plot.minX + x, y: plot.maxY))
                        }
                        .stroke(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4]))
                        .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func select(at location: CGPoint, plot: CGRect) {
        guard plot.contains(location), let date = proxy.value(atX: location.x - plot.minX, as: Date.self) else {
            state.select(nil); return
        }
        state.select(data.nearest(to: date)?.date)
    }
}

/// 单日完整读数仅展示工具调用次数；未知保留占位，不使用图表抽样点替代事实。
struct ClientAnalyticsTrendReadout: View {
    let data: ClientAnalyticsDailyTrendData
    let state: UsageTrendHoverState

    var body: some View {
        HStack(spacing: 12) {
            if let date = state.date, let day = data.nearest(to: date) {
                Text(day.date, format: .dateTime.year().month().day())
                Spacer(minLength: 4)
                Text(String(format: "clientAnalytics.trend.toolsReadout".localized(), day.tools?.formatted() ?? "—"))
            } else {
                Text("clientAnalytics.trend.hoverHint".localized()).foregroundStyle(.secondary)
            }
        }
        .font(.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        .frame(minHeight: 18).accessibilityElement(children: .combine)
        .accessibilityIdentifier("clientDailyTrendReadout")
    }
}

/// 折叠明细仅展示日期与工具调用次数；LazyVStack 保留长历史逐日访问能力，
/// 展开前不创建成千上万行，展示不改变已有来源与日期筛选。
struct ClientAnalyticsTrendDetails: View {
    let days: [ClientAnalyticsDailyTrendData.Day]

    var body: some View {
        LazyVStack(spacing: 8) {
            HStack {
                Text("usage.day".localized()).frame(maxWidth: .infinity, alignment: .leading)
                Text("clientAnalytics.trend.tools".localized()).frame(maxWidth: .infinity, alignment: .trailing)
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(days) { day in
                HStack {
                    Text(day.date, format: .dateTime.year().month().day())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(day.tools?.formatted() ?? "—").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
