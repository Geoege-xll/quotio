import Foundation

extension QuotaViewModel {
    /// 批量、单提供商、单账号共用本会话的已确认凭据。CPA 已支持时即使取数失败也不试另一条路径。
    /// 仅 CPA 未支持、且存在精确补查能力时允许补查，补查仍使用本次目录的单个认证文件。
    func refreshCPAQuotas(provider: AIProvider, accountKey: String?, directory: [AuthFile],
                          context: RefreshContext, client: ManagementAPIClient) async {
        let usesCPA = CPAQuotaFetcher.supports(provider)
        guard usesCPA || CPAQuotaFetcher.supportsSupplemental(provider),
              canCommitQuotaRefresh(context, client: client) else { return }

        let providerFiles = directory.filter { $0.providerType == provider }
        let matching: [AuthFile]
        if let accountKey {
            let exact = providerFiles.filter { $0.quotaLookupKey == accountKey }
            let legacy = providerFiles.filter { $0.legacyQuotaLookupKeys.contains(accountKey) }
            // 老固定项只有唯一匹配时才迁移。暂未确认、已删除或歧义的键都不发出额度请求。
            matching = exact.isEmpty && legacy.count == 1 ? legacy : exact
        } else {
            matching = providerFiles
        }

        // 若多个真实文件投影到同一旧键，当前 UI 无法区分两条结果，跳过歧义，避免并发互相覆盖。
        let counts = Dictionary(grouping: providerFiles, by: \.quotaLookupKey)
        let files = matching.filter { !$0.disabled && counts[$0.quotaLookupKey]?.count == 1 }
        guard !files.isEmpty else { return }

        await withTaskGroup(of: (AuthFile, Result<ProviderQuotaData, any Error>).self) { group in
            for file in files {
                // 精确补查可能在一次额度刷新里发出多条请求。每次出站都复核原客户端和同一目录条目，
                // 即使启动刷新的是菜单或页面的独立任务，代理停机、凭据变化后也不能继续访问提供商。
                let fetcher = CPAQuotaFetcher(client: client, copilot: copilotFetcher, kiro: kiroFetcher,
                    isCurrent: { [weak self] in
                        guard let self else { return false }
                        return await self.canUseCPAQuotaFile(file, context: context, client: client)
                    })
                group.addTask {
                    do {
                        let quota = try await (usesCPA ? fetcher.fetch(file: file) : fetcher.fetchSupplemental(file: file))
                        return (file, .success(quota))
                    } catch {
                        return (file, .failure(error))
                    }
                }
            }
            for await (file, result) in group {
                guard canCommitQuotaRefresh(context, client: client) else { group.cancelAll(); return }
                guard canUseCPAQuotaFile(file, context: context, client: client) else { continue }
                let key = file.quotaLookupKey
                let account = QuotaAccountID(provider: provider, accountKey: key)
                var quota: ProviderQuotaData
                switch result {
                case .success(let fetched) where !fetched.isForbidden:
                    quota = fetched
                case .success:
                    recordAccountQuotaFailure(account, error: QuotaFetchError.forbidden)
                    continue
                case .failure(let error):
                    recordAccountQuotaFailure(account, error: error)
                    continue
                }
                // 失败只登记状态，旧值、订阅和成功时间一律保留。实际成功才标记额度来源。
                quota.accountDisplayName = quota.accountDisplayName ?? file.quotaDisplayName
                quota.refreshSource = usesCPA ? .cpa : .matchedCredential
                providerQuotas[provider, default: [:]][key] = quota
                if provider == .antigravity {
                    subscriptionInfos[provider, default: [:]][key] = quota.subscriptionInfo
                }
                monitorAccountIssues.removeValue(forKey: account)
                recordAccountQuotaSuccess(at: quota.lastUpdated)
            }
        }
    }

    /// 同一判断用于补查出站和额度写回。其他入口可能刷新了目录；新出现的歧义键、
    /// 禁用或换号都让原请求失效。冷却、权重等显示字段的变动不影响额度归属。
    private func canUseCPAQuotaFile(_ file: AuthFile, context: RefreshContext, client: ManagementAPIClient) -> Bool {
        guard canCommitQuotaRefresh(context, client: client) else { return false }
        let matches = authFiles.filter { $0.providerType == file.providerType && $0.quotaLookupKey == file.quotaLookupKey }
        guard matches.count == 1, let current = matches.first else { return false }
        return current.id == file.id && current.name == file.name && current.authIndex == file.authIndex
            && current.account == file.account && current.email == file.email && current.quotaMetadata == file.quotaMetadata
            && !current.disabled && current.unavailable == file.unavailable && current.runtimeOnly == file.runtimeOnly
    }

    /// 错误只转换为可信状态码和本地文案，不把上游任意正文带进额度卡片或存储。
    /// 正常取消不登记失败，也不会冲掉上次查询成功后的状态。
    func recordAccountQuotaFailure(_ account: QuotaAccountID, error: any Error) {
        guard let message = Self.accountQuotaFailureMessage(error) else { return }
        monitorAccountIssues[account] = MonitorRefreshIssue(message: message, occurredAt: Date())
    }

    static func accountQuotaFailureMessage(_ error: any Error) -> String? {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
        let status: Int?
        if case .httpError(let code) = error as? QuotaFetchError {
            status = code
        } else if case .httpError(let code) = error as? APIError {
            status = code
        } else {
            status = nil
        }
        let message: String
        if (error as? URLError)?.code == .timedOut {
            message = "remote.error.timeout".localized()
        } else {
            switch status {
            case 401, 403: message = "remote.error.forbidden".localized()
            case 408, 504: message = "remote.error.timeout".localized()
            case 429: message = "routing.failure.rateLimited.title".localized()
            default:
                if case .forbidden = error as? QuotaFetchError {
                    message = "remote.error.forbidden".localized()
                } else {
                    message = "monitor.refresh.failed".localized()
                }
            }
        }
        return status.map { "\(message) (HTTP \($0))" } ?? message
    }

}
