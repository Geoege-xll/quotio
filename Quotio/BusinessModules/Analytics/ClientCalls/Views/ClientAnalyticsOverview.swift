import SwiftUI

/// 客户端调用概览卡片：聚焦总调用数、MCP 调用、技能调用与活跃 MCP 四项核心指标，
/// 已按用户要求彻底移除本地会话 Token、模型数量及未调用技能数统计。
/// 来源未读到或读取失败时保留未知占位（—），不把未知推断为零。
struct ClientAnalyticsOverview: View {
    let calls: CallReplicaDerived

    /// 稳定 ID 使用已有指标键，来源／日期刷新只更新值，不按数值重排网格。
    /// number 为 nil 时保留未知；0 是合法事实，仍按数字显示。
    struct Metric: Identifiable {
        let id: String
        let number: Int?
        let icon: String
        let tint: Color
        var compact = false
        var prominent = false

        var value: String {
            number.map { compact ? $0.formattedCompact : $0.formatted() } ?? "—"
        }
        var fullValue: String { number?.formatted() ?? "usage.metric.unavailable".localized() }
    }

    var metrics: [Metric] {
        let known = calls.report.canDisplayTotals
        return [
            Metric(id: "callReplica.total", number: known ? calls.report.totalCalls : nil,
                   icon: "wrench.and.screwdriver", tint: .indigo, prominent: true),
            Metric(id: "callReplica.mcpCalls", number: known ? calls.mcpCalls : nil,
                   icon: "puzzlepiece.extension", tint: .purple),
            Metric(id: "callReplica.skillCalls", number: known ? calls.skillCalls : nil,
                   icon: "sparkles", tint: .pink),
            Metric(id: "callReplica.activeMCP", number: known ? calls.activeServers : nil,
                   icon: "server.rack", tint: .blue)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("clientAnalytics.overview.title".localized(), systemImage: "chart.bar.xaxis")
                .font(.headline)
            // 四项工具调用指标单行自适应排列；窄窗自动减列并允许末行不铺满。
            CPAUsageAdaptiveGrid(maximumColumns: 4, minimumColumnWidth: 140, spacing: 12,
                                 allowsIncompleteLastRow: true) {
                ForEach(metrics) { metric in metricCell(metric) }
            }
        }
        .quotioCard()
        .accessibilityIdentifier("clientAnalyticsOverview")
    }

    private func metricCell(_ metric: Metric) -> some View {
        HStack(spacing: 8) {
            Image(systemName: metric.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(metric.tint)
                .frame(width: 26, height: 26)
                .background(metric.tint.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(metric.id.localized())
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(metric.value)
                    .font(.system(size: 17, weight: metric.prominent ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(metric.prominent ? metric.tint : Color.primary)
                    .lineLimit(1).minimumScaleFactor(0.85).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        // 每项只用网格间距区分，取消旧的独立卡片、背景和阴影；整组只有一层表面。
        .help(metric.fullValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.id.localized())
        .accessibilityValue(metric.fullValue)
        .accessibilityIdentifier("clientAnalyticsOverview-" + metric.id)
    }
}
