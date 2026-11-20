import Foundation

/// 上次成功目录及额度的只读展示副本。目录采用字段白名单，永远不编码原始管理响应、
/// 认证文件、磁盘路径、路由元数据或可能包含上游响应正文的错误文本。
nonisolated struct CPAAccountQuotaSnapshot: Codable {
    static let preferenceKey = "persisted.cpaAccountQuotaSnapshot.v1"

    private struct Account: Codable {
        let id: String
        let name: String
        let provider: String
        let label: String?
        let status: String
        let disabled: Bool
        let unavailable: Bool
        let email: String?
        let account: String?
        let authIndex: String?
        let githubHost: String?
        let accountType: String?
        let lastRefresh: String?

        init(_ file: AuthFile) {
            id = file.id
            name = file.name
            provider = file.provider
            label = file.label
            status = file.status
            disabled = file.disabled
            unavailable = file.unavailable
            email = file.email
            account = file.account
            // 索引只作为原额度字典的稳定键组件。恢复后必须重新确认当前目录才能发起操作。
            authIndex = file.authIndex
            githubHost = file.quotaMetadata.githubHost
            accountType = file.accountType
            lastRefresh = file.lastRefresh
        }

        var file: AuthFile {
            var metadata = AuthFileQuotaMetadata()
            metadata.githubHost = githubHost
            return AuthFile(id: id, name: name, provider: provider, label: label, status: status,
                            disabled: disabled, unavailable: unavailable, email: email,
                            accountType: accountType, account: account, authIndex: authIndex,
                            lastRefresh: lastRefresh, quotaMetadata: metadata)
        }
    }

    private let accounts: [Account]
    let quotas: [AIProvider: [String: ProviderQuotaData]]
    let lastQuotaRefreshTime: Date?

    var authFiles: [AuthFile] { accounts.map(\.file) }

    init(authFiles: [AuthFile], quotas: [AIProvider: [String: ProviderQuotaData]], lastQuotaRefreshTime: Date?) {
        accounts = authFiles.map(Account.init)
        // ProviderQuotaData 是已解析的展示值。去掉仅供其他来源归并的标识和未经筛选的提示文字；
        // 原额度、成功时间、周期、计量和账户套餐仍可直接供页面与菜单栏消费。
        self.quotas = quotas.mapValues { $0.mapValues { quota in
            var safeQuota = quota
            safeQuota.monitorAccountIdentity = nil
            safeQuota.models = quota.models.map { model in
                var safeModel = model
                safeModel.tooltip = nil
                return safeModel
            }
            if let subscription = quota.subscriptionInfo {
                let displayTier = subscription.paidTier ?? subscription.currentTier
                let safeTier = displayTier.map {
                    SubscriptionTier(id: $0.id, name: $0.name, description: $0.description,
                                     privacyNotice: nil, isDefault: nil, upgradeSubscriptionUri: nil,
                                     upgradeSubscriptionText: nil, upgradeSubscriptionType: nil, userDefinedCloudaicompanionProject: nil)
                }
                safeQuota.subscriptionInfo = SubscriptionInfo(
                    currentTier: safeTier, allowedTiers: nil, cloudaicompanionProject: nil,
                    gcpManaged: subscription.gcpManaged, upgradeSubscriptionUri: nil, paidTier: nil)
            }
            return safeQuota
        } }
        self.lastQuotaRefreshTime = lastQuotaRefreshTime
    }
}
