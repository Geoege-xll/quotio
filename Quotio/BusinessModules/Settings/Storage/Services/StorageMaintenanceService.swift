import Foundation
import Observation

/// 页面只发起维护意图；应用持有的服务负责暂停采集、等待在途写入、失效旧结果及恢复运行。
/// 回调由应用层注入，避免另建一套统计引擎或第二个 CPA 队列消费者。
@MainActor @Observable
final class StorageMaintenanceService {
    private(set) var snapshot: AnalyticsStorageSnapshot?
    private(set) var isBusy = false
    private(set) var errorKey: String?
    private(set) var messageKey: String?
    private(set) var lastClearResult: AnalyticsStorageClearResult?

    @ObservationIgnored private let store: StorageMaintenanceStore
    @ObservationIgnored private let prepareAction: @MainActor () async throws -> Void
    @ObservationIgnored private let invalidateAction: @MainActor (Set<AnalyticsStorageModule>) async throws -> Void
    @ObservationIgnored private let resumeAction: @MainActor () -> Void
    @ObservationIgnored private let clearCachesAction: @MainActor () async throws -> Void

    init(store: StorageMaintenanceStore = StorageMaintenanceStore(),
         prepare: @escaping @MainActor () async throws -> Void,
         invalidate: @escaping @MainActor (Set<AnalyticsStorageModule>) async throws -> Void,
         resume: @escaping @MainActor () -> Void,
         clearCaches: @escaping @MainActor () async throws -> Void) {
        self.store = store
        prepareAction = prepare
        invalidateAction = invalidate
        resumeAction = resume
        clearCachesAction = clearCaches
    }

    /// 读取与写入共用忙碌状态，保证清理完成后不会再发布先前排队的旧存储概况。
    func inspect() async {
        guard beginOperation() else { return }
        defer { isBusy = false }
        do { snapshot = try await store.inspect() }
        catch is CancellationError { }
        catch { errorKey = "storage.inspect.failed" }
    }

    /// 此入口仅清除可重建缓存；事实、水位与尚未投影的扫描输入全部由业务存储保留。
    func clearCaches() async {
        guard beginOperation() else { return }
        defer { resumeAction(); isBusy = false }
        do {
            try await prepareAction()
            try Task.checkCancellation()
            try await clearCachesAction()
            snapshot = try await store.inspect()
            messageKey = "storage.cache.cleared"
        } catch is CancellationError { }
        catch { errorKey = "storage.cache.failed" }
    }

    /// 等待已返回的 CPA 消费批次入库后才删除，避免清理结束又被迟到写入恢复历史。
    /// 一旦事务提交，后续刷新失败必须明确说明“数据已清除”，不能让用户误以为删除已回滚。
    func clearStatistics(_ modules: Set<AnalyticsStorageModule>) async {
        guard !modules.isEmpty, beginOperation() else { return }
        defer { resumeAction(); isBusy = false }
        var committed = false
        do {
            try await prepareAction()
            try Task.checkCancellation()
            lastClearResult = try await store.clearStatistics(modules)
            committed = true
            snapshot = nil
            try await invalidateAction(modules)
            snapshot = try await store.inspect()
            messageKey = "storage.data.cleared"
        } catch {
            if committed { errorKey = "storage.data.clearedRefreshFailed" }
            else if !(error is CancellationError) { errorKey = "storage.data.failed" }
        }
    }

    /// 磁盘整理独立于删除操作。暂停统计期间使用 SQLite 自身回收空间，不直接操作 WAL 文件。
    func compact() async {
        guard beginOperation() else { return }
        defer { resumeAction(); isBusy = false }
        do {
            try await prepareAction()
            try Task.checkCancellation()
            snapshot = try await store.compact()
            messageKey = "storage.compact.completed"
        } catch is CancellationError { }
        catch { errorKey = "storage.compact.failed" }
    }

    private func beginOperation() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorKey = nil
        messageKey = nil
        lastClearResult = nil
        return true
    }
}
