//
//  QuotaViewModel+CPAQuotaRefresh.swift
//  Quotio
//

import Foundation

/// CPA 运行期间按真实认证凭据获取额度的原接管方法。
/// 扩展继续读取主类同一管理客户端和运行会话，不创建客户端、任务持有者或第二个用量队列消费者。
/// 精确凭据键优先、旧邮箱仅唯一匹配时迁移、套餐与额度同身份清理的规则保持原样。
/// 保留原 TaskGroup 并发、逐结果会话复核、取消路径及失败保留；返回 true 仍表示已接管而非成功。
extension QuotaViewModel {
    /// 整个接管事务完整迁移，目录发布、请求分发、逐账号写回和最终错误清理之间不新增挂起点。
    /// 代理运行时复用 CPA 的账号索引和鉴权，批量与单账号刷新走完全相同的路径。
    /// 返回 true 表示本次已由 CPA 接管；失败保留旧值并标记过期，不能再用本机另一账号覆盖。
    /// 此方法只调用配额接口，绝不消费 /usage-queue 或改写客户端历史账本。
    func refreshCPAQuotas(provider: AIProvider, accountKey: String? = nil) async -> Bool {
        let context = refreshContext()
        guard !modeManager.isMonitorMode, proxyManager.proxyStatus.running,
              let apiClient, CPAQuotaFetcher.supports(provider) else { return false }
        let session = proxyManager.runtimeSessionID
        // 配额批量刷新可能由独立任务触发；账号/模式世代之外还必须校验代理会话，
        // 避免停止后的取消错误把旧额度标为失败，或覆盖新服务的账号列表。
        func canCommitSession() -> Bool {
            canCommit(context) && !Task.isCancelled && self.apiClient === apiClient
                && proxyManager.runtimeSessionID == session && proxyManager.proxyStatus.running
        }
        let fetcher = CPAQuotaFetcher(client: apiClient)
        do {
            let currentFiles = try await apiClient.fetchAuthFiles()
            guard canCommitSession() else { return true }
            // 列表与快照使用同一批 CPA 凭据，避免列表仍拿旧邮箱键而新结果已经改用凭据键。
            authFiles = AuthFileIdentity.deduplicated(currentFiles)
            reconcileAccountQuotaIdentities()
            let providerFiles = authFiles.filter { $0.providerType == provider && !$0.disabled }
            let files: [AuthFile]
            if let accountKey {
                let exactMatches = providerFiles.filter { $0.quotaLookupKey == accountKey }
                let legacyMatches = providerFiles.filter { $0.legacyQuotaLookupKeys.contains(accountKey) }
                // 旧菜单或缓存可能只记录邮箱。只有一对一匹配才允许迁移，绝不猜测同邮箱凭据。
                files = exactMatches.isEmpty
                    ? (legacyMatches.count == 1 ? legacyMatches : [])
                    : exactMatches
                guard !files.isEmpty else {
                    providerQuotas[provider]?.removeValue(forKey: accountKey)
                    if provider == .antigravity { subscriptionInfos[provider]?.removeValue(forKey: accountKey) }
                    monitorAccountIssues[QuotaAccountID(provider: provider, accountKey: accountKey)] = MonitorRefreshIssue(
                        message: "monitor.refresh.failed".localized(), occurredAt: Date()
                    )
                    return true
                }
                if files.first?.quotaLookupKey != accountKey {
                    providerQuotas[provider]?.removeValue(forKey: accountKey)
                    monitorAccountIssues.removeValue(forKey: QuotaAccountID(provider: provider, accountKey: accountKey))
                    if provider == .antigravity { subscriptionInfos[provider]?.removeValue(forKey: accountKey) }
                }
            } else {
                files = providerFiles
            }
            if accountKey == nil {
                let activeKeys = Set(files.map(\.quotaLookupKey))
                providerQuotas[provider] = providerQuotas[provider, default: [:]].filter { activeKeys.contains($0.key) }
                // 套餐和额度必须采用相同账号身份；移除旧邮箱槽位，避免套餐被另一个项目复用。
                if provider == .antigravity {
                    // 外层按提供商隔离，只清理当前提供商的账号，不能过滤其他提供商的订阅。
                    subscriptionInfos[provider] = subscriptionInfos[provider, default: [:]].filter { activeKeys.contains($0.key) }
                }
            }
            await withTaskGroup(of: (String, ProviderQuotaData?).self) { group in
                for file in files {
                    group.addTask { (file.quotaLookupKey, try? await fetcher.fetch(file: file)) }
                }
                for await (key, quota) in group {
                    guard canCommitSession() else { group.cancelAll(); return }
                    let id = QuotaAccountID(provider: provider, accountKey: key)
                    if var quota {
                        // 内部键只负责隔离凭据，界面继续显示可读邮箱或账号标签，不泄露认证信息。
                        if quota.accountDisplayName == nil {
                            quota.accountDisplayName = files.first { $0.quotaLookupKey == key }?.quotaDisplayName
                        }
                        providerQuotas[provider, default: [:]][key] = quota
                        if provider == .antigravity {
                            // 附加套餐查询失败时移除旧套餐，避免新额度快照搭配陈旧权益信息。
                            subscriptionInfos[provider, default: [:]][key] = quota.subscriptionInfo
                        }
                        monitorAccountIssues.removeValue(forKey: id)
                    } else {
                        monitorAccountIssues[id] = MonitorRefreshIssue(message: "monitor.refresh.failed".localized(), occurredAt: Date())
                    }
                }
            }
            guard canCommitSession() else { return true }
            monitorIssues.removeValue(forKey: provider)
        } catch {
            guard canCommitSession(), !(error is CancellationError) else { return true }
            monitorIssues[provider] = MonitorRefreshIssue(message: "monitor.refresh.failed".localized(), occurredAt: Date())
        }
        return true
    }
}
