import Foundation

/// 分布维度使用上游真实元数据，不根据模型名猜测账号来源或客户端类型。
nonisolated enum CPAUsageDimension: String, CaseIterable, Sendable {
    case model, provider, source, apiKey
    var titleKey: String {
        switch self {
        case .model: return "usage.model"
        case .provider: return "usage.provider"
        case .source: return "usage.records.source"
        case .apiKey: return "usage.records.apiKey"
        }
    }
}

nonisolated enum CPAUsageChartMetric: String, CaseIterable, Sendable {
    case tokens, requests
    var titleKey: String { self == .tokens ? "usage.tokens" : "usage.cpa.requests" }
}

nonisolated struct CPAUsageTrendPoint: Sendable, Identifiable {
    let date: Date
    var requests: Int
    var tokens: Int
    var id: Date { date }
}

/// 与上游按单个维度聚合，同名模型跨提供商合并；稳定身份不受排行位置影响。
nonisolated struct CPAUsageCategory: Sendable, Identifiable {
    let key: String
    let title: String
    let provider: String
    let requests: Int
    let tokens: Int
    var id: String { "\(provider.utf8.count):\(provider)\(key)" }
    func value(_ metric: CPAUsageChartMetric) -> Int { metric == .tokens ? tokens : requests }
    func selection(from original: CPAUsageSelection, dimension: CPAUsageDimension) -> CPAUsageSelection {
        var selection = original
        switch dimension {
        case .model: selection.model = key
        case .provider: selection.provider = key
        case .source: selection.source = key
        case .apiKey: selection.apiKey = key
        }
        return selection
    }
}

nonisolated struct CPAUsageDashboardReport: Sendable {
    var summary: CPAUsageEventPage
    var trend: [CPAUsageTrendPoint]
    let hourly: Bool
    var categories: [CPAUsageCategory]
    var hasMoreCategories: Bool
    /// 旧日归档只贡献真实保存的汇总；不生成虚构事件或小时级请求。
    var historicalRequests = 0
    var omittedHistoricalRequests = 0
}

/// 价格仅表示用户配置的标准单价，单位统一为 USD / 百万 Tokens。
/// 未配置与显式零价不同；不凭模型名猜测套餐、优先级、长上下文或实际账单价格。
nonisolated struct CPAModelPrice: Codable, Sendable, Equatable, Identifiable {
    let model: String
    var input: Double
    var output: Double
    var cacheRead: Double?
    var cacheWrite: Double?
    var id: String { model }
    var isValid: Bool {
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.count <= 512 &&
        [input, output].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000 } &&
        [cacheRead, cacheWrite].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000 }
    }
}

nonisolated struct CPAUsagePriceRow: Sendable, Identifiable {
    let model: String
    let requests: Int
    let tokens: Int
    let pricedRequests: Int
    let estimatedCost: Double?
    let price: CPAModelPrice?
    /// 历史汇总与真实请求按同一模型合并，但保留数量来源供价格页明确解释覆盖范围。
    var historicalRequests = 0
    /// 有些请求或历史 Token 分量尚不能计价；即使已知部分恰好为零，也只能展示为下界。
    var hasPartialEstimate = false
    var id: String { model }
}

nonisolated struct CPAUsagePricingReport: Sendable {
    let summary: CPAUsageEventPage
    let rows: [CPAUsagePriceRow]
    var omittedHistoricalRequests = 0
    var pricedRequests: Int { rows.reduce(0) { $0 + $1.pricedRequests } }
    /// 缺少单价、缓存拆分或完整历史窗口时，已估金额只是当前有据部分的下界。
    /// 与金额是否为 nil 分开：完全未知仍是 nil，已知部分为零则保留真实的 0。
    var hasPartialEstimate: Bool {
        omittedHistoricalRequests > 0 || summary.metrics.requests > pricedRequests
            || rows.contains { $0.hasPartialEstimate }
    }
    var estimatedCost: Double? {
        let values = rows.compactMap(\.estimatedCost)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

/// 值导航携带进入子页时的筛选快照，返回不会改写仪表盘的筛选及滚动状态。
nonisolated enum CPAUsageDestination: Hashable {
    case records(CPAUsageSelection)
    case pricing(CPAUsageSelection)
}
