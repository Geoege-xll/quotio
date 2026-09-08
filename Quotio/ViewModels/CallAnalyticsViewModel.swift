// 调用分析页面状态：沿用项目 Observation 模式，扫描与磁盘操作交给独立 actor。
import Foundation
import Observation

@MainActor @Observable
final class CallAnalyticsViewModel {
    private(set) var snapshot = CallAnalyticsSnapshot.empty {
        didSet { reports.removeAll(keepingCapacity: true); reportRevision += 1 }
    }
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var range: CallAnalyticsDateRange = .week
    var source: CallSourceKind?
    var kind: CallKind?
    var customStart = Calendar.current.startOfDay(for: Date())
    var customEnd = Date()
    @ObservationIgnored private let engine: CallAnalyticsEngine
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lastCompletedRefresh: Date?
    @ObservationIgnored private var reports: [ReportKey: CallAnalyticsReport] = [:]
    @ObservationIgnored private var maintenanceSuspended = false
    @ObservationIgnored private var pendingMaintenanceRefresh = false
    private var reportRevision = 0
    private struct ReportKey: Hashable {
        let revision: Int
        let lower: String?
        let upper: String?
        let source: CallSourceKind?
        let kind: CallKind?
    }

    init(engine: CallAnalyticsEngine = .shared) { self.engine = engine }

    var report: CallAnalyticsReport {
        var calendar = Calendar.current
        calendar.timeZone = aggregationTimeZone
        // 自定义日期来自系统 DatePicker，其年月日才是用户选择；转换到归档日历的同一日期，
        // 避免把本机零点当作绝对时刻换区后，筛选边界意外前移或后移一天。
        func archiveDate(_ date: Date) -> Date {
            let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
            return calendar.date(from: components) ?? date
        }
        let (lower, upper) = range.bounds(now: Date(), start: archiveDate(customStart),
                                         end: archiveDate(customEnd), calendar: calendar)
        let key = ReportKey(revision: reportRevision, lower: lower, upper: upper, source: source, kind: kind)
        if let cached = reports[key] { return cached }
        // 同一次展示的 KPI、趋势与排行共享聚合；筛选只切换内存报表，不驱动引擎扫描。
        let result = CallAnalyticsReport(snapshot: snapshot, lowerDay: lower, upperDay: upper, source: source, kind: kind)
        if reports.count >= 24 { reports.removeAll(keepingCapacity: true) }
        reports[key] = result
        return result
    }

    /// 只有日摘要的归档不能在旅行换区后重新分桶；筛选与日桶必须使用同一统计时区。
    var aggregationTimeZone: TimeZone {
        snapshot.aggregationTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    func refreshIfNeeded(now: Date = Date()) {
        // 清理期间的数据即使暂时仍新鲜，也可能随后被删除；页面进入意图必须先于新鲜度判断保存。
        if maintenanceSuspended { pendingMaintenanceRefresh = true; return }
        guard lastCompletedRefresh.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        refresh()
    }

    /// 冷启动先展示 SQL 摘要，再检查来源变化；并发刷新合并，迟到结果不能覆盖较新的快照。
    func refresh() {
        if maintenanceSuspended { pendingMaintenanceRefresh = true; return }
        guard !isLoading else { return }
        let current = UUID()
        generation = current
        isLoading = true
        errorMessage = nil
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == current { isLoading = false } }
            do {
                if snapshot.generatedAt == .distantPast {
                    let cached = try await engine.cachedSnapshot()
                    try Task.checkCancellation()
                    if generation == current { snapshot = cached }
                }
                let fresh = try await engine.refresh()
                try Task.checkCancellation()
                guard generation == current else { return }
                snapshot = fresh
                lastCompletedRefresh = Date()
                if fresh.sources.contains(where: { $0.errorCode != nil }) {
                    errorMessage = "callAnalytics.error.partial".localized()
                }
            } catch is CancellationError {
                // 主动取消属于正常交互；保留最近有效摘要。
            } catch {
                guard generation == current else { return }
                errorMessage = "callAnalytics.error.load".localized()
            }
        }
    }

    func cancel() {
        pendingMaintenanceRefresh = false
        refreshTask?.cancel()
        generation = UUID()
        isLoading = false
    }

    /// 等待同步扫描 actor 实际退出后才允许清理 SQL，generation 只负责防止旧结果回到界面。
    func suspendForMaintenance() async {
        maintenanceSuspended = true
        let active = refreshTask
        cancel()
        await active?.value
        reports.removeAll()
    }

    func resumeAfterMaintenance() {
        maintenanceSuspended = false
        let pending = pendingMaintenanceRefresh
        pendingMaintenanceRefresh = false
        if pending { refreshIfNeeded() }
    }
    func discardPendingMaintenanceRefresh() { pendingMaintenanceRefresh = false }
    func clearMemoryCaches() { reports.removeAll() }

    func reloadAfterMaintenance() async throws {
        // 事实已删除时，即使磁盘重读失败也只能展示空状态，不能保留旧排行和报表。
        snapshot = .empty
        lastCompletedRefresh = nil
        errorMessage = nil
        do { snapshot = try await engine.cachedSnapshot() }
        catch { errorMessage = "callAnalytics.error.load".localized(); throw error }
    }
}
