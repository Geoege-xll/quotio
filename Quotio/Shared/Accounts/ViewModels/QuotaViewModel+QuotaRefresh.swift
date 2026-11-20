import Foundation

extension QuotaViewModel {
    /// CPA 定时任务仍完整等待同一轮。API Key 读取有自己的互斥，失败或编辑中不阻止
    /// 已确认目录的额度读取；目录失败则只保留上次快照。
    @discardableResult
    func refreshScheduledCPAData(refreshQuotas: () async -> Void) async -> Bool {
        let source = refreshContext()
        guard canRefreshAccountQuotas, let client = apiClient else { return false }
        _ = await refreshData(refreshQuotas: false)
        guard canUseRefreshSource(source), apiClient === client else { return false }
        if hasCurrentCPAAccountDirectory { await refreshQuotas() }
        return canUseRefreshSource(source) && apiClient === client
    }

    /// 当前客户端是认证目录的唯一来源。任何请求失败均保留目录和额度原值，停机时没有本地枚举。
    private func fetchCurrentAccountDirectory(client: ManagementAPIClient) async -> [AuthFile]? {
        let source = refreshContext()
        func isCurrentSource() -> Bool {
            canUseRefreshSource(source) && canRefreshAccountQuotas && apiClient === client
        }
        guard isCurrentSource() else { return nil }
        do {
            return try await readCPAAuthDirectory(read: { try await client.fetchAuthFiles() },
                                                  isCurrentSource: isCurrentSource)
        } catch {
            // 目录事务已在当前世代记录可见错误；返回 nil 以阻止本轮额度查询。
            return nil
        }
    }

    #if DEBUG
    /// 离线夹具只替换目录 I/O，真实删除世代和目录提交顺序仍由生产代码校验。
    func refreshAuthDirectoryForTesting(read: () async throws -> [AuthFile]) async throws -> Bool {
        try await readCPAAuthDirectory(read: read, isCurrentSource: { true }) != nil
    }
    #endif

    /// 目录、API Key 及仪表盘完成判定仍维持各自的提交边界。入口不触碰用量消费者。
    @discardableResult
    func refreshData(refreshQuotas: Bool = true) async -> Bool {
        let source = refreshContext()
        guard canRefreshAccountQuotas, let client = apiClient,
              await fetchCurrentAccountDirectory(client: client) != nil else { return false }
        guard await refreshAPIKeySnapshot(using: client, clearingErrorOnSuccess: true),
              canUseRefreshSource(source), apiClient === client, hasCurrentCPAAccountDirectory else { return false }

        checkAccountStatusChanges()
        if refreshQuotas && isQuotaRefreshDueForPolling() && !isLoadingQuotas {
            Task { [weak self] in
                guard let self, canUseRefreshSource(source), apiClient === client else { return }
                await refreshAllQuotas()
            }
        }
        return true
    }

    /// 同一手动状态合并账号页与菜单栏的重复点击。目录读取失败、取消或停机都不会继续取数。
    func manualRefresh() async {
        await manualAccountRefreshState.perform {
            let source = refreshContext()
            for step in AccountRefreshStep.plan(proxyRunning: canRefreshAccountQuotas) {
                guard canUseRefreshSource(source) else { return }
                #if DEBUG
                if let hook = accountRefreshStepHookForTesting { await hook(step); continue }
                #endif
                switch step {
                case .cpaDirectory:
                    await refreshData(refreshQuotas: false)
                    guard hasCurrentCPAAccountDirectory else { return }
                case .cpaQuotas:
                    await refreshAllQuotas(waitForAvailability: true)
                }
            }
        }
    }

    /// 多个入口复用原槽位与等待策略。一次批量请求共享一份成功返回的目录，
    /// 避免为每种提供商重复请求或让一次目录故障只影响组内部分账号。
    func refreshAllQuotas(waitForAvailability: Bool = false) async {
        guard canRefreshAccountQuotas, let client = apiClient else { return }
        let source = refreshContext()
        let providers = Set(AIProvider.allCases.filter { supportsScopedRefresh(for: $0) })
        guard await QuotaRefreshAvailability.acquire(wait: waitForAvailability,
            isCurrent: { canUseRefreshSource(source) && apiClient === client },
            claim: { beginBatchRefresh(providers: providers) }) else { return }
        defer { endBatchRefresh(providers: providers) }
        guard canUseRefreshSource(source), apiClient === client else { return }
        let context = refreshContext()

        // 私有节流仍记录本轮尝试；界面展示时间只由实际成功的账号结果推进。
        recordQuotaRefreshStart()
        guard let directory = await fetchCurrentAccountDirectory(client: client),
              canCommitQuotaRefresh(context, client: client) else { return }
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                // 子任务只携带可安全传递的目录和会话值，回到 ViewModel 的主执行器后才读取或写入状态。
                group.addTask { @Sendable [self, provider, directory, context, client] in
                    await refreshKnownProviderQuotas(provider, accountKey: nil, directory: directory,
                                                     context: context, client: client)
                }
            }
        }
        await finishScopedRefresh(context: context)
    }

    /// 原调用方共用同一个 CPA 批量入口。
    func refreshQuotasUnified(waitForAvailability: Bool = false) async {
        await refreshAllQuotas(waitForAvailability: waitForAvailability)
    }

    func refreshQuota(for provider: AIProvider, waitForAvailability: Bool = false) async {
        guard canRefreshAccountQuotas, let client = apiClient, supportsScopedRefresh(for: provider) else { return }
        let source = refreshContext()
        guard await QuotaRefreshAvailability.acquire(wait: waitForAvailability,
            isCurrent: { canUseRefreshSource(source) && apiClient === client },
            claim: { beginScopedRefresh(provider: provider) }) else { return }
        defer { endScopedRefresh(provider: provider) }
        guard canUseRefreshSource(source), apiClient === client else { return }
        let context = refreshContext()
        guard let directory = await fetchCurrentAccountDirectory(client: client),
              canCommitQuotaRefresh(context, client: client) else { return }

        await refreshKnownProviderQuotas(provider, accountKey: nil, directory: directory, context: context, client: client)
        await finishScopedRefresh(context: context)
    }

    func refreshQuota(for account: QuotaAccountID) async {
        guard canRefreshAccountQuotas, let client = apiClient,
              beginScopedRefresh(provider: account.provider, account: account) else { return }
        defer { endScopedRefresh(provider: account.provider, account: account) }
        let context = refreshContext()
        guard let directory = await fetchCurrentAccountDirectory(client: client),
              canCommitQuotaRefresh(context, client: client) else { return }

        await refreshKnownProviderQuotas(account.provider, accountKey: account.accountKey,
                                         directory: directory, context: context, client: client)
        await finishScopedRefresh(context: context)
    }

    func canCommitQuotaRefresh(_ context: RefreshContext, client: ManagementAPIClient) -> Bool {
        canCommit(context) && hasCurrentCPAAccountDirectory && apiClient === client
    }

    private func refreshKnownProviderQuotas(_ provider: AIProvider, accountKey: String?, directory: [AuthFile],
                                            context: RefreshContext, client: ManagementAPIClient) async {
        guard canCommitQuotaRefresh(context, client: client) else { return }
        await refreshCPAQuotas(provider: provider, accountKey: accountKey, directory: directory,
                               context: context, client: client)
        guard canCommitQuotaRefresh(context, client: client) else { return }
        if provider.isImportedFromLocalIDE {
            await refreshImportedIDEQuotas(provider: provider, accountKey: accountKey, context: context, client: client)
        } else {
            await refreshConfiguredAccountQuotas(provider: provider, accountKey: accountKey,
                                                  context: context, client: client)
        }
    }

    /// 保留原调用入口供配置页，所有触发仍走同一运行态与目录检查。
    func refreshQuotaForProvider(_ provider: AIProvider) async {
        await refreshQuota(for: provider)
    }

    /// 槽位释放仍由各入口 defer 处理。收尾只同步界面和通知，不能人为改变成功时间。
    func finishScopedRefresh(context: RefreshContext) async {
        guard canCommit(context) else { return }
        checkQuotaNotifications()
        syncMenuBarSelection()
    }
}
