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
    @State private var selectedDate: Date?

    private var selectedDay: UsageStatisticsDay? {
        guard let selectedDate else { return nil }
        return days.min { abs($0.day.timeIntervalSince(selectedDate)) < abs($1.day.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("usage.dailyTrend".localized(), systemImage: "chart.xyaxis.line")
                    .font(.headline.weight(.bold))
                Spacer()
                Text("usage.tokens".localized()).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(days) { day in
                    AreaMark(x: .value("usage.day".localized(), day.day),
                             y: .value("usage.tokens".localized(), day.totals.totalTokens))
                        .foregroundStyle(LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("usage.day".localized(), day.day),
                             y: .value("usage.tokens".localized(), day.totals.totalTokens))
                        .foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("usage.day".localized(), day.day),
                              y: .value("usage.tokens".localized(), day.totals.totalTokens))
                        .foregroundStyle(accent).symbolSize(days.count < 32 ? 20 : 5)
                        .accessibilityLabel(day.day.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(day.totals.totalTokens.formatted())
                }
                if let selectedDay {
                    RuleMark(x: .value("usage.day".localized(), selectedDay.day))
                        .foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(dash: [4]))
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                // ChartProxy 的 x 坐标相对绘图区，不包含左侧坐标轴留白。
                                // 仅在真实绘图区内显示悬停值，离开图表或移入坐标轴立即清除。
                                guard let anchor = proxy.plotFrame else { selectedDate = nil; return }
                                let plot = geometry[anchor]
                                guard plot.contains(location) else { selectedDate = nil; return }
                                selectedDate = proxy.value(atX: location.x - plot.minX, as: Date.self)
                            case .ended:
                                selectedDate = nil
                            }
                        }
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 7)) }
            .frame(height: 220)
            HStack {
                if let selectedDay {
                    Text(selectedDay.day, format: .dateTime.year().month().day())
                    Spacer()
                    Text(selectedDay.totals.totalTokens.formatted() + " Tokens").monospacedDigit()
                } else {
                    Text("usage.replica.hoverHint".localized()).foregroundStyle(.secondary)
                }
            }
            .font(.caption).frame(height: 18)
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
