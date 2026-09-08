// Copyright 2026 AIUsage contributors. Licensed under Apache-2.0.
// 参考 ProxyStatsView 的摘要与分布布局（bdb83bbe）；修改为客户端 Token 口径并补足完整分布与无障碍读取。
import SwiftUI
import Charts

/// 按参考项目的紧凑彩色摘要条展示 Token 数据；费用不进入该页面。
/// 客户端计数归一化后，缓存 Token 已属于输入子集，只显示原始计数，不构造不可靠的「缓存命中率」。
struct UsageStatisticsSummary: View {
    let totals: UsageTotals
    let available: Bool
    var modelCount: Int? = nil
    /// 未报告的指标显示占位符，不把缺失的 Pi 思考明细当作零。
    var unavailableMetrics: Set<String> = []

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            metric("usage.tokens", number: totals.totalTokens, icon: "bolt.fill", tint: UsageStatisticsPalette.metric("usage.tokens"))
            metric("usage.cachedTokens", number: totals.cachedTokens, icon: "scope", tint: UsageStatisticsPalette.metric("usage.cachedTokens"))
            metric("usage.inputTokens", number: totals.inputTokens, icon: "arrow.down.doc.fill", tint: UsageStatisticsPalette.metric("usage.inputTokens"))
            metric("usage.outputTokens", number: totals.outputTokens, icon: "arrow.up.doc.fill", tint: UsageStatisticsPalette.metric("usage.outputTokens"))
            metric("usage.reasoningTokens", number: totals.reasoningTokens, icon: "brain", tint: UsageStatisticsPalette.metric("usage.reasoningTokens"))
            cell("usage.replica.modelCount", value: available ? modelCount.map { $0.formatted() } ?? "—" : "—", icon: "cpu", tint: UsageStatisticsPalette.metric("usage.replica.modelCount"))
        }
    }

    private func metric(_ key: String, number: Int, icon: String, tint: Color) -> some View {
        cell(key, value: available && !unavailableMetrics.contains(key) ? number.formattedCompact : "—", icon: icon, tint: tint)
            .help(available && !unavailableMetrics.contains(key) ? number.formatted() : "usage.metric.unavailable".localized())
            .accessibilityLabel(key.localized())
            .accessibilityValue(available && !unavailableMetrics.contains(key) ? number.formatted() : "usage.metric.unavailable".localized())
    }

    private func cell(_ key: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: Capsule())
            VStack(alignment: .leading, spacing: 1) {
                Text(key.localized()).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .modifier(UsageAnalyticsSurface(radius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// 日趋势与顶部筛选口径一致，只展示 Token。悬停读数和逐日明细共享相同数据，
/// 无障碍用户不需要操作鼠标也能读取完整日期及数值。
struct UsageStatisticsTrend: View {
    let days: [UsageStatisticsDay]
    var accent: Color = QuotioTheme.Colors.info
    @State private var hoverState = UsageTrendHoverState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("usage.dailyTrend".localized(), systemImage: "chart.xyaxis.line")
                    .font(.headline.weight(.bold))
                Spacer()
                Text("usage.tokens".localized()).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            // 图表只依赖真实数据与色彩。鼠标状态由独立覆盖层和读数行观察，
            // 不向 ChartContent 动态插入 RuleMark，也不同时使用系统选择与鼠标两条写入路径。
            UsageStatisticsTrendPlot(days: days, accent: accent, hoverState: hoverState)
                .equatable()
                .frame(height: 220)
            UsageTrendReadout(days: days, state: hoverState)
            DisclosureGroup("usage.dailyDetails".localized()) {
                LazyVStack(spacing: 8) {
                    ForEach(days) { day in
                        HStack {
                            Text(day.day, format: .dateTime.year().month().day())
                            Spacer()
                            Text(day.totals.totalTokens.formatted()).monospacedDigit()
                        }
                        .font(.callout).accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(UsageAnalyticsSurface())
    }
}

/// 独立的悬停状态仅在命中日期改变时发布；图表、坐标轴和页面均不读取它的选中值。
@MainActor @Observable
final class UsageTrendHoverState {
    private(set) var date: Date?

    func select(_ date: Date?) {
        guard self.date != date else { return }
        self.date = date
    }
}

/// 用值语义比较隔离采集进度与父页面刷新，避免没有数据变化时重新创建 Chart 的布局图。
struct UsageStatisticsTrendPlot: View, Equatable {
    let days: [UsageStatisticsDay]
    let accent: Color
    let hoverState: UsageTrendHoverState

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.days == rhs.days && lhs.accent == rhs.accent && lhs.hoverState === rhs.hoverState
    }

    var body: some View {
        let points = UsageTrendPlotData.sampled(days)
        let maximum = max(1, points.map { $0.totals.totalTokens }.max() ?? 0)
        Chart(points) { day in
            AreaMark(x: .value("usage.day".localized(), day.day), y: .value("usage.tokens".localized(), day.totals.totalTokens))
                .foregroundStyle(LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("usage.day".localized(), day.day), y: .value("usage.tokens".localized(), day.totals.totalTokens))
                .foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 2))
                .symbol(.circle).symbolSize(points.count < 32 ? 20 : 0)
                .accessibilityLabel(day.day.formatted(date: .abbreviated, time: .omitted))
                .accessibilityValue(day.totals.totalTokens.formatted())
        }
        .chartYScale(domain: 0...maximum)
        .chartYAxis { AxisMarks(position: .leading) }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 7)) }
        .chartOverlay { proxy in
            UsageTrendHoverLayer(days: days, state: hoverState, proxy: proxy)
        }
        // 过滤和模型行展开的祖先动画不能重新插值图表锚点；提示线在覆盖层单独绘制。
        .transaction { $0.animation = nil }
        .onChange(of: days) { _, _ in hoverState.select(nil) }
        .onDisappear { hoverState.select(nil) }
    }
}

/// 只在覆盖层解析绘图区坐标，悬停线不参与图表标记、坐标域或锚点的尺寸测量。
private struct UsageTrendHoverLayer: View {
    let days: [UsageStatisticsDay]
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
            state.select(nil)
            return
        }
        state.select(UsageTrendPlotData.nearest(to: date, in: days)?.day)
    }
}

/// 读数使用完整日明细，不用抽样值代替某一天的真实用量；该行更新不重建图表。
private struct UsageTrendReadout: View {
    let days: [UsageStatisticsDay]
    let state: UsageTrendHoverState

    var body: some View {
        HStack {
            if let date = state.date, let selectedDay = UsageTrendPlotData.nearest(to: date, in: days) {
                Text(selectedDay.day, format: .dateTime.year().month().day())
                Spacer()
                Text(selectedDay.totals.totalTokens.formatted() + " Tokens").monospacedDigit()
            } else {
                Text("usage.replica.hoverHint".localized()).foregroundStyle(.secondary)
            }
        }
        .font(.caption).frame(height: 18)
    }
}

/// 本地卡片沿用共享的 AIUsage 表面色阶，仅保留摘要与分布所需的不同圆角。
struct UsageAnalyticsSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .quotioCard(cornerRadius: radius, padding: 0)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

/// 统计页统一的语义色映射：来源色只表达客户端，指标色只表达 Token 类型。
/// 不将来源色散列到模型名，也不让切换时间范围改变同一来源的视觉身份。
enum UsageStatisticsPalette {
    static func source(_ title: String?, scheme: ColorScheme) -> Color {
        switch title?.lowercased() {
        case "claude", "claude code": return QuotioTheme.Colors.claudeUsage(for: scheme)
        case "codex": return QuotioTheme.Colors.codexGreen
        case "opencode", "open code": return QuotioTheme.Colors.opencodeBlue
        case "pi": return CLIAgent.pi.color
        default: return QuotioTheme.Colors.info
        }
    }

    static func metric(_ key: String) -> Color {
        switch key {
        case "usage.inputTokens": return QuotioTheme.Colors.opencodeBlue
        case "usage.outputTokens": return QuotioTheme.Colors.codexGreen
        case "usage.cachedTokens": return QuotioTheme.Colors.warning
        case "usage.reasoningTokens": return QuotioTheme.Colors.claudeOrange
        default: return QuotioTheme.Colors.info
        }
    }
}
