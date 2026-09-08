import SwiftUI

/// 所有维护入口共用应用级实例。切换侧栏、语言或关闭设置页不会创建第二个维护锁，
/// 防止第一轮清理尚未完成时，重开的页面再次暂停／恢复采集并引入迟到写入。
@MainActor @Observable
final class AnalyticsMaintenanceCoordinator {
    private(set) var service: StorageMaintenanceService?

    func configure(clientUsage: ClientUsageViewModel, callAnalytics: CallAnalyticsViewModel,
                   usage: UsageStatisticsStore, store: StorageMaintenanceStore = StorageMaintenanceStore()) {
        guard service == nil else { return }
        service = StorageMaintenanceService(
            store: store,
            prepare: {
                await clientUsage.suspendForMaintenance()
                await callAnalytics.suspendForMaintenance()
                try await usage.suspendForMaintenance()
            },
            invalidate: { modules in
                // 删除已经提交后，任何一个模块读取失败都不能阻断其他模块清除旧缓存。
                // 每个 reload 先发布空状态并释放缓存；全部尝试完成后才交由服务报告首个错误和恢复采集。
                var firstError: Error?
                if modules.contains(.clientUsage) {
                    do { try await clientUsage.reloadAfterMaintenance() } catch { firstError = error }
                }
                if modules.contains(.callAnalytics) {
                    do { try await callAnalytics.reloadAfterMaintenance() } catch { firstError = firstError ?? error }
                }
                if modules.contains(.dashboard) {
                    do { try await usage.reloadAfterMaintenance() } catch { firstError = firstError ?? error }
                }
                if let firstError { throw firstError }
            },
            resume: {
                clientUsage.resumeAfterMaintenance()
                callAnalytics.resumeAfterMaintenance()
                usage.resumeAfterMaintenance()
            },
            clearCaches: {
                await clientUsage.clearMemoryCaches()
                callAnalytics.clearMemoryCaches()
                await usage.clearMemoryCaches()
                ImageCacheService.shared.clearCache()
                URLCache.shared.removeAllCachedResponses()
            }
        )
    }
}

/// 在设置导航目的地连接应用已有实例，避免维护页创建第二套扫描器或队列消费者。
/// 服务持有的异步操作可以在页面关闭后完成清理与恢复，不能留下永久暂停的采集状态。
struct StorageDataDestination: View {
    @Environment(QuotaViewModel.self) private var quota
    @Environment(ClientUsageViewModel.self) private var clientUsage
    @Environment(CallAnalyticsViewModel.self) private var callAnalytics
    @Environment(AnalyticsMaintenanceCoordinator.self) private var coordinator

    var body: some View {
        Group {
            if let service = coordinator.service { StorageDataScreen(service: service) }
            else { ProgressView().controlSize(.small) }
        }
        .task {
            coordinator.configure(clientUsage: clientUsage, callAnalytics: callAnalytics, usage: quota.usageMonitor)
        }
    }
}
