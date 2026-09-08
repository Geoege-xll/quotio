import Foundation
import Observation

/// 生命周期由页面 task 控制。旧查询取消后不能覆盖新筛选，同条件刷新保留现有图表。
@MainActor @Observable
final class CPAUsageDashboardViewModel {
    /// 图表指标与分组由公共筛选区持有，趋势和排行只接收这份状态。
    var dimension: CPAUsageDimension = .model
    var metric: CPAUsageChartMetric = .tokens
    private(set) var result: CPAUsageDashboardReport?
    private(set) var errorKey: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var previous: Query?

    struct Query: Hashable {
        let selection: CPAUsageSelection
        let dimension: CPAUsageDimension
        let metric: CPAUsageChartMetric
        let limit: Int
        let active: Bool
    }

    func load(_ query: Query, store: UsageStatisticsStore) async -> Bool {
        let token = UUID()
        generation = token
        if let previous, previous.selection != query.selection || previous.dimension != query.dimension || previous.metric != query.metric {
            result = nil
        }
        previous = query
        errorKey = nil
        do {
            let value = try await store.queryDashboard(query.selection, dimension: query.dimension,
                metric: query.metric, limit: query.limit, now: Date())
            try Task.checkCancellation()
            guard generation == token else { return false }
            result = value
            return true
        } catch {
            if generation == token && !Task.isCancelled { errorKey = "usage.records.readFailed" }
            return false
        }
    }
}

/// 价格汇总仅在价格子页面打开时查询，编辑价格后刷新，不在首页常驻计算费用。
@MainActor @Observable
final class CPAUsagePricingViewModel {
    private(set) var result: CPAUsagePricingReport?
    private(set) var errorKey: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var previousSelection: CPAUsageSelection?

    func load(_ selection: CPAUsageSelection, store: UsageStatisticsStore) async -> Bool {
        let token = UUID()
        generation = token
        if previousSelection != selection { result = nil }
        previousSelection = selection
        errorKey = nil
        do {
            let value = try await store.queryPricing(selection, now: Date())
            try Task.checkCancellation()
            guard generation == token else { return false }
            result = value
            return true
        } catch {
            if generation == token && !Task.isCancelled { errorKey = "usage.records.readFailed" }
            return false
        }
    }
}
