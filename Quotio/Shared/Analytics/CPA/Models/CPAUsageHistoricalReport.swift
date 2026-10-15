import Foundation

/// 旧版仅保存每日汇总。保留可证明的日级统计；精确时间、来源、密钥及结果无法
/// 覆盖的历史单独标明，避免静默显示零、按请求比例分摊 Tokens 或虚构取消数量。
nonisolated struct CPAUsageHistoricalReport {
    let buckets: [UsageBucket]
    let options: [UsageBucket]
    let omittedRequests: Int
    let allRequests: Int
    private let hasExplicitTimeRange: Bool

    init(history: [UsageBucket], collectedAt: Date?, query: CPAUsageQuery, calendar: Calendar) {
        var included: [UsageBucket] = []
        var options: [UsageBucket] = []
        var omitted = 0
        for bucket in history {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: bucket.day) else { continue }
            // 采集时间只作为末日上界；不能用它反推某个日桶中请求发生的具体时刻。
            let lastPossible = min(nextDay, max(bucket.day, collectedAt ?? nextDay))
            guard query.start.map({ $0 < nextDay }) ?? true,
                  query.end.map({ $0 >= bucket.day }) ?? true else { continue }
            options.append(bucket)
            guard Self.matches(bucket.provider, query.provider), Self.matches(bucket.model, query.model) else { continue }
            let coversDay = (query.start.map { $0 <= bucket.day } ?? true)
                && (query.end.map { $0 >= lastPossible } ?? true)
            let supportsMetadata = (query.source.isEmpty || query.source == "__unknown__")
                && (query.apiKey.isEmpty || query.apiKey == "__unknown__") && query.outcome == .all
            if coversDay && supportsMetadata { included.append(bucket) }
            else { omitted += bucket.requests }
        }
        self.buckets = included
        self.options = options
        self.omittedRequests = omitted
        self.allRequests = history.reduce(0) { $0 + $1.requests }
        self.hasExplicitTimeRange = query.start != nil && query.end != nil
    }

    private static func matches(_ actual: String, _ selected: String) -> Bool {
        selected.isEmpty || (selected == "__unknown__" ? actual.isEmpty : sqliteNoCaseKey(actual) == sqliteNoCaseKey(selected))
    }

    /// 三个页面共用历史范围和筛选选项；明细页保留实际事件指标，只有总览/价格页
    /// 才合并日级指标。分页继续由真实事件数计算，历史行始终是独立的日期汇总。
    func mergingSummary(into original: CPAUsageEventPage, includeHistoricalMetrics: Bool) -> CPAUsageEventPage {
        var page = original
        page.historicalBuckets = buckets.sorted {
            if $0.day != $1.day { return $0.day > $1.day }
            return $0.id < $1.id
        }
        page.omittedHistoricalRequests = omittedRequests
        page.allHistoricalRequests = allRequests
        page.providers = mergedOptions(page.providers, names: options.map(\.provider))
        page.models = mergedOptions(page.models, names: options.map(\.model))
        guard includeHistoricalMetrics, !buckets.isEmpty else { return page }
        let totals = UsageTotals(buckets: buckets)
        var metrics = page.metrics
        metrics.requests += totals.requests
        metrics.successes += totals.requests - totals.failures
        metrics.unclassifiedFailures += totals.failures
        metrics.input += totals.inputTokens
        metrics.output += totals.outputTokens
        metrics.reasoning += totals.reasoningTokens
        metrics.cached += totals.cachedTokens
        metrics.tokens += totals.totalTokens
        metrics.latencyTotal += totals.latencyTotal
        metrics.latencySamples += totals.latencySamples
        // 日汇总没有首末请求时间；无完整显式时间窗时不能延用仅明细计算的吞吐量。
        if !hasExplicitTimeRange { metrics.minutes = nil }
        page.metrics = metrics
        return page
    }

    /// 目录查询只补充历史确实保存的提供商和模型；来源、密钥没有历史证据时不生成身份。
    func mergingOptions(into original: CPAUsageFilterOptions) -> CPAUsageFilterOptions {
        var result = original
        result.providers = mergedOptions(result.providers, names: options.map(\.provider))
        result.models = mergedOptions(result.models, names: options.map(\.model))
        return result
    }

    private func mergedOptions(_ existing: [CPAUsageOption], names: [String]) -> [CPAUsageOption] {
        var values = Dictionary(existing.map { (Self.sqliteNoCaseKey($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        for name in names where !name.isEmpty {
            if values[Self.sqliteNoCaseKey(name)] == nil { values[Self.sqliteNoCaseKey(name)] = CPAUsageOption(id: name, title: name) }
        }
        return values.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 与新事件相加前，调用者已经扣除了事件索引覆盖的日桶部分。
    /// 总览、趋势和排行都合并同一批历史，排行完成合并后才取前 N 项。
    func merging(into original: CPAUsageDashboardReport, query: CPAUsageQuery,
                 dimension: CPAUsageDimension, metric: CPAUsageChartMetric, limit: Int) -> CPAUsageDashboardReport {
        var report = original
        report.omittedHistoricalRequests = omittedRequests
        report.summary = mergingSummary(into: original.summary, includeHistoricalMetrics: true)
        guard !buckets.isEmpty else { return report }
        report.historicalRequests = report.summary.historicalRequests
        // 未限定完整窗口时，历史只有日期，无法重建上游首末事件跨度，吞吐量应留空。
        if query.start == nil || query.end == nil { report.summary.metrics.minutes = nil }

        var points = Dictionary(uniqueKeysWithValues: report.trend.map { ($0.date, $0) })
        var categories = Dictionary(report.categories.map { (Self.sqliteNoCaseKey($0.key), $0) }, uniquingKeysWith: { first, _ in first })
        for bucket in buckets {
            var point = points[bucket.day] ?? CPAUsageTrendPoint(date: bucket.day, requests: 0, tokens: 0)
            // 旧日账本保存过输入、输出和缓存总量，可直接按日合并；不推算缓存读写拆分。
            point.add(CPAUsageTrendPoint(date: bucket.day, requests: bucket.requests, tokens: bucket.totalTokens,
                                        input: bucket.inputTokens, output: bucket.outputTokens, cached: bucket.cachedTokens))
            points[bucket.day] = point
            let name: String
            switch dimension {
            case .model: name = bucket.model
            case .provider: name = bucket.provider
            case .source, .apiKey: name = ""
            }
            let key = name.isEmpty ? "__unknown__" : name
            let old = categories[Self.sqliteNoCaseKey(key)]
            categories[Self.sqliteNoCaseKey(key)] = CPAUsageCategory(key: old?.key ?? key, title: old?.title ?? name, provider: "",
                requests: (old?.requests ?? 0) + bucket.requests, tokens: (old?.tokens ?? 0) + bucket.totalTokens)
        }
        report.trend = points.values.sorted { $0.date < $1.date }
        // 长历史先完成逐日相加再合并连续点，否则旧历史会与已压缩的新事件日期错位。
        report.trend = CPAUsageTrendPoint.coalesced(report.trend)
        let sorted = categories.values.sorted {
            if $0.value(metric) != $1.value(metric) { return $0.value(metric) > $1.value(metric) }
            if $0.requests != $1.requests { return $0.requests > $1.requests }
            return $0.key < $1.key
        }
        let boundedLimit = min(1_000, max(8, limit))
        report.categories = Array(sorted.prefix(boundedLimit))
        report.hasMoreCategories = sorted.count > boundedLimit
        return report
    }

    /// 历史只提供日级 Token 分量，价格表仍应列出这些模型并允许配置单价。
    /// 缓存读写无法恢复时，仅估算普通输入和输出，不推测缓存类型、不把整桶计为完整覆盖。
    func merging(into original: CPAUsagePricingReport, prices: [CPAModelPrice]) -> CPAUsagePricingReport {
        let catalogue = Dictionary(prices.map { (Self.sqliteNoCaseKey($0.model), $0) }, uniquingKeysWith: { first, _ in first })
        var rows = Dictionary(original.rows.map { (Self.sqliteNoCaseKey($0.model), $0) }, uniquingKeysWith: { first, _ in first })
        for bucket in buckets {
            let key = Self.sqliteNoCaseKey(bucket.model)
            let old = rows[key]
            let price = old?.price ?? catalogue[key]
            let estimate = historicalCost(bucket, price: price)
            let costs = [old?.estimatedCost, estimate.cost].compactMap { $0 }
            var row = CPAUsagePriceRow(model: old?.model ?? bucket.model,
                requests: (old?.requests ?? 0) + bucket.requests,
                tokens: (old?.tokens ?? 0) + bucket.totalTokens,
                pricedRequests: (old?.pricedRequests ?? 0) + (estimate.complete ? bucket.requests : 0),
                estimatedCost: costs.isEmpty ? nil : costs.reduce(0, +), price: price)
            row.historicalRequests = (old?.historicalRequests ?? 0) + bucket.requests
            row.hasPartialEstimate = (old?.hasPartialEstimate ?? false) || !estimate.complete
                || row.pricedRequests < row.requests
            rows[key] = row
        }
        let ordered = rows.values.sorted {
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            return $0.model < $1.model
        }
        return CPAUsagePricingReport(summary: mergingSummary(into: original.summary, includeHistoricalMetrics: true),
            rows: ordered, omittedHistoricalRequests: omittedRequests)
    }

    /// SQLite 内置 NOCASE 只折叠 ASCII 的 A–Z；Swift 的 Unicode 小写转换范围更大。
    /// 历史筛选、选项去重、排行合并与价格主键都必须使用同一规则，才能让 Élite
    /// 与 élite 保留各自的请求和单价。保留 UTF-8 字节数组作为键，也避免 Swift
    /// String 的 Unicode 规范等价比较进一步合并 SQLite 视为不同的标识。
    private static func sqliteNoCaseKey(_ value: String) -> [UInt8] {
        value.utf8.map { byte in (65...90).contains(byte) ? byte + 32 : byte }
    }

    private func historicalCost(_ bucket: UsageBucket, price: CPAModelPrice?) -> (cost: Double?, complete: Bool) {
        guard let price else { return (nil, false) }
        // 只有总 Token 而没有输入/输出分量的旧归档不能按零元处理。
        // 真实的零 Token 桶仍可使用显式配置单价得到完整的零费用。
        guard bucket.inputTokens > 0 || bucket.outputTokens > 0 || bucket.totalTokens == 0 else { return (nil, false) }
        // 输入/输出超出总量，或缓存超出输入时，已保存的分量彼此矛盾；此时无法证明
        // 任何分量计价是实际费用下界，必须保持未知。总量大于已知分量则仍可估算
        // 已知部分，只是不计为完整覆盖。用减法比较避免不可信旧数据的加法溢出。
        guard bucket.inputTokens <= bucket.totalTokens,
              bucket.outputTokens <= bucket.totalTokens - bucket.inputTokens,
              bucket.cachedTokens <= bucket.inputTokens else { return (nil, false) }
        let input = max(0, bucket.inputTokens - bucket.cachedTokens)
        let cost = (Double(input) * price.input + Double(bucket.outputTokens) * price.output) / 1_000_000
        let complete = bucket.cachedTokens == 0 && bucket.totalTokens == bucket.inputTokens + bucket.outputTokens
        return (cost, complete)
    }
}
