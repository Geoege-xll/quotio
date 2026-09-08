import SwiftUI

/// 总览统一为一张结构卡：四个主指标使用内嵌表面，十三项次级指标按语义轻量分组常显。
/// 颜色只用于主指标图标，数字使用系统主文本色；筛选与未知值口径由纯展示模型统一处理。
struct CPAUsageOverviewSection: View {
    let metrics: CPAUsageEventMetrics
    var totalAccounts: Int = 0
    var readyAccounts: Int = 0
    var isIncomplete = false
    var historicalRequests = 0

    var body: some View {
        let presentation = CPAUsageOverviewPresentation(metrics: metrics, isIncomplete: isIncomplete)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("usage.dashboard.overview".localized())
                    .font(.headline).accessibilityAddTraits(.isHeader)
                Text(String(format: "usage.cpa.accounts".localized(), totalAccounts, readyAccounts))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }

            // 主指标优先四等分；降低原 145pt 的列宽门槛，让默认窗口能够一行展示四张卡。
            // 宽度不足仍沿用共享布局的两列／单列回退，卡片文字、数值和紧凑处理保持原样。
            CPAUsageAdaptiveGrid(maximumColumns: 4, minimumColumnWidth: 120) {
                CPAUsageOverviewMetric(metric: presentation.requests, icon: "network", tint: .blue)
                CPAUsageOverviewMetric(metric: presentation.tokens, icon: "number", tint: .purple)
                CPAUsageOverviewMetric(metric: presentation.successRate, icon: "checkmark.seal", tint: .green)
                CPAUsageOverviewMetric(metric: presentation.latency, icon: "clock", tint: .orange)
            }

            CPAUsageOverviewDetails(presentation: presentation)

            // 指标不再藏在「更多」浮层中，计算口径也随结果保持可见；缺失信号仍由文字说明。
            Text("usage.records.metricRules".localized())
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if historicalRequests > 0 || isIncomplete {
                CPAUsageCoverageSummary(historicalRequests: historicalRequests, isIncomplete: isIncomplete)
            }
        }
        .quotioCard()
    }

}

/// 主要指标共享内嵌表面、字号和数字基线；精确值可复制、悬停查看或由 VoiceOver 朗读。
private struct CPAUsageOverviewMetric: View {
    let metric: CPAUsageOverviewPresentation.Metric
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(metric.titleKey.localized()).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            .font(.caption.weight(.medium)).lineLimit(1)
            Text(metric.value)
                .font(.title2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.75)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .quotioInsetCard(padding: 14)
        .help(metric.exactValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.titleKey.localized()).accessibilityValue(metric.exactValue)
    }
}

/// 次级指标共享一个轻量底面，按四组紧凑清单排布；组内名称和值同行，避免空值占据大块高度。
/// 默认窗口四列，宽度不足时两列，极窄时单列；沿用现有 Layout 测量，不增加几何状态或查询计算。
struct CPAUsageOverviewDetails: View {
    let presentation: CPAUsageOverviewPresentation

    var body: some View {
        // 次级底面还有左右各 12pt 内边距：原 135pt 列宽要求外层至少 612pt，默认约 560pt 会退成两列。
        // 改为 120pt 后，外层达到 552pt 即可四等分；更窄时仍按原布局换行，不改组内文字和数值处理。
        CPAUsageAdaptiveGrid(maximumColumns: 4, minimumColumnWidth: 120, spacing: 16) {
            CPAUsageOverviewGroup(titleKey: "usage.dashboard.tokenUsage",
                metrics: Array(presentation.tokenAndCache.prefix(3)))
            CPAUsageOverviewGroup(titleKey: "usage.dashboard.cache",
                metrics: Array(presentation.tokenAndCache.dropFirst(3)))
            CPAUsageOverviewGroup(titleKey: "usage.dashboard.performance", metrics: presentation.performance)
            CPAUsageOverviewGroup(titleKey: "usage.dashboard.requestOutcomes", metrics: presentation.requestOutcomes)
        }
        .quotioInsetCard(padding: 12)
    }
}

/// 每个分组保持统一的标题和行距。Token 与缓存拆成两个语义组，让四组都有三至四行，减少空列。
private struct CPAUsageOverviewGroup: View {
    let titleKey: String
    let metrics: [CPAUsageOverviewPresentation.Metric]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titleKey.localized())
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(metrics) { CPAUsageOverviewDetail(metric: $0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct CPAUsageOverviewDetail: View {
    let metric: CPAUsageOverviewPresentation.Metric

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(compactTitle).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 0)
            Text(metric.value).font(.callout.weight(.medium)).monospacedDigit()
                // 缺失仍显示破折号，但不再与已知数值拥有相同的视觉权重；不把未知值转换成零。
                .foregroundStyle(metric.value == "—" ? .secondary : .primary)
                .lineLimit(1).minimumScaleFactor(0.8).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(metric.titleKey.localized() + " · " + metric.exactValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.titleKey.localized()).accessibilityValue(metric.exactValue)
    }

    /// 分组已说明单位和含义，行标签只保留必要文字；完整统计名称仍用于帮助与 VoiceOver。
    /// 性能缩写沿用领域通用写法，数值中的 ms、t/s 和百分号保持原统计展示口径。
    private var compactTitle: String {
        switch metric.titleKey {
        case "usage.inputTokens": "usage.dashboard.inputShort".localized()
        case "usage.outputTokens": "usage.dashboard.outputShort".localized()
        case "usage.reasoningTokens": "usage.dashboard.reasoningShort".localized()
        case "usage.records.cacheRead": "usage.dashboard.cacheReadShort".localized()
        case "usage.records.cacheWrite": "usage.dashboard.cacheWriteShort".localized()
        case "usage.records.cacheRate": "usage.dashboard.cacheRateShort".localized()
        case "usage.records.ttft": "TTFT"
        case "usage.records.tps": "TPS"
        case "usage.records.rpm": "RPM"
        case "usage.records.tpm": "TPM"
        default: metric.titleKey.localized()
        }
    }
}

/// 覆盖范围保留可见摘要，长说明移入原生浮层，避免说明段落抢在总览数字之前。
/// 覆盖不完整始终通过文字提示，不依赖颜色，也不隐藏原有详细统计边界。
private struct CPAUsageCoverageSummary: View {
    let historicalRequests: Int
    let isIncomplete: Bool
    @State private var showsDetails = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label {
                Text(isIncomplete ? "usage.dashboard.partialCoverage".localized()
                     : String(format: "usage.dashboard.historySummary".localized(), historicalRequests.formatted()))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: isIncomplete ? "exclamationmark.circle" : "calendar")
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 0)
            Button("usage.dashboard.coverageDetails".localized()) { showsDetails = true }
                .buttonStyle(.borderless).font(.caption).fixedSize()
                .popover(isPresented: $showsDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("usage.dashboard.coverageDetails".localized()).font(.headline)
                        if historicalRequests > 0 {
                            Text(String(format: "usage.dashboard.historyIncluded".localized(), historicalRequests.formatted()))
                        }
                        if isIncomplete { Text("usage.dashboard.historyIncomplete".localized()) }
                    }
                    .font(.callout).padding(20).frame(width: 360, alignment: .leading)
                }
        }
    }
}
