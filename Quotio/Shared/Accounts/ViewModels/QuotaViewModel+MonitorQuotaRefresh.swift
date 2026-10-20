//
//  QuotaViewModel+MonitorQuotaRefresh.swift
//  Quotio
//

import Foundation

/// 监控模式的批量及单提供商取数流程，仍操作应用持有的同一个 QuotaViewModel。
/// 原 MonitorRefreshCoordinator、提供商获取器、Debug 钩子及所有状态继续由主类持有。
/// 批量流程保留原 async let 并发及等待顺序；发现账号、旧值合并、身份归一和提交检查不重新组织。
/// 提交前最后一次上下文校验之后，原连续内存发布段不增加 await，避免删除插入半批结果之间。
/// 刷新槽位、世代校验、错误恢复判定及统一收尾继续调用主类原入口，不建立另一套刷新策略。
extension QuotaViewModel {
    /// 整批取数连同原槽位申请／defer 释放完整迁移；保留凭据存在性、有效账号键和失败旧值筛选。
    /// Refresh quotas directly without proxy (for Quota-Only Mode)
    /// Note: Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)
    func refreshQuotasDirectly(force: Bool = false) async {
        let context = refreshContext()
        let providers: Set<AIProvider> = [
            .codex, .claude, .copilot, .kiro, .glm, .deepseek, .moonshot, .clinePass, .warp,
            .antigravity, .factoryDroid, .devin, .grok, .openRouter, .amp,
        ]
        guard await QuotaRefreshAvailability.acquire(wait: force, claim: {
            beginBatchRefresh(providers: providers)
        }) else { return }
        defer { endBatchRefresh(providers: providers) }
        guard canCommit(context) else { return }

        lastQuotaRefreshTime = Date()
        
        let previous = providerQuotas
        let coordinator = monitorCoordinator
        let discoveredAccounts = await coordinator.discoverAccounts()
        let discoveredProviders = Set(discoveredAccounts.map(\.provider))
        let discoveredAccountKeys = Dictionary(grouping: discoveredAccounts, by: \.provider)
            .mapValues { Set($0.map(\.accountKey)) }
        let credentialProviders: Set<AIProvider> = [
            .codex, .claude, .copilot, .kiro, .antigravity, .factoryDroid, .devin, .grok, .openRouter, .amp,
        ]
        let credentialAvailability = Dictionary(uniqueKeysWithValues: credentialProviders.map {
            ($0, discoveredProviders.contains($0) ? MonitorCredentialAvailability.present : .missing)
        })
        let codexFetcher = codexCLIFetcher
        let claudeFetcher = claudeCodeFetcher
        let copilotQuotaFetcher = copilotFetcher
        let kiroQuotaFetcher = kiroFetcher
        let glmQuotaFetcher = glmFetcher
        let deepseekQuotaFetcher = deepseekFetcher
        let moonshotQuotaFetcher = moonshotFetcher
        let clineQuotaFetcher = clinePassFetcher
        let warpQuotaFetcher = warpFetcher
        let antigravityQuotaFetcher = antigravityFetcher
        let factoryDroidQuotaFetcher = factoryDroidFetcher
        let devinQuotaFetcher = devinFetcher
        let grokQuotaFetcher = grokFetcher
        let openRouterQuotaFetcher = openRouterFetcher
        let ampQuotaFetcher = ampFetcher
        let warpTokens = WarpService.shared.tokens.filter { $0.isEnabled }
        let factoryDroidPrevious = previous[.factoryDroid]?.filter {
            discoveredAccountKeys[.factoryDroid]?.contains($0.key) == true
        } ?? [:]
        let devinPrevious = previous[.devin]?.filter {
            discoveredAccountKeys[.devin]?.contains($0.key) == true
        } ?? [:]
        let grokPrevious = previous[.grok]?.filter {
            discoveredAccountKeys[.grok]?.contains($0.key) == true
        } ?? [:]
        let openRouterPrevious = previous[.openRouter]?.filter {
            discoveredAccountKeys[.openRouter]?.contains($0.key) == true
        } ?? [:]
        let ampPrevious = previous[.amp]?.filter {
            discoveredAccountKeys[.amp]?.contains($0.key) == true
        } ?? [:]

        let codexGroups = await codexFetcher.monitorCredentialGroups()
        let codexPrevious = CodexMonitorGroup.reconcile(previous[.codex] ?? [:], groups: codexGroups)
        let codexKeys = codexGroups.contains { $0.sources.contains { !$0.isReadable } }
            ? nil : Set(codexGroups.filter { !$0.account.isDisabled }.map { $0.account.accountKey })
        guard canCommit(context) else { return }
        async let codex = coordinator.refresh(
            provider: .codex,
            force: force,
            previous: codexPrevious,
            credentialAvailability: credentialAvailability[.codex] ?? .unknown,
            credentialAccountKeys: codexKeys
        ) {
            await codexFetcher.fetchMonitorQuotas()
        }
        async let claude = coordinator.refresh(
            provider: .claude,
            force: force,
            previous: previous[.claude] ?? [:],
            credentialAvailability: credentialAvailability[.claude] ?? .unknown
        ) {
            await claudeFetcher.fetchAsProviderQuota(forceRefresh: force, includeMonitorCredentials: true)
        }
        async let copilot = coordinator.refresh(
            provider: .copilot,
            force: force,
            previous: previous[.copilot] ?? [:],
            credentialAvailability: credentialAvailability[.copilot] ?? .unknown
        ) {
            await copilotQuotaFetcher.fetchAllCopilotQuotas(includeMonitorCredentials: true)
        }
        async let kiro = coordinator.refresh(
            provider: .kiro,
            force: force,
            previous: previous[.kiro] ?? [:],
            credentialAvailability: credentialAvailability[.kiro] ?? .unknown
        ) {
            await kiroQuotaFetcher.fetchAllQuotas(includeMonitorCredentials: true)
        }
        async let glm = coordinator.refresh(provider: .glm, force: force, previous: previous[.glm] ?? [:]) {
            await glmQuotaFetcher.fetchAllQuotas()
        }
        async let deepseek = coordinator.refresh(provider: .deepseek, force: force, previous: previous[.deepseek] ?? [:]) {
            await deepseekQuotaFetcher.fetchAllQuotas()
        }
        async let moonshot = coordinator.refresh(provider: .moonshot, force: force, previous: previous[.moonshot] ?? [:]) {
            await moonshotQuotaFetcher.fetchAllQuotas()
        }
        async let clinePass = coordinator.refresh(provider: .clinePass, force: force, previous: previous[.clinePass] ?? [:]) {
            await clineQuotaFetcher.fetchAllQuotas()
        }
        async let warp = coordinator.refresh(provider: .warp, force: force, previous: previous[.warp] ?? [:]) {
            var quotas: [String: ProviderQuotaData] = [:]
            for entry in warpTokens {
                if let quota = try? await warpQuotaFetcher.fetchQuota(apiKey: entry.token) {
                    quotas[entry.name] = quota
                }
            }
            return quotas
        }
        async let antigravityData = antigravityQuotaFetcher.fetchAllAntigravityData(
            includeMonitorCredentials: true
        )
        async let factoryDroid = coordinator.refresh(
            provider: .factoryDroid,
            force: force,
            previous: factoryDroidPrevious,
            credentialAvailability: credentialAvailability[.factoryDroid] ?? .unknown,
            credentialAccountKeys: discoveredAccountKeys[.factoryDroid] ?? []
        ) {
            await factoryDroidQuotaFetcher.fetchAllQuotas()
        }
        async let devin = coordinator.refresh(
            provider: .devin,
            force: force,
            previous: devinPrevious,
            credentialAvailability: credentialAvailability[.devin] ?? .unknown,
            credentialAccountKeys: discoveredAccountKeys[.devin] ?? []
        ) {
            await devinQuotaFetcher.fetchAsProviderQuota()
        }
        async let grok = coordinator.refresh(
            provider: .grok,
            force: force,
            previous: grokPrevious,
            credentialAvailability: credentialAvailability[.grok] ?? .unknown,
            credentialAccountKeys: discoveredAccountKeys[.grok] ?? []
        ) {
            await grokQuotaFetcher.fetchAllQuotas()
        }
        async let openRouter = coordinator.refresh(
            provider: .openRouter,
            force: force,
            previous: openRouterPrevious,
            credentialAvailability: credentialAvailability[.openRouter] ?? .unknown,
            credentialAccountKeys: discoveredAccountKeys[.openRouter] ?? []
        ) {
            await openRouterQuotaFetcher.fetchAllQuotas()
        }
        async let amp = coordinator.refresh(
            provider: .amp,
            force: force,
            previous: ampPrevious,
            credentialAvailability: credentialAvailability[.amp] ?? .unknown,
            credentialAccountKeys: discoveredAccountKeys[.amp] ?? []
        ) {
            await ampQuotaFetcher.fetchAllQuotas()
        }

        let fetchedAntigravityData = await antigravityData
        let antigravity = await coordinator.refresh(
            provider: .antigravity,
            force: force,
            previous: previous[.antigravity] ?? [:],
            credentialAvailability: credentialAvailability[.antigravity] ?? .unknown
        ) {
            fetchedAntigravityData.quotas
        }

        var refreshed = previous
        refreshed[.codex] = CodexMonitorGroup.reconcile(await codex, groups: await codexFetcher.monitorCredentialGroups())
        refreshed[.claude] = await claude
        refreshed[.copilot] = await copilotQuotaFetcher.reconcileLegacyAliases(in: await copilot)
        refreshed[.kiro] = await kiro
        refreshed[.glm] = await glm
        refreshed[.deepseek] = await deepseek
        refreshed[.moonshot] = await moonshot
        refreshed[.clinePass] = await clinePass
        refreshed[.warp] = await warp
        refreshed[.antigravity] = antigravity
        refreshed[.factoryDroid] = await factoryDroid
        refreshed[.devin] = await devin
        refreshed[.grok] = await grok
        refreshed[.openRouter] = await openRouter
        refreshed[.amp] = await amp
        let accounts = await discoverMonitorAccounts(merging: refreshed)
        let issues = await coordinator.currentIssues()
        guard canCommit(context) else { return }
        // 从这里到全部内存状态发布不再挂起，删除不可能插入半批结果之间。
        providerQuotas = refreshed.filter { !$0.value.isEmpty }
        subscriptionInfos[.antigravity, default: [:]].merge(fetchedAntigravityData.subscriptions) { _, fresh in fresh }
        subscriptionInfos[.antigravity] = subscriptionInfos[.antigravity]?.filter { antigravity[$0.key] != nil }
        monitorAccounts = accounts
        monitorIssues = issues
        clearRecoveredMonitorAccountIssues()
        removeDisabledMonitorQuotas()
        await refreshImportedIDEQuotas()
        guard canCommit(context) else { return }
        await coordinator.finish(quotas: providerQuotas, accountIssues: monitorAccountIssues, revision: context.revision)
        guard canCommit(context) else { return }

        checkQuotaNotifications()
        pruneMenuBarItems()
        autoSelectMenuBarItems()

        notifyQuotaDataChanged()
    }

    /// 保留 nonisolated static 与原 Sendable 闭包，先由协调器合并旧值，再归一 Copilot 别名。
    /// Runs a provider-scoped Copilot refresh and reconciles the result.
    ///
    /// `MonitorRefreshCoordinator.refresh` merges `previous` into the fetcher
    /// output, so reconciling only the fetcher output is not enough: a Copilot-only
    /// refresh would re-store the stale filename key that the merge carried over.
    /// The reconciliation therefore runs on the *merged* dictionary, matching what
    /// `refreshQuotasDirectly` does for the full refresh (#404).
    nonisolated static func refreshCopilotThroughCoordinator(
        coordinator: MonitorRefreshCoordinator,
        fetcher: CopilotQuotaFetcher,
        previous: [String: ProviderQuotaData],
        credentialAvailability: MonitorCredentialAvailability,
        authDir: String = "~/.cli-proxy-api",
        operation: @escaping @Sendable () async -> [String: ProviderQuotaData]
    ) async -> [String: ProviderQuotaData] {
        let merged = await coordinator.refresh(
            provider: .copilot,
            force: true,
            previous: previous,
            credentialAvailability: credentialAvailability,
            operation: operation
        )
        return await fetcher.reconcileLegacyAliases(in: merged, authDir: authDir)
    }

    /// 单提供商读取保留原协调器强制刷新、Codex 凭据分组及 Antigravity 套餐合并规则。
    func refreshMonitorProvider(_ provider: AIProvider) async {
        let context = refreshContext()
        let coordinator = monitorCoordinator
        var previous = providerQuotas[provider] ?? [:]
        var credentialKeys: Set<String>?
        if provider == .codex {
            let groups = await codexCLIFetcher.monitorCredentialGroups()
            previous = CodexMonitorGroup.reconcile(previous, groups: groups)
            if !groups.contains(where: { $0.sources.contains { !$0.isReadable } }) {
                credentialKeys = Set(groups.filter { !$0.account.isDisabled }.map { $0.account.accountKey })
            }
        }
        let credentialProviders: Set<AIProvider> = [
            .codex, .claude, .copilot, .kiro, .antigravity,
            .factoryDroid, .devin, .grok, .openRouter, .amp,
        ]
        let discoveredProviders = Set(await coordinator.discoverAccounts().map(\.provider))
        guard canCommit(context) else { return }
        let credentialAvailability: MonitorCredentialAvailability = credentialProviders.contains(provider)
            ? (discoveredProviders.contains(provider) ? .present : .missing)
            : .unknown
        let fresh: [String: ProviderQuotaData]
        var freshSubscriptions: [String: SubscriptionInfo] = [:]

        func coordinatedRefresh(
            _ operation: @escaping @Sendable () async -> [String: ProviderQuotaData]
        ) async -> [String: ProviderQuotaData] {
            await coordinator.refresh(
                provider: provider,
                force: true,
                previous: previous,
                credentialAvailability: credentialAvailability,
                credentialAccountKeys: credentialKeys,
                operation: operation
            )
        }

        switch provider {
        case .codex:
            let fetcher = codexCLIFetcher
            let refreshed = await coordinatedRefresh {
                await fetcher.fetchMonitorQuotas()
            }
            fresh = CodexMonitorGroup.reconcile(refreshed, groups: await fetcher.monitorCredentialGroups())
        case .claude:
            let fetcher = claudeCodeFetcher
            fresh = await coordinatedRefresh {
                await fetcher.fetchAsProviderQuota(forceRefresh: true, includeMonitorCredentials: true)
            }
        case .copilot:
            let fetcher = copilotFetcher
            fresh = await Self.refreshCopilotThroughCoordinator(
                coordinator: coordinator,
                fetcher: fetcher,
                previous: previous,
                credentialAvailability: credentialAvailability
            ) {
                await fetcher.fetchAllCopilotQuotas(includeMonitorCredentials: true)
            }
        case .kiro:
            let fetcher = kiroFetcher
            fresh = await coordinatedRefresh {
                await fetcher.fetchAllQuotas(includeMonitorCredentials: true)
            }
        case .glm:
            let fetcher = glmFetcher
            fresh = await coordinatedRefresh {
                await fetcher.fetchAllQuotas()
            }
        case .deepseek:
            let fetcher = deepseekFetcher
            fresh = await coordinatedRefresh {
                await fetcher.fetchAllQuotas()
            }
        case .moonshot:
            let fetcher = moonshotFetcher
            fresh = await coordinatedRefresh {
                await fetcher.fetchAllQuotas()
            }
        case .clinePass:
            let fetcher = clinePassFetcher
            fresh = await coordinatedRefresh {
                await fetcher.fetchAllQuotas()
            }
        case .warp:
            let fetcher = warpFetcher
            let tokens = WarpService.shared.tokens.filter(\.isEnabled)
            fresh = await coordinatedRefresh {
                var results: [String: ProviderQuotaData] = [:]
                for entry in tokens {
                    if let quota = try? await fetcher.fetchQuota(apiKey: entry.token) {
                        results[entry.name] = quota
                    }
                }
                return results
            }
        case .antigravity:
            let fetcher = antigravityFetcher
            let fetched = await fetcher.fetchAllAntigravityData(includeMonitorCredentials: true)
            freshSubscriptions = fetched.subscriptions
            fresh = await coordinatedRefresh {
                fetched.quotas
            }
        case .factoryDroid:
            let fetcher = factoryDroidFetcher
            fresh = await coordinatedRefresh {
                await fetcher.fetchAllQuotas()
            }
        case .devin:
            let fetcher = devinFetcher
            fresh = await coordinatedRefresh {
                await fetcher.fetchAsProviderQuota()
            }
        case .grok:
            let fetcher = grokFetcher
            fresh = await coordinatedRefresh {
                await fetcher.fetchAllQuotas()
            }
        case .openRouter:
            let fetcher = openRouterFetcher
            fresh = await coordinatedRefresh {
                await fetcher.fetchAllQuotas()
            }
        case .amp:
            let fetcher = ampFetcher
            fresh = await coordinatedRefresh {
                await fetcher.fetchAllQuotas()
            }
        case .cursor:
            let fetcher = cursorFetcher
            fresh = await coordinatedRefresh {
                await fetcher.fetchAsProviderQuota()
            }
        case .trae:
            let fetcher = traeFetcher
            fresh = await coordinatedRefresh {
                await fetcher.fetchAsProviderQuota()
            }
        case .qwen, .iflow, .vertex, .minimax:
            return
        }

        guard canCommit(context) else { return }
        if fresh.isEmpty {
            providerQuotas.removeValue(forKey: provider)
        } else {
            providerQuotas[provider] = fresh
        }
        if provider == .antigravity {
            subscriptionInfos[provider, default: [:]].merge(freshSubscriptions) { _, fresh in fresh }
            subscriptionInfos[provider] = subscriptionInfos[provider]?.filter { fresh[$0.key] != nil }
        }
    }
}
