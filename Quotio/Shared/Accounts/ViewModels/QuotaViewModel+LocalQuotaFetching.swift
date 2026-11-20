import Foundation

extension QuotaViewModel {
    /// 本地额度路径仅服务用户显式添加的连接。允许的账号键来自现有配置，不接受本机登录、
    /// 认证文件扫描或上次成功的额度作为取数授权。每次只对选定的 Key 发送请求。
    func refreshConfiguredAccountQuotas(provider: AIProvider, accountKey: String?,
                                        context: RefreshContext, client: ManagementAPIClient) async {
        let providers = configuredQuotaProviders.filter(\.isEnabled)
        let warpTokens = WarpService.shared.tokens.filter(\.isEnabled)
        let keys = MenuBarAccountCatalog.items(authFiles: [], customProviders: providers, warpTokens: warpTokens)
            .filter { $0.aiProvider == provider && (accountKey == nil || $0.accountKey == accountKey) }
            .map(\.accountKey)
        // CPA 同键优先。名称型旧连接改为只匹配唯一配置，避免命中另一条 Key 或另一个工作区。
        let cpaKeys = Set(authFiles.filter { $0.providerType == provider }.map(\.quotaLookupKey))
        for key in keys where !cpaKeys.contains(key) {
            guard canCommitQuotaRefresh(context, client: client) else { return }
            #if DEBUG
            let quota: ProviderQuotaData?
            if let hook = localQuotaFetchHookForTesting {
                quota = await hook(provider)[key]
            } else {
                quota = await fetchConfiguredAccountQuota(provider: provider, key: key,
                                                          providers: providers, warpTokens: warpTokens)
            }
            #else
            let quota = await fetchConfiguredAccountQuota(provider: provider, key: key,
                                                          providers: providers, warpTokens: warpTokens)
            #endif
            guard canCommitQuotaRefresh(context, client: client) else { return }
            guard !authFiles.contains(where: { $0.providerType == provider && $0.quotaLookupKey == key }),
                  MenuBarAccountCatalog.items(authFiles: [], customProviders: configuredQuotaProviders,
                    warpTokens: WarpService.shared.tokens).contains(where: {
                        $0.aiProvider == provider && $0.accountKey == key
                    }) else { continue }
            let account = QuotaAccountID(provider: provider, accountKey: key)
            guard var quota, !quota.isForbidden else {
                monitorAccountIssues[account] = MonitorRefreshIssue(
                    message: "monitor.refresh.failed".localized(), occurredAt: Date())
                continue
            }
            quota.refreshSource = .explicitConnection
            providerQuotas[provider, default: [:]][key] = quota
            monitorAccountIssues.removeValue(forKey: account)
            recordAccountQuotaSuccess(at: quota.lastUpdated)
        }
    }

    private func fetchConfiguredAccountQuota(provider: AIProvider, key: String, providers: [CustomProvider],
                                              warpTokens: [WarpService.WarpToken]) async -> ProviderQuotaData? {
        let type: CustomProviderType
        let keyBuilder: (UUID, UUID) -> String
        switch provider {
        case .glm: type = .glmCompatibility; keyBuilder = GLMQuotaFetcher.quotaAccountKey
        case .deepseek: type = .deepseekCompatibility; keyBuilder = DeepSeekQuotaFetcher.quotaAccountKey
        case .moonshot: type = .moonshotCompatibility; keyBuilder = MoonshotQuotaFetcher.quotaAccountKey
        case .warp:
            let matches = warpTokens.filter { $0.name == key }
            guard matches.count == 1, let token = matches.first else { return nil }
            return try? await warpFetcher.fetchQuota(apiKey: token.token)
        case .clinePass:
            let matches = providers.filter { $0.type == .clinePass && $0.name == key }
            guard matches.count == 1, let connection = matches.first, connection.apiKeys.count == 1,
                  let credential = connection.apiKeys.first else { return nil }
            return try? await clinePassFetcher.fetchQuota(apiKey: credential.apiKey)
        default:
            return nil
        }

        let matches = providers.filter { $0.type == type }.flatMap { provider in
            provider.apiKeys.filter { keyBuilder(provider.id, $0.id) == key }.map { (provider, $0) }
        }
        guard matches.count == 1, let (connection, credential) = matches.first else { return nil }
        var quota: ProviderQuotaData?
        switch provider {
        case .glm:
            quota = try? await glmFetcher.fetchQuota(apiKey: credential.apiKey, baseURL: connection.baseURL)
        case .deepseek:
            quota = try? await deepseekFetcher.fetchQuota(apiKey: credential.apiKey, baseURL: connection.baseURL)
        case .moonshot:
            quota = try? await moonshotFetcher.fetchQuota(apiKey: credential.apiKey, baseURL: connection.baseURL)
        default:
            return nil
        }
        if let index = connection.apiKeys.firstIndex(where: { $0.id == credential.id }), connection.apiKeys.count > 1 {
            quota?.accountDisplayName = "\(connection.name) · \(index + 1)"
        } else {
            quota?.accountDisplayName = connection.name
        }
        return quota
    }
}
