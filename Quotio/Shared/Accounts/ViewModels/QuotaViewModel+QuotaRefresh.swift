//
//  QuotaViewModel+QuotaRefresh.swift
//  Quotio
//

import Foundation

/// 目录读取、手动操作、批量及单提供商／单账号刷新的原流程，仍属于应用持有的同一个 QuotaViewModel。
/// 本文件不持有存储、Task 句柄或新的协调器；全部账号、模式、客户端、额度和手动刷新状态继续由主类持有。
/// 刷新槽位的实际写入和取消／会话校验仍调用主类原入口，不开放 private(set) 或可变私有存储。
/// 私有节流时间只经主类同步入口判断和记录；保留原调用位置及两条批量路径不同的时间写入顺序，不新增 await。
/// 原 async let、Task、defer、失败回退及挂起后的提交检查完整保留；后台与手动刷新继续各自遵守原合并规则。
/// 目录提交与失败持久化辅助留在同文件并继续 private，统一收尾继续复用原方法，不另建一套发布或通知逻辑。
extension QuotaViewModel {
    /// CPA 定时到期的一轮刷新。调度来自主类唯一 refreshTask，不再检查 lastQuotaRefresh 的机会性节流。
    /// 目录／密钥仍按原入口读取，返回值继续服务仪表盘的严格完成判定；密钥失败、被新读取取代
    /// 或正在编辑时，不应阻止独立的账号额度查询。额度获取器会按同一凭据重新读取所需目录。
    /// 闭包在生产中固定为原批量入口并等待槽位；测试仅缩小外部取数范围，不移动状态或任务所有权。
    /// 返回值仅表示轮次结束时来源仍有效，供原定时器保留错误恢复计数；不替代目录的成功返回。
    @discardableResult
    func refreshScheduledCPAData(refreshQuotas: () async -> Void) async -> Bool {
        let source = refreshContext()
        guard !modeManager.isMonitorMode, proxyManager.proxyStatus.running, let client = apiClient else { return false }
        func isCurrentSource() -> Bool {
            canUseRefreshSource(source) && !modeManager.isMonitorMode
                && proxyManager.proxyStatus.running && apiClient === client
        }
        guard isCurrentSource() else { return false }
        _ = await refreshData(refreshQuotas: false)
        guard isCurrentSource() else { return false }
        await refreshQuotas()
        return isCurrentSource()
    }

    /// 本地目录仍先读取再检查账号／模式／代理会话世代，之后按原顺序发布并归一身份。
    /// Load auth files directly from filesystem
    func loadDirectAuthFiles() async {
        let context = refreshContext()
        let files = await directAuthService.scanAllAuthFiles()
        let accounts = modeManager.isMonitorMode
            ? await discoverMonitorAccounts(merging: providerQuotas) : monitorAccounts
        guard canCommit(context) else { return }
        directAuthFiles = files
        monitorAccounts = accounts
        reconcileAccountQuotaIdentities()
    }

    /// 目录事务辅助与其调用方同文件维护并继续保持 private；原目录去重及挂起后双重校验不变。
    /// 目录读取与额度读取采用相同的账号世代。删除成功后的新目录先发布时，
    /// 删除前挂起的旧目录不能随后覆盖它；读取闭包仅负责外部 I/O，提交规则唯一。
    private func refreshAuthDirectorySnapshot(read: () async throws -> [AuthFile],
                                               isCurrentSource: () -> Bool) async throws -> Bool {
        let context = refreshContext()
        let files = try await read()
        guard canCommit(context), isCurrentSource() else { return false }
        authFiles = AuthFileIdentity.deduplicated(files)
        reconcileAccountQuotaIdentities()
        return true
    }

    #if DEBUG
    /// 仅将原无状态 Debug 包装方法随目录辅助迁移；外部读取钩子和所有测试存储仍在主类。
    /// 离线夹具只替换目录读取，仍经过真实的世代检查与目录发布，避免操作运行中的 CPA。
    func refreshAuthDirectoryForTesting(read: () async throws -> [AuthFile]) async throws -> Bool {
        try await refreshAuthDirectorySnapshot(read: read, isCurrentSource: { true })
    }
    #endif

    /// CPA 目录与 API Key 仍串行读取；密钥提交交回主类统一校验读写世代，原后台 Task 不变。
    /// 明确返回本轮是否完成，仪表盘不能把过期、取消或被编辑取代的读取当作成功刷新。
    @discardableResult
    func refreshData(refreshQuotas: Bool = true) async -> Bool {
        guard let client = apiClient else { return false }
        let session = proxyManager.runtimeSessionID
        // 请求在挂起期间可能跨越一次停止/重启；只有当前客户端的结果能写回。
        func isCurrentSession() -> Bool {
            !Task.isCancelled && apiClient === client && proxyManager.proxyStatus.running
                && proxyManager.runtimeSessionID == session
        }
        guard isCurrentSession() else { return false }
        
        do {
            // Serialize requests to avoid connection contention (issue #37)
            // This reduces pressure on the connection pool
            let oldNames = Set(self.authFiles.map { $0.name })
            guard try await refreshAuthDirectorySnapshot(read: { try await client.fetchAuthFiles() },
                                                         isCurrentSource: isCurrentSession) else { return false }

            // Only update timestamp if auth files actually changed (account added/removed)
            let newNames = Set(self.authFiles.map { $0.name })
            if oldNames != newNames {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.authFilesChangedKey)
            }

            // 用量队列由独立服务采集；配额刷新不能二次消费，也不因旧 /usage 的 404 隐藏数据。
            guard await refreshAPIKeySnapshot(using: client, clearingErrorOnSuccess: true),
                  isCurrentSession() else { return false }
            
            checkAccountStatusChanges()
            
            // Prune menu bar items for accounts that no longer exist
            pruneMenuBarItems()
            
            let isQuotaRefreshDue = isQuotaRefreshDueForPolling()
            
            if refreshQuotas && isQuotaRefreshDue && !isLoadingQuotas {
                Task {
                    await refreshAllQuotas()
                }
            }
            return true
        } catch {
            if isCurrentSession(), !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    /// 手动刷新继续使用主类唯一的 ManualRefreshState 合并重复点击，并在每个原步骤之前检查来源。
    func manualRefresh() async {
        await manualAccountRefreshState.perform {
            let source = refreshContext()
            for step in AccountRefreshStep.plan(mode: modeManager.currentMode,
                                                proxyRunning: proxyManager.proxyStatus.running) {
                guard canUseRefreshSource(source) else { return }
                #if DEBUG
                if let hook = accountRefreshStepHookForTesting { await hook(step); continue }
                #endif
                switch step {
                case .directDirectory: await loadDirectAuthFiles()
                case .monitorQuotas: await refreshQuotasDirectly(force: true)
                case .cpaDirectory: await refreshData(refreshQuotas: false)
                case .cpaQuotas: await refreshAllQuotas(waitForAvailability: true)
                case .localQuotas: await refreshQuotasUnified(waitForAvailability: true)
                case .provider(let provider): await refreshQuota(for: provider, waitForAvailability: true)
                }
            }
        }
    }

    /// 保留原槽位等待与 defer 释放；私有节流记录仍先于可见时间更新，随后保持原并发和收尾顺序。
    func refreshAllQuotas(waitForAvailability: Bool = false) async {
        let source = refreshContext()
        if modeManager.isMonitorMode {
            await refreshQuotasDirectly(force: waitForAvailability)
            return
        }
        let providers: Set<AIProvider> = [
            .antigravity, .codex, .copilot, .claude, .glm, .deepseek, .moonshot, .warp, .kiro, .clinePass,
        ]
        guard await QuotaRefreshAvailability.acquire(wait: waitForAvailability, claim: {
            beginBatchRefresh(providers: providers)
        }) else { return }
        defer { endBatchRefresh(providers: providers) }
        guard canUseRefreshSource(source) else { return }
        let batchContext = refreshContext()

        recordQuotaRefreshStart()
        lastQuotaRefreshTime = Date()

        // Note: Cursor and Trae removed from auto-refresh (issue #29)
        // User must use "Scan for IDEs" to detect these
        async let antigravity: () = refreshAntigravityQuotasInternal()
        async let openai: () = refreshOpenAIQuotasInternal()
        async let copilot: () = refreshCopilotQuotasInternal()
        async let claudeCode: () = refreshClaudeCodeQuotasInternal()
        async let glm: () = refreshGlmQuotasInternal()
        async let deepseek: () = refreshDeepSeekQuotasInternal()
        async let moonshot: () = refreshMoonshotQuotasInternal()
        async let warp: () = refreshWarpQuotasInternal()
        async let kiro: () = refreshKiroQuotasInternal()
        async let clinePass: () = refreshClinePassQuotasInternal()

        _ = await (antigravity, openai, copilot, claudeCode, glm, deepseek, moonshot, warp, kiro, clinePass)
        guard canCommit(batchContext) else { return }
        reconcileAccountQuotaIdentities()

        // Refresh (not re-import) already-imported Cursor/Trae accounts (#163).
        await refreshImportedIDEQuotas()

        checkQuotaNotifications()
        pruneMenuBarItems()
        autoSelectMenuBarItems()

        notifyQuotaDataChanged()
    }

    /// 统一批量路径仍先更新可见时间再记录私有节流，与另一批量入口保持各自原来的写入顺序。
    /// Unified quota refresh - works in both Full Mode and Quota-Only Mode
    /// In Full Mode: uses direct fetchers (works without proxy)
    /// In Quota-Only Mode: uses direct fetchers + CLI fetchers
    /// Note: Cursor and Trae require explicit user scan (issue #29)
    func refreshQuotasUnified(waitForAvailability: Bool = false) async {
        let source = refreshContext()
        if modeManager.isMonitorMode {
            await refreshQuotasDirectly(force: waitForAvailability)
            return
        }
        let providers: Set<AIProvider> = [
            .antigravity, .codex, .copilot, .claude, .glm, .deepseek, .moonshot, .warp, .kiro, .clinePass,
        ]
        guard await QuotaRefreshAvailability.acquire(wait: waitForAvailability, claim: {
            beginBatchRefresh(providers: providers)
        }) else { return }
        defer { endBatchRefresh(providers: providers) }
        guard canUseRefreshSource(source) else { return }
        let batchContext = refreshContext()

        lastQuotaRefreshTime = Date()
        recordQuotaRefreshStart()

        // Refresh direct fetchers (these don't need proxy)
        // Note: Cursor and Trae removed - require explicit scan (issue #29)
        async let antigravity: () = refreshAntigravityQuotasInternal()
        async let codex: () = refreshCodexQuotasInternal(includeCLIFallback: modeManager.isMonitorMode)
        async let copilot: () = refreshCopilotQuotasInternal()
        async let claudeCode: () = refreshClaudeCodeQuotasInternal()
        async let glm: () = refreshGlmQuotasInternal()
        async let deepseek: () = refreshDeepSeekQuotasInternal()
        async let moonshot: () = refreshMoonshotQuotasInternal()
        async let warp: () = refreshWarpQuotasInternal()
        async let kiro: () = refreshKiroQuotasInternal()
        async let clinePass: () = refreshClinePassQuotasInternal()

        _ = await (antigravity, codex, copilot, claudeCode, glm, deepseek, moonshot, warp, kiro, clinePass)
        guard canCommit(batchContext) else { return }
        reconcileAccountQuotaIdentities()

        // Refresh (not re-import) already-imported Cursor/Trae accounts (#163).
        await refreshImportedIDEQuotas()

        checkQuotaNotifications()
        pruneMenuBarItems()
        autoSelectMenuBarItems()

        notifyQuotaDataChanged()
    }

    /// 单提供商仍在原位置申请槽位、复核来源并建立提交上下文；原提供商分支及统一收尾不重排。
    func refreshQuota(for provider: AIProvider, waitForAvailability: Bool = false) async {
        let source = refreshContext()
        guard await QuotaRefreshAvailability.acquire(wait: waitForAvailability, claim: {
            beginScopedRefresh(provider: provider)
        }) else { return }
        defer { endScopedRefresh(provider: provider) }
        guard canUseRefreshSource(source) else { return }
        let context = refreshContext()

        if modeManager.isMonitorMode {
            await refreshMonitorProvider(provider)
            await finishScopedRefresh(provider: provider, context: context)
            return
        }

        switch provider {
        case .antigravity:
            await refreshAntigravityQuotasInternal()
        case .codex:
            if modeManager.isMonitorMode {
                await refreshCodexQuotasInternal(includeCLIFallback: true)
            } else {
                await refreshOpenAIQuotasInternal()
            }
        case .copilot:
            await refreshCopilotQuotasInternal()
        case .claude:
            await refreshClaudeCodeQuotasInternal()
        case .cursor:
            await refreshCursorQuotasInternal()
        case .trae:
            await refreshTraeQuotasInternal()
        case .glm:
            await refreshGlmQuotasInternal()
        case .deepseek:
            await refreshDeepSeekQuotasInternal()
        case .moonshot:
            await refreshMoonshotQuotasInternal()
        case .warp:
            await refreshWarpQuotasInternal()
        case .kiro:
            await refreshKiroQuotasInternal()
        case .clinePass:
            await refreshClinePassQuotasInternal()
        case .factoryDroid:
            let quotas = await factoryDroidFetcher.fetchAllQuotas()
            guard canCommit(context) else { return }
            providerQuotas[provider] = quotas
        case .devin:
            let quotas = await devinFetcher.fetchAsProviderQuota()
            guard canCommit(context) else { return }
            providerQuotas[provider] = quotas
        case .grok:
            // 代理模式按 CPA 的凭据索引查询，避免本机凭据与页面账号不一致。
            // 使用 break 保留分支后的刷新收尾逻辑；监控模式仍由原生获取器处理。
            if await refreshCPAQuotas(provider: .grok) { break }
            let quotas = await grokFetcher.fetchAllQuotas()
            guard canCommit(context) else { return }
            providerQuotas[provider] = quotas
        case .openRouter:
            let quotas = await openRouterFetcher.fetchAllQuotas()
            guard canCommit(context) else { return }
            providerQuotas[provider] = quotas
        case .amp:
            let quotas = await ampFetcher.fetchAllQuotas()
            guard canCommit(context) else { return }
            providerQuotas[provider] = quotas
        default:
            return
        }

        await finishScopedRefresh(provider: provider, context: context)
    }

    /// 单账号仍按精确身份刷新，保留 CPA 优先、失败保留、套餐写回及 Codex 别名提交前的再次校验。
    func refreshQuota(for account: QuotaAccountID) async {
        let context = refreshContext()
        guard beginScopedRefresh(provider: account.provider, account: account) else { return }
        defer { endScopedRefresh(provider: account.provider, account: account) }

        if await refreshCPAQuotas(provider: account.provider, accountKey: account.accountKey) {
            await finishScopedRefresh(provider: account.provider, context: context)
            return
        }

        let quota: ProviderQuotaData?
        var subscription: SubscriptionInfo?

        switch account.provider {
        case .antigravity:
            let result = await antigravityFetcher.fetchData(forAccountKey: account.accountKey)
            quota = result.quota
            subscription = result.subscription
        case .codex:
            quota = modeManager.isMonitorMode
                ? await codexCLIFetcher.fetchMonitorQuota(forAccountKey: account.accountKey)
                : await codexCLIFetcher.fetchQuota(forAccountKey: account.accountKey)
        case .copilot:
            quota = await copilotFetcher.fetchQuota(accountKey: account.accountKey)
        case .claude:
            quota = await claudeCodeFetcher.fetchQuota(accountKey: account.accountKey, forceRefresh: true)
        case .cursor:
            quota = await cursorFetcher.fetchAsProviderQuota()[account.accountKey]
        case .trae:
            quota = await traeFetcher.fetchAsProviderQuota()[account.accountKey]
        case .glm:
            // 一个配置可包含多个独立密钥，不能再按配置名称默认刷新第一个密钥。
            let credentials = CustomProviderService.shared.providers
                .filter { $0.type == .glmCompatibility && $0.isEnabled }
                .flatMap { provider in
                    provider.apiKeys.map { (provider: provider, key: $0) }
                }
            let exactMatch = credentials.first {
                GLMQuotaFetcher.quotaAccountKey(providerID: $0.provider.id, apiKeyID: $0.key.id)
                    == account.accountKey
            }
            // 兼容旧版缓存的名称键，但名称有歧义时拒绝猜测，等待完整刷新生成稳定身份。
            let legacyMatches = credentials.filter { $0.provider.name == account.accountKey }
            guard let match = exactMatch ?? (legacyMatches.count == 1 ? legacyMatches.first : nil) else { return }
            // 先补齐显示信息，再一次性赋给统一刷新结果，保持其他提供商分支的不可变约束。
            var fetchedQuota = try? await glmFetcher.fetchQuota(apiKey: match.key.apiKey, baseURL: match.provider.baseURL)
            fetchedQuota?.accountDisplayName = match.provider.name
            quota = fetchedQuota
        case .deepseek:
            let credentials = CustomProviderService.shared.providers
                .filter { $0.type == .deepseekCompatibility && $0.isEnabled }
                .flatMap { provider in
                    provider.apiKeys.map { (provider: provider, key: $0) }
                }
            let exactMatch = credentials.first {
                DeepSeekQuotaFetcher.quotaAccountKey(providerID: $0.provider.id, apiKeyID: $0.key.id)
                    == account.accountKey
            }
            let legacyMatches = credentials.filter { $0.provider.name == account.accountKey }
            guard let match = exactMatch ?? (legacyMatches.count == 1 ? legacyMatches.first : nil) else { return }
            var fetchedQuota = try? await deepseekFetcher.fetchQuota(apiKey: match.key.apiKey, baseURL: match.provider.baseURL)
            fetchedQuota?.accountDisplayName = match.provider.name
            quota = fetchedQuota
        case .moonshot:
            let credentials = CustomProviderService.shared.providers
                .filter { $0.type == .moonshotCompatibility && $0.isEnabled }
                .flatMap { provider in
                    provider.apiKeys.map { (provider: provider, key: $0) }
                }
            let exactMatch = credentials.first {
                MoonshotQuotaFetcher.quotaAccountKey(providerID: $0.provider.id, apiKeyID: $0.key.id)
                    == account.accountKey
            }
            let legacyMatches = credentials.filter { $0.provider.name == account.accountKey }
            guard let match = exactMatch ?? (legacyMatches.count == 1 ? legacyMatches.first : nil) else { return }
            var fetchedQuota = try? await moonshotFetcher.fetchQuota(apiKey: match.key.apiKey, baseURL: match.provider.baseURL)
            fetchedQuota?.accountDisplayName = match.provider.name
            quota = fetchedQuota
        case .warp:
            guard let entry = WarpService.shared.tokens.first(where: {
                $0.isEnabled && $0.name == account.accountKey
            }) else { return }
            quota = try? await warpFetcher.fetchQuota(apiKey: entry.token)
        case .kiro:
            quota = await kiroFetcher.fetchQuota(accountKey: account.accountKey)
        case .clinePass:
            guard let customProvider = CustomProviderService.shared.providers.first(where: {
                $0.type == .clinePass && $0.isEnabled && $0.name == account.accountKey
            }), let apiKey = customProvider.apiKeys.first?.apiKey else { return }
            quota = try? await clinePassFetcher.fetchQuota(apiKey: apiKey)
        case .factoryDroid:
            quota = await factoryDroidFetcher.fetchQuota(accountKey: account.accountKey)
        case .devin:
            quota = await devinFetcher.fetchAsProviderQuota()[account.accountKey]
        case .grok:
            quota = await grokFetcher.fetchQuota(accountKey: account.accountKey)
        case .openRouter:
            quota = await openRouterFetcher.fetchQuota(accountKey: account.accountKey)
        case .amp:
            quota = await ampFetcher.fetchQuota(accountKey: account.accountKey)
        case .qwen, .iflow, .vertex, .minimax:
            return
        }

        guard canCommit(context) else { return }
        guard let quota else {
            if modeManager.isMonitorMode {
                monitorAccountIssues[account] = MonitorRefreshIssue(
                    message: "monitor.refresh.failed".localized(),
                    occurredAt: Date()
                )
                // 单账号失败不更新额度时间，但必须把失败与旧额度一起落盘供重启后恢复。
                await persistMonitorAccountIssues(context: context)
            }
            return
        }
        if account.provider == .codex {
            let fresh = await codexCLIFetcher.promoteFreshLegacyAliases(in: [account.accountKey: quota])
            var quotas = providerQuotas[.codex, default: [:]]
            quotas.removeValue(forKey: account.accountKey)
            quotas.merge(fresh) { _, fresh in fresh }
            let reconciled = modeManager.isMonitorMode
                ? CodexMonitorGroup.reconcile(quotas, groups: await codexCLIFetcher.monitorCredentialGroups())
                : await codexCLIFetcher.reconcileLegacyAliases(in: quotas)
            guard canCommit(context) else { return }
            providerQuotas[.codex] = reconciled
        } else {
            providerQuotas[account.provider, default: [:]][account.accountKey] = quota
        }
        if let subscription {
            subscriptionInfos[account.provider, default: [:]][account.accountKey] = subscription
        }
        monitorAccountIssues.removeValue(forKey: account)
        await finishScopedRefresh(provider: account.provider, context: context)
    }

    /// 保留既有调用入口和类型名称，仍直接转到同一实例的单提供商刷新。
    func refreshQuotaForProvider(_ provider: AIProvider) async {
        await refreshQuota(for: provider)
    }

    /// 账号发现仍读取主类原 Debug 钩子或同一协调器；发现结果由原调用者的上下文保护。
    /// 发现结果也受调用者的刷新世代保护；测试可在发现挂起时执行删除，验证列表不会回填。
    /// IDE 扫描与账号保存调用原发现入口，继续复用同一协调器和主类中的 Debug 挂起钩子。
    func discoverMonitorAccounts(merging quotas: [AIProvider: [String: ProviderQuotaData]]) async -> [MonitorAccount] {
        #if DEBUG
        if let hook = monitorDiscoveryHookForTesting { return await hook(quotas) }
        #endif
        return await monitorCoordinator.discoverAccounts(merging: quotas)
    }

    /// 完整保留身份归一、监控发现与校验、同步发布、持久化、时间更新、通知和菜单同步的收尾顺序。
    /// 账号变更扩展回到原统一收尾入口，保持身份归一、世代复核、持久化、通知与菜单同步的既有顺序。
    func finishScopedRefresh(provider: AIProvider, context: RefreshContext? = nil) async {
        let context = context ?? refreshContext()
        guard canCommit(context) else { return }
        reconcileAccountQuotaIdentities()
        if modeManager.isMonitorMode {
            let accounts = await discoverMonitorAccounts(merging: providerQuotas)
            let issues = await monitorCoordinator.currentIssues()
            guard canCommit(context) else { return }
            monitorAccounts = accounts
            monitorIssues = issues
            // 单服务商刷新与全量刷新使用同一恢复判定；旧额度本身不能消除新失败。
            clearRecoveredMonitorAccountIssues()
            removeDisabledMonitorQuotas()
            await monitorCoordinator.finish(quotas: providerQuotas, accountIssues: monitorAccountIssues, revision: context.revision)
            guard canCommit(context) else { return }
        }
        lastQuotaRefreshTime = Date()
        if provider.isImportedFromLocalIDE { savePersistedIDEQuotas() }
        checkQuotaNotifications()
        pruneMenuBarItems()
        autoSelectMenuBarItems()
        notifyQuotaDataChanged()
    }

    /// 单账号失败只持久化原失败与旧额度，不推进成功时间；辅助仍为 private，不复制状态。
    /// 单账号失败只持久化状态，不把失败当作一次成功刷新去推进页面更新时间或通知。
    private func persistMonitorAccountIssues(context: RefreshContext) async {
        guard modeManager.isMonitorMode, canCommit(context) else { return }
        await monitorCoordinator.finish(
            quotas: providerQuotas, accountIssues: monitorAccountIssues, revision: context.revision
        )
    }

    /// 自动发现刷新仍排除需显式扫描的 IDE 提供商，按原顺序复用单提供商入口，避免删除后自动重新导入。
    /// Refresh all auto-detected providers (those that don't support manual auth)
    /// Cursor and Trae are excluded: they are imported only via explicit "Scan for IDEs"
    /// (issue #29) and re-importing here would resurrect deleted accounts (issue #213).
    /// They can still be refreshed via their scoped refresh actions while imported.
    func refreshAutoDetectedProviders() async {
        let autoDetectedProviders = AIProvider.allCases.filter { !$0.supportsManualAuth && !$0.isImportedFromLocalIDE }

        for provider in autoDetectedProviders {
            await refreshQuotaForProvider(provider)
        }
    }
}
