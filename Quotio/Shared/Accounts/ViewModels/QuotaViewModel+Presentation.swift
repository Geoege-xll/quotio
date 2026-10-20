//
//  QuotaViewModel+Presentation.swift
//  Quotio
//

import Foundation

/// 原刷新进度、监控状态及认证目录的只读展示计算，继续读取同一个 QuotaViewModel 的当前状态。
/// 本扩展不保存快照、不持有任务、不发布状态或修改偏好；每次读取沿用原计算与时间判定。
/// 原属性／方法名称、MainActor 与 nonisolated 边界保持原样，界面与刷新协调仍使用同一套规则。
/// 私有槽位、客户端、预热状态及懒加载依赖的读取入口留在主类，避免仅为归类而扩大可变私有存储访问。
extension QuotaViewModel {
    /// 每次读取即时投影原提供商／账号刷新集合，不建立展示缓存或额外加载状态。
    var isLoadingQuotas: Bool {
        !refreshingProviders.isEmpty || !refreshingAccounts.isEmpty
    }

    /// 提供商展示仍同时检查整提供商与单账号刷新，不改变两种原刷新进度的含义。
    func isRefreshing(provider: AIProvider) -> Bool {
        refreshingProviders.contains(provider)
            || refreshingAccounts.contains(where: { $0.provider == provider })
    }

    /// 账号展示仍复用原刷新集合，整提供商刷新继续使所属账号呈现刷新状态。
    func isRefreshing(account: QuotaAccountID) -> Bool {
        refreshingAccounts.contains(account) || refreshingProviders.contains(account.provider)
    }

    /// 保持原提供商能力规则，主类槽位申请与界面继续调用同一方法，不另设能力列表。
    func supportsScopedRefresh(for provider: AIProvider) -> Bool {
        switch provider {
        case .qwen, .iflow, .vertex, .minimax:
            return false
        default:
            return true
        }
    }

    /// 保留原账号错误优先级、成功时间比较及实时频率读取；状态仅计算，不在这里持久化或清除错误。
    func monitorStatus(for account: MonitorAccount) -> (status: String?, message: String?) {
        let updated = Self.monitorLastUpdated(for: account, providerQuotas: providerQuotas)
        let accountID = QuotaAccountID(provider: account.provider, accountKey: account.accountKey)
        if let issue = monitorAccountIssues[accountID],
           updated == nil || updated! <= issue.occurredAt {
            return ("outdated", issue.message)
        }
        if let issue = monitorIssues[account.provider],
           updated == nil || updated! <= issue.occurredAt {
            return ("outdated", issue.message)
        }
        guard let updated else { return (nil, nil) }
        let staleAfter = refreshSettings.refreshCadence.intervalSeconds ?? 600
        if Date().timeIntervalSince(updated) > staleAfter {
            return (
                "outdated",
                String(format: "monitor.status.outdated".localized(), updated.formatted(date: .abbreviated, time: .shortened))
            )
        }
        return (
            "ready",
            String(format: "monitor.status.updated".localized(), updated.formatted(date: .omitted, time: .shortened))
        )
    }

    /// 保留 nonisolated static 和原精确账号查找，不借用同提供商其他账号的成功时间。
    nonisolated static func monitorLastUpdated(
        for account: MonitorAccount,
        providerQuotas: [AIProvider: [String: ProviderQuotaData]]
    ) -> Date? {
        providerQuotas[account.provider]?[account.accountKey]?.lastUpdated
    }

    /// 每次按当前认证目录分组，保留原条目顺序和未知提供商过滤，不去重或改变目录身份。
    var authFilesByProvider: [AIProvider: [AuthFile]] {
        var result: [AIProvider: [AuthFile]] = [:]
        for file in authFiles {
            if let provider = file.providerType {
                result[provider, default: []].append(file)
            }
        }
        return result
    }

    /// 继续按原认证目录条目计数，不把额度缓存或本地凭据叠加成新账号。
    var totalAccounts: Int { authFiles.count }

    /// 继续使用 AuthFile.isReady 的原兼容规则，原生 active 与旧 ready 等语义不在展示扩展重写。
    var readyAccounts: Int { authFiles.filter { $0.isReady }.count }
}
