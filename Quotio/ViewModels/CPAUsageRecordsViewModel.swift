import Foundation
import Observation

/// 筛选任务由视图生命周期管理；请求令牌防止较慢的旧查询覆盖用户的新条件。
@MainActor @Observable
final class CPAUsageRecordsViewModel {
    private(set) var result: CPAUsageEventPage?
    private(set) var isLoading = false
    private(set) var errorKey: String?
    @ObservationIgnored private let store: UsageStatisticsStore
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var previousSelection: CPAUsageSelection?
    @ObservationIgnored private var previousPage = 0
    @ObservationIgnored private var previousSize = 0

    init(store: UsageStatisticsStore) { self.store = store }

    func load(selection: CPAUsageSelection, page: Int, pageSize: Int, now: Date) async {
        let token = UUID()
        generation = token
        // 条件变化时不把旧数值暂挂到新筛选下；同条件后台刷新则保留上一份可用结果。
        if previousSelection != selection || previousPage != page || previousSize != pageSize { result = nil }
        previousSelection = selection; previousPage = page; previousSize = pageSize
        isLoading = true; errorKey = nil
        defer { if generation == token { isLoading = false } }
        do {
            let value = try await store.queryUsageRecords(selection.query(now: now, page: page, pageSize: pageSize))
            try Task.checkCancellation()
            guard generation == token else { return }
            result = value
        } catch is CancellationError {
            // 快速切换和关闭弹窗是正常取消，不显示成存储故障。
        } catch {
            if generation == token && !Task.isCancelled { errorKey = "usage.records.readFailed" }
        }
    }
}
