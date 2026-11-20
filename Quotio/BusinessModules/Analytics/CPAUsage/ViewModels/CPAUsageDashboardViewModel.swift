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
    /// 用户刷新单独使查询任务失效；后台采集状态不参与查询身份或导航按钮状态。
    private(set) var refreshRevision = 0
    @ObservationIgnored private var generation = UUID()
    private var previous: Query?

    struct Query: Hashable {
        let selection: CPAUsageSelection
        let dimension: CPAUsageDimension
        let metric: CPAUsageChartMetric
        let limit: Int
        let active: Bool
        var refreshRevision = 0
    }

    func requestRefresh() { refreshRevision &+= 1 }

    /// SwiftUI 先重绘、后启动查询；只在报表和当前条件匹配时引用它，防止用新标签解释旧数值。
    func result(matching query: Query) -> CPAUsageDashboardReport? {
        guard let previous, previous.selection == query.selection,
              previous.dimension == query.dimension, previous.metric == query.metric else { return nil }
        return result
    }

    func load(_ query: Query, store: UsageStatisticsStore, now: Date = .now) async -> Bool {
        let token = UUID()
        generation = token
        if let previous, previous.selection != query.selection || previous.dimension != query.dimension || previous.metric != query.metric {
            result = nil
        }
        previous = query
        errorKey = nil
        do {
            let value = try await store.queryDashboard(query.selection, dimension: query.dimension,
                metric: query.metric, limit: query.limit, now: now)
            try Task.checkCancellation()
            guard generation == token else { return false }
            // 无变化的后台查询不重新发布整份图表，减少轮询导致的无效布局与重绘。
            if result?.hasSamePresentation(as: value) != true { result = value }
            return true
        } catch {
            if generation == token && !Task.isCancelled { errorKey = "usage.records.readFailed" }
            return false
        }
    }
}

/// 价格子页保留独立明细和编辑查询；总览选中费用口径时只读取聚合。
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
