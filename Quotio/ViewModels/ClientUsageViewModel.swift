import Foundation
import Observation

/// 分来源刷新与发布：慢客户端不阻塞其它结果；用户可取消，已完成来源立即保留。
@MainActor @Observable
final class ClientUsageViewModel {
    private(set) var snapshot = ClientUsageSnapshot()
    private(set) var buckets: [UsageBucket] = []
    private(set) var isLoading = false
    private(set) var errorKey: String?
    private(set) var activities: [ClientUsageSource: ClientUsageActivity] = [:]
    @ObservationIgnored private let engine: ClientUsageEngine
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var presentationTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceSuspended = false
    @ObservationIgnored private var pageIsActive = false
    @ObservationIgnored private var pendingManualRefresh = false
    @ObservationIgnored private var reasoningUnknownDays: [Date] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lastCompletedRefresh: Date?
    @ObservationIgnored private var presentations: [PresentationKey: Presentation] = [:]
    @ObservationIgnored private var presentationCalendar = Calendar.current
    @ObservationIgnored private var presentationReloadGeneration = UUID()
    private var presentationRevision = 0

    struct Presentation {
        let statistics: UsageStatisticsPresentation
        let available: Bool
        let lacksReasoning: Bool
    }
    private struct PresentationKey: Hashable {
        let revision: Int
        let interval: DateInterval?
        let source: ClientUsageSource?
    }

    init(engine: ClientUsageEngine = ClientUsageEngine()) { self.engine = engine }
    func start() {
        // 维护中进入页面仍记录意图，维护结束后应自动加载，不能要求用户再切页一次。
        pageIsActive = true
        guard !maintenanceSuspended, loopTask == nil else { return }
        refreshIfNeeded()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                guard !Task.isCancelled, let self else { break }
                self.refreshIfNeeded()
            }
        }
    }
    /// 自动进入只检查最近一次完整刷新；部分来源的提前发布不能误判整轮已经完成。
    /// 手动刷新仍可立即检查日志，重复点击由 isLoading 合并为同一轮任务。
    func refreshIfNeeded(now: Date = Date()) {
        if presentationCalendar != Calendar.current { reloadPresentation() }
        guard lastCompletedRefresh.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        refresh()
    }

    /// 系统改区或日历偏好变化只重建现有事实的日桶，不重新扫描日志。
    /// 离页期间错过通知也会在 refreshIfNeeded 中补做；迟到结果仍遵守采集代际与时间顺序。
    func reloadPresentation(calendar: Calendar = .current) {
        guard !maintenanceSuspended else { return }
        presentationTask?.cancel()
        let current = generation
        let reload = UUID()
        presentationReloadGeneration = reload
        presentationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await engine.loadPresentation(calendar: calendar)
                guard generation == current, presentationReloadGeneration == reload,
                      (value.snapshot.collectedAt ?? .distantPast) >= (snapshot.collectedAt ?? .distantPast) else { return }
                publish(value, calendar: calendar)
            } catch is CancellationError {
                // 新的时区/日历请求替换旧重建是正常交互，不能留下虚假的读取失败提示。
            } catch {
                if generation == current, presentationReloadGeneration == reload { errorKey = "usage.client.failed" }
            }
        }
    }
    func refresh() {
        if maintenanceSuspended { pendingManualRefresh = true; return }
        guard !isLoading else { return }
        let current = UUID()
        generation = current; isLoading = true; errorKey = nil
        activities = Dictionary(uniqueKeysWithValues: ClientUsageSource.allCases.map {
            ($0, ClientUsageActivity(progress: ClientUsageProgress(source: $0)))
        })
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == current { isLoading = false } }
            do {
                if snapshot.collectedAt == nil {
                    let saved = try await engine.loadPresentation()
                    try Task.checkCancellation()
                    guard generation == current else { return }
                    publish(saved)
                }
                // 扫描器在后台发节流进度；主线程只接收数量和已聚合的日桶，不处理原始历史。
                let fresh = try await engine.refresh { [weak self] event in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == current else { return }
                        self.receive(event)
                    }
                }
                try Task.checkCancellation()
                guard generation == current else { return }
                // 最终快照显式读取，避免最后一个异步完成通知尚未进入主队列时短暂缺少结果。
                let presentation = try await engine.loadPresentation()
                guard generation == current else { return }
                publish(presentation)
                for status in fresh.metadata.statuses {
                    activities[status.source]?.phase = status.hasErrors ? .failed : .complete
                }
                if fresh.metadata.statuses.contains(where: \.hasErrors) { errorKey = "usage.client.partial" }
                lastCompletedRefresh = Date()
            } catch is CancellationError {
                // 用户取消的文案由cancelRefresh设置；离开页面不会产生错误提示。
            } catch {
                if generation == current {
                    errorKey = "usage.client.failed"
                    for source in ClientUsageSource.allCases where activities[source]?.phase != .complete {
                        activities[source]?.phase = .failed
                    }
                }
            }
        }
    }
    /// 取消只停止当前读取，不删除已保存的数据；同时暂停自动循环，避免一分钟后自行重启用户取消的扫描。
    func cancelRefresh() {
        stop()
        errorKey = "usage.client.cancelled"
        for source in ClientUsageSource.allCases {
            guard let phase = activities[source]?.phase, phase != .complete, phase != .failed else { continue }
            activities[source]?.phase = .cancelled
        }
    }
    func cancel() { stop() }
    /// 离开页面暂停定时唤醒，但不中断正在解析的文件；显式取消按钮才结束采集。
    func stopAutomaticRefresh() {
        pageIsActive = false
        pendingManualRefresh = false
        loopTask?.cancel(); loopTask = nil
    }
    private func stop() {
        stopAutomaticRefresh()
        presentationTask?.cancel()
        task?.cancel(); task = nil
        generation = UUID(); isLoading = false
    }
    private func receive(_ event: ClientUsageRefreshEvent) {
        switch event {
        case .progress(let progress):
            // 来源完成后排队中的进度不能把状态倒退成扫描中。
            let phase = activities[progress.source]?.phase
            guard isLoading, phase != .complete, phase != .failed, phase != .saving else { return }
            activities[progress.source] = ClientUsageActivity(phase: .scanning, progress: progress)
        case .saving(let source):
            guard isLoading, activities[source]?.phase != .complete, activities[source]?.phase != .failed else { return }
            activities[source]?.phase = .saving
        case .completed(let source, let display):
            // 不接收比已发布快照更旧的来源完成通知，防止主队列调度顺序造成数据倒退。
            if (display.metadata.collectedAt ?? .distantPast) >= (snapshot.collectedAt ?? .distantPast) {
                publish(display)
            }
            let failed = display.metadata.statuses.first { $0.source == source }?.hasErrors == true
            activities[source]?.phase = failed ? .failed : .complete
            if failed { errorKey = "usage.client.partial" }
        case .failed(let source):
            activities[source]?.phase = .failed
            errorKey = "usage.client.partial"
        }
    }
    private func publish(_ value: ClientUsageDisplaySnapshot, calendar: Calendar = .current) {
        snapshot = value.metadata
        buckets = value.buckets
        reasoningUnknownDays = value.reasoningUnknownDays
        presentationCalendar = calendar
        // 后到的日历重建任务不能覆盖已经发布的新快照或更新后的时区结果。
        presentationReloadGeneration = UUID()
        presentationRevision += 1
        presentations.removeAll(keepingCapacity: true)
    }

    /// 筛选仅访问当前快照。缓存键使用实际日期边界，午夜/时区变化自然产生新结果；
    /// 新快照发布统一失效，进度、悬浮和布局刷新不会重复分组、排序或遍历原始记录。
    func presentation(interval: DateInterval?, source: ClientUsageSource?) -> Presentation {
        let key = PresentationKey(revision: presentationRevision, interval: interval, source: source)
        if let cached = presentations[key] { return cached }
        let result = Presentation(
            statistics: UsageStatisticsPresentation(buckets: buckets, interval: interval, provider: source?.title, model: nil),
            available: buckets.contains { source == nil || $0.provider == source?.title } || snapshot.hasData(source: source),
            lacksReasoning: (source == nil || source == .pi) && reasoningUnknownDays.contains { day in
                interval.map { day >= $0.start && day < $0.end } ?? true
            })
        // 有界缓存覆盖日常来源/期间切换，不随用户反复选择日期无限增长。
        if presentations.count >= 24 { presentations.removeAll(keepingCapacity: true) }
        presentations[key] = result
        return result
    }

    /// 清理事务前建立采集屏障：不仅取消 UI 发布，还等待四个来源的子任务退出，
    /// 保证清空数据库后不会再被旧扫描结果写回。维护结束前拒绝页面触发的新扫描。
    func suspendForMaintenance() async {
        guard !maintenanceSuspended else { return }
        let wasActive = pageIsActive
        maintenanceSuspended = true
        let scanning = task
        let presentation = presentationTask
        stop()
        pageIsActive = wasActive
        await scanning?.value
        await presentation?.value
        await engine.releaseMemoryCaches()
    }

    func resumeAfterMaintenance() {
        guard maintenanceSuspended else { return }
        maintenanceSuspended = false
        let manual = pendingManualRefresh
        pendingManualRefresh = false
        if manual { refresh() }
        if pageIsActive { start() }
    }

    func clearMemoryCaches() async {
        presentations.removeAll()
        await engine.releaseMemoryCaches()
    }

    /// 删除统计后立即展示空账本；下次用户进入页面可以从仍存在的源日志重新采集。
    func reloadAfterMaintenance() async throws {
        // 已提交删除不能被读取失败“撤回”为旧界面；先失效展示和新鲜度，再尝试读取新账本。
        publish(ClientUsageDisplaySnapshot())
        activities.removeAll()
        lastCompletedRefresh = nil
        errorKey = nil
        await clearMemoryCaches()
        do { publish(try await engine.loadPresentation()) }
        catch { errorKey = "usage.client.failed"; throw error }
    }
}
