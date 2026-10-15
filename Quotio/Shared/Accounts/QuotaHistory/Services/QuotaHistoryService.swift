import Foundation
import Observation

/// 应用级额度历史协调：只订阅已发布快照，不创建轮询、不调用提供商 API 或用量队列。
/// 历史写入使用独立世代，维护暂停／账号清理使排队旧写入失效；原 QuotaViewModel 状态不迁移。
@MainActor @Observable
final class QuotaHistoryService {
    private(set) var revision: UInt64 = 0
    private(set) var isSuspended = false
    private(set) var isClearing = false
    private(set) var recordingError = false
    private(set) var recordingEnabled: Bool
    @ObservationIgnored private let store: QuotaHistoryStore
    @ObservationIgnored private let defaults: UserDefaults
    private var generation: UInt64 = 0
    private var isChangingRecording = false
    /// 新增采样任务只归历史服务，合并同一分钟的最新样本；不借用原额度刷新或预热任务句柄。
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    private var pendingSamples: [SampleKey: QuotaHistorySample] = [:]
    private struct SampleKey: Hashable {
        let account: QuotaHistoryAccount
        let metric: String
        let minute: Int64
    }

    init(store: QuotaHistoryStore = QuotaHistoryStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        recordingEnabled = defaults.object(forKey: "quotaHistoryRecordingEnabled") as? Bool ?? true
    }

    /// 开关也推进原历史世代，暂停前已经排队的旧写入不能在暂停之后继续提交。
    /// UI 使用显式异步入口，不在 didSet 内派生隐藏任务；配置仍由本服务唯一持有。
    func setRecordingEnabled(_ enabled: Bool) async {
        guard !isSuspended, !isClearing else { return }
        generation &+= 1
        pendingSamples.removeAll()
        let expected = generation
        isChangingRecording = true
        recordingEnabled = enabled
        defaults.set(enabled, forKey: "quotaHistoryRecordingEnabled")
        await store.advanceGeneration(to: expected)
        guard expected == generation else { return }
        isChangingRecording = false
        revision &+= 1
    }

    /// 只接收本轮新发布的观测：相同／更旧的源时间属于缓存复用，不计为新历史。
    /// 原账号键变更仍按精确键隔离，不根据邮箱合并；服务内最多保留有界待写样本。
    func submit(mode: String, quotas: [AIProvider: [String: ProviderQuotaData]], previous: [AIProvider: [String: ProviderQuotaData]]) {
        guard recordingEnabled, !isSuspended, !isClearing, !isChangingRecording else { return }
        for (provider, accounts) in quotas {
            for (key, quota) in accounts {
                if let old = previous[provider]?[key], quota.lastUpdated <= old.lastUpdated { continue }
                for model in quota.models {
                    guard let point = QuotaHistoryPoint.make(model: model, quota: quota) else { continue }
                    // 在主线程排队前也安全转换时间，避免畸形的有限 Date 在 Int64 转换时触发陷阱。
                    guard let minute = Int64(exactly: floor(point.date.timeIntervalSince1970 / 60)) else { continue }
                    let account = QuotaHistoryAccount(mode: mode, provider: provider, accountKey: key)
                    let id = SampleKey(account: account, metric: point.metricID, minute: minute)
                    if (pendingSamples[id]?.point.date ?? .distantPast) < point.date {
                        pendingSamples[id] = QuotaHistorySample(account: account, point: point)
                    }
                }
            }
        }
        // 异常提供商返回巨量指标时也限制主线程队列；优先保留最新观测，数据库另有十万条硬上限。
        if pendingSamples.count > 10_000 {
            let newest = pendingSamples.sorted { $0.value.point.date > $1.value.point.date }.prefix(10_000)
            pendingSamples = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        guard writeTask == nil, !pendingSamples.isEmpty else { return }
        writeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { writeTask = nil }
            while !pendingSamples.isEmpty, !Task.isCancelled {
                let batch = Array(pendingSamples.values), expected = generation
                pendingSamples.removeAll(keepingCapacity: true)
                do {
                    let changed = try await store.record(batch, generation: expected)
                    guard expected == generation, !isSuspended else { continue }
                    recordingError = false
                    if changed { revision &+= 1 }
                } catch is CancellationError { return }
                catch {
                    if expected == generation, !isSuspended { recordingError = true }
                }
            }
        }
    }

    /// 定向回归及维护协调可等待已有写入，不创建另一个写入任务或暴露可变句柄。
    func waitForWrites() async { await writeTask?.value }

    func metrics(account: QuotaHistoryAccount) async throws -> [QuotaHistoryPoint] {
        guard !isSuspended else { throw QuotaHistoryError.busy }
        let expected = generation
        let result = try await store.metrics(account: account)
        try Task.checkCancellation()
        guard expected == generation, !isSuspended else { throw CancellationError() }
        return result
    }

    func points(account: QuotaHistoryAccount, metricID: String, range: QuotaHistoryRange) async throws -> [QuotaHistoryChartPoint] {
        guard !isSuspended else { throw QuotaHistoryError.busy }
        let expected = generation
        let result = try await store.points(account: account, metricID: metricID, range: range)
        try Task.checkCancellation()
        guard expected == generation, !isSuspended else { throw CancellationError() }
        return result
    }

    func dailyRates(account: QuotaHistoryAccount) async throws -> [String: QuotaHistoryDailyRate] {
        guard !isSuspended else { throw QuotaHistoryError.busy }
        let expected = generation
        let result = try await store.dailyRates(account: account)
        try Task.checkCancellation()
        guard expected == generation, !isSuspended else { throw CancellationError() }
        return result
    }

    func clear(account: QuotaHistoryAccount) async throws {
        guard !isSuspended, !isClearing, !isChangingRecording else { throw QuotaHistoryError.busy }
        isClearing = true
        defer { isClearing = false }
        let before = generation
        // 单账号清理不能丢弃其他账号已经排队的观测。先拒绝新提交，仅移除本账号待写，
        // 等现有批次提交完毕后再推进世代与删除；期间全局维护抢先接管则取消本轮。
        pendingSamples = pendingSamples.filter { $0.value.account != account }
        await waitForWrites()
        try Task.checkCancellation()
        guard before == generation, !isSuspended else { throw CancellationError() }
        generation &+= 1
        let expected = generation
        await store.advanceGeneration(to: expected)
        try Task.checkCancellation()
        guard expected == generation, !isSuspended else { throw CancellationError() }
        try await store.clear(account: account, generation: expected)
        guard expected == generation, !isSuspended else { throw CancellationError() }
        revision &+= 1
    }

    /// 原统计维护屏障先暂停采集、再等待历史 actor 废弃所有旧写入，之后才执行同库清理。
    func suspendForMaintenance() async {
        isSuspended = true
        isChangingRecording = false
        pendingSamples.removeAll()
        generation &+= 1
        await store.advanceGeneration(to: generation)
    }

    func invalidateAfterMaintenance() { revision &+= 1; recordingError = false }
    func resumeAfterMaintenance() { isSuspended = false; revision &+= 1 }
}
