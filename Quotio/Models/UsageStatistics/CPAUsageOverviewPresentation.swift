import Foundation

/// 总览的纯展示值：只格式化共享查询已算出的指标，不读取队列、重新聚合事件或改动筛选状态。
/// 将覆盖判断集中在这里，确保主卡与常显次级指标使用同一套「确定值／已知下界／未知」语义。
nonisolated struct CPAUsageOverviewPresentation {
    nonisolated struct Metric: Identifiable {
        let titleKey: String
        let value: String
        /// 大数在卡片中使用紧凑写法；悬停和无障碍仍提供完整数字及相同的覆盖标记。
        let exactValue: String
        var id: String { titleKey }
    }

    let requests: Metric
    let tokens: Metric
    let successRate: Metric
    let latency: Metric
    let tokenAndCache: [Metric]
    let performance: [Metric]
    let requestOutcomes: [Metric]

    init(metrics: CPAUsageEventMetrics, isIncomplete: Bool) {
        func unavailable(_ key: String) -> Metric { Metric(titleKey: key, value: "—", exactValue: "—") }

        func count(_ key: String, _ value: Int, compact: Bool = false) -> Metric {
            // 精确筛选可能排除无法定位的日归档；可加总指标只代表已确认部分。
            // 已知子集为零不能证明总数为零，保留未知；正值则明确标成下界。
            guard !isIncomplete || value > 0 else { return unavailable(key) }
            let prefix = isIncomplete ? "≥ " : ""
            return Metric(titleKey: key, value: prefix + (compact ? value.formattedCompact : value.formatted()),
                          exactValue: prefix + value.formatted())
        }

        func decimal(_ key: String, _ value: Double?, suffix: String = "") -> Metric {
            guard let value, value.isFinite else { return unavailable(key) }
            let text = String(format: "%.1f", value) + suffix
            return Metric(titleKey: key, value: text, exactValue: text)
        }

        func cache(_ key: String, value: Int, samples: Int) -> Metric {
            // 旧日汇总没有缓存读写拆分。只有全部已纳入请求都报告了该分量，才能展示数值。
            // 若另外存在未能纳入的历史，完整的已知分量也仍然只能作为总体下界。
            guard metrics.requests > 0, samples == metrics.requests else { return unavailable(key) }
            return count(key, value, compact: true)
        }

        requests = count("usage.cpa.requests", metrics.requests)
        tokens = count("usage.tokens", metrics.tokens, compact: true)
        successRate = decimal("usage.records.successRate", isIncomplete ? nil : metrics.successRate, suffix: "%")
        // 平均值只使用已报告的样本，保留既有统计口径；平均值不能当作全体平均值的下界。
        latency = decimal("usage.cpa.latency", metrics.latency, suffix: " ms")

        tokenAndCache = [
            count("usage.inputTokens", metrics.input, compact: true),
            count("usage.outputTokens", metrics.output, compact: true),
            count("usage.reasoningTokens", metrics.reasoning, compact: true),
            cache("usage.records.cacheRead", value: metrics.cacheRead, samples: metrics.cacheReadSamples),
            cache("usage.records.cacheWrite", value: metrics.cacheWrite, samples: metrics.cacheWriteSamples),
            // 分子和分母都可能缺失时，比率没有可证明的上下界；不能只计算已知子集后当作全体。
            decimal("usage.records.cacheRate", isIncomplete ? nil : metrics.cacheReadRate, suffix: "%")
        ]
        performance = [
            decimal("usage.records.ttft", metrics.ttft, suffix: " ms"),
            decimal("usage.records.tps", metrics.tps, suffix: " t/s"),
            decimal("usage.records.rpm", isIncomplete ? nil : metrics.rpm),
            decimal("usage.records.tpm", isIncomplete ? nil : metrics.tpm)
        ]
        requestOutcomes = [
            count("usage.records.outcome.success", metrics.successes),
            // 历史非成功请求没有区分失败与取消，不能将它们直接归到失败，也不能显示伪造的零。
            metrics.unclassifiedFailures > 0 ? unavailable("usage.records.outcome.failed")
                : count("usage.records.outcome.failed", metrics.failures),
            metrics.unclassifiedFailures > 0 ? unavailable("usage.records.outcome.canceled")
                : count("usage.records.outcome.canceled", metrics.canceled)
        ]
    }
}
