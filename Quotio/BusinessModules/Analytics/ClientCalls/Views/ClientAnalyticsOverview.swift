import SwiftUI

/// 客户端 Token 与工具调用共用一张概览卡片、一个网格。两份账本的统计口径与
/// 可用性保持独立：一方未读到数据不能使另一方失效，也不能把未知计为零。
struct ClientAnalyticsOverview: View {
    let client: ClientUsageViewModel.Presentation?
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
        var items: [Metric] = []
        if let client {
            let totals = client.statistics.totals
            let values = [("usage.tokens", totals.totalTokens, "bolt.fill"),
                          ("usage.cachedTokens", totals.cachedTokens, "scope"),
                          ("usage.inputTokens", totals.inputTokens, "arrow.down.doc.fill"),
                          ("usage.outputTokens", totals.outputTokens, "arrow.up.doc.fill"),
                          ("usage.reasoningTokens", totals.reasoningTokens, "brain")]
            items += values.map { key, number, icon in
                let known = client.available && !(key == "usage.reasoningTokens" && client.lacksReasoning)
                return Metric(id: key, number: known ? number : nil, icon: icon,
                              tint: UsageStatisticsPalette.metric(key), compact: true,
                              prominent: key == "usage.tokens")
            }
            items.append(Metric(id: "usage.replica.modelCount",
                                number: client.available ? client.statistics.models.count : nil,
                                icon: "cpu", tint: UsageStatisticsPalette.metric("usage.replica.modelCount")))
        }
        let known = calls.report.canDisplayTotals
        items += [Metric(id: "callReplica.total", number: known ? calls.report.totalCalls : nil,
                         icon: "wrench.and.screwdriver", tint: .indigo, prominent: true),
                  Metric(id: "callReplica.mcpCalls", number: known ? calls.mcpCalls : nil,
                         icon: "puzzlepiece.extension", tint: .purple),
                  Metric(id: "callReplica.skillCalls", number: known ? calls.skillCalls : nil,
                         icon: "sparkles", tint: .pink),
                  Metric(id: "callReplica.activeMCP", number: known ? calls.activeServers : nil,
                         icon: "server.rack", tint: .blue),
                  Metric(id: "callReplica.unusedSkills",
                         number: known && !calls.report.hasReadFailures ? calls.unusedSkills : nil,
                         icon: "moon.zzz", tint: .orange)]
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("clientAnalytics.overview.title".localized(), systemImage: "chart.bar.xaxis")
                .font(.headline)
            // 11 项连续排列，常规宽度为 4＋4＋3；窄窗自动减列。显式允许末行空位，
            // 避免共享布局为追求整行排满，将质数 11 个指标退化成一列。
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
