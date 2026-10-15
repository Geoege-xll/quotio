// Copyright 2026 AIUsage contributors. Licensed under Apache-2.0.
// 参考 ProxyStatsView 的摘要与分布布局（bdb83bbe）；修改为客户端 Token 口径并补足完整分布与无障碍读取。
import SwiftUI

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

/// 独立的悬停状态仅在命中日期改变时发布；图表、坐标轴和页面均不读取它的选中值。
@MainActor @Observable
final class UsageTrendHoverState {
    private(set) var date: Date?

    func select(_ date: Date?) {
        guard self.date != date else { return }
        self.date = date
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
