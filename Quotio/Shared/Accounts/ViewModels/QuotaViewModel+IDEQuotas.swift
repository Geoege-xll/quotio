//
//  QuotaViewModel+IDEQuotas.swift
//  Quotio
//

import Foundation

/// IDE 额度读取、显式扫描、已有账号刷新与持久化的原有方法组。
/// 扩展仍操作同一个 QuotaViewModel 的额度快照，不存储新的账号列表、任务或刷新集合。
/// Cursor／Trae 的获取器及扫描设置继续由主类创建；存储键、编码结构和用户扫描同意规则不变。
/// 已有账号刷新仍通过主类的原同步入口占用刷新槽位，在 await 后重新核对世代及现存账号。
/// 保留取消、删除后不复活、未扫描不自动导入，以及同步发布与落盘之间不增加挂起点的边界。
/// 测试读取钩子继续存储在主类；只开放主类或账号变更扩展实际需要调用的入口，局部辅助仍私有。
extension QuotaViewModel {
    /// Merge freshly read IDE quota data into the accounts that are already imported.
    ///
    /// Cursor and Trae accounts only exist once the user has explicitly run
    /// "Scan for IDEs" (issue #29), and they can be deleted (issue #213). A global
    /// refresh must therefore update the quota of the accounts that are currently
    /// imported without importing any account key that is not already present —
    /// otherwise a deleted account would resurrect on the next refresh.
    ///
    /// - Parameters:
    ///   - fetched: everything the IDE fetcher could read from the local database.
    ///   - existing: the account keys currently imported into `providerQuotas`.
    /// - Returns: `existing`, with fresh data applied to the keys it already holds.
    ///   Keys present only in `fetched` are dropped; keys the fetcher could not read
    ///   this time keep their previous value instead of disappearing from the UI.
    nonisolated static func mergeImportedIDEQuotas(
        fetched: [String: ProviderQuotaData],
        into existing: [String: ProviderQuotaData]
    ) -> [String: ProviderQuotaData] {
        guard !existing.isEmpty else { return existing }

        var merged = existing
        for (accountKey, quota) in fetched where existing[accountKey] != nil {
            merged[accountKey] = quota
        }
        return merged
    }

    #if DEBUG
    /// 原测试入口只在已注入隔离读取时执行。生产入口的运行会话、槽位及目录由统一刷新流程持有。
    func refreshImportedIDEQuotas() async {
        guard ideQuotaFetchHookForTesting != nil else { return }
        let context = refreshContext()
        for provider in Self.ideProvidersToSave.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard canCommit(context), providerQuotas[provider]?.isEmpty == false,
                  beginBatchRefresh(providers: [provider]) else { continue }
            defer { endBatchRefresh(providers: [provider]) }
            await refreshImportedIDEQuotas(provider: provider, accountKey: nil, context: context, client: nil)
        }
    }
    #endif

    /// 只刷新已显式导入的账号键。持有统一的提供商槽位，恢复后重新读取当前字典，
    /// 删除或重新导入可使旧上下文失效，不会用挂起前的旧列表覆盖新账号。
    func refreshImportedIDEQuotas(provider: AIProvider, accountKey: String?, context: RefreshContext,
                                  client: ManagementAPIClient?) async {
        guard canRefreshIDEQuota(context, client: client), let existing = providerQuotas[provider] else { return }
        let requestedKeys = Set(existing.keys.filter { accountKey == nil || $0 == accountKey })
        guard !requestedKeys.isEmpty else { return }
        // 身份和会话同时决定本轮取数许可。取数器从自己的 actor 返回到主类复核后才读本地凭据或出站。
        let fetched = await fetchImportedIDEQuotas(for: provider, matchingAccountKeys: requestedKeys,
            isCurrent: { [self, context, client] in await canRefreshIDEQuota(context, client: client) })
        guard canRefreshIDEQuota(context, client: client),
              let current = providerQuotas[provider], !current.isEmpty else { return }

        var successes: [String: ProviderQuotaData] = [:]
        for key in current.keys where accountKey == nil || accountKey == key {
            let account = QuotaAccountID(provider: provider, accountKey: key)
            guard var quota = fetched[key], !quota.isForbidden else {
                monitorAccountIssues[account] = MonitorRefreshIssue(
                    message: "monitor.refresh.failed".localized(), occurredAt: Date())
                continue
            }
            quota.refreshSource = .explicitConnection
            successes[key] = quota
            monitorAccountIssues.removeValue(forKey: account)
        }
        guard let newest = successes.values.map(\.lastUpdated).max() else { return }
        providerQuotas[provider] = Self.mergeImportedIDEQuotas(fetched: successes, into: current)
        savePersistedIDEQuotas()
        recordAccountQuotaSuccess(at: newest)
    }

    private func canRefreshIDEQuota(_ context: RefreshContext, client: ManagementAPIClient?) -> Bool {
        if let client { return canCommitQuotaRefresh(context, client: client) }
        #if DEBUG
        return ideQuotaFetchHookForTesting != nil && canCommit(context)
        #else
        return false
        #endif
    }

    private func fetchImportedIDEQuotas(for provider: AIProvider, matchingAccountKeys: Set<String>,
                                        isCurrent: @Sendable () async -> Bool) async -> [String: ProviderQuotaData] {
        #if DEBUG
        if let hook = ideQuotaFetchHookForTesting {
            return await hook(provider)
        }
        #endif
        switch provider {
        case .cursor:
            return await cursorFetcher.fetchAsProviderQuota(matchingAccountKeys: matchingAccountKeys, isCurrent: isCurrent)
        case .trae:
            return await traeFetcher.fetchAsProviderQuota(matchingAccountKeys: matchingAccountKeys, isCurrent: isCurrent)
        default:
            return [:]
        }
    }

    /// Scan IDEs with explicit user consent - addresses issue #29
    /// Only scans what the user has opted into
    func scanIDEsWithConsent(options: IDEScanOptions) async {
        // 显式同意允许首次导入具体身份；停机时连已导入 IDE 的取数入口也不执行。
        guard canRefreshAccountQuotas, let client = apiClient else { return }
        var context = beginAccountMutation()
        func canCommitScan() -> Bool { canCommitIDEScan(context, client: client) }
        ideScanSettings.setScanningState(true)
        defer { ideScanSettings.setScanningState(false) }
        
        var cursorFound = false
        var cursorEmail: String?
        var traeFound = false
        var traeEmail: String?
        var cliToolsFound: [String] = []
        
        // Scan Cursor if opted in
        if options.scanCursor {
            let quotas = await cursorFetcher.fetchAsProviderQuota(isCurrent: { [self, context, client] in
                await canCommitIDEScan(context, client: client)
            }).filter { !$0.value.isForbidden }
            guard canCommitScan() else { return }
            if !quotas.isEmpty {
                cursorFound = true
                cursorEmail = quotas.keys.first
                for key in quotas.keys {
                    let id = MonitorAccount.make(provider: .cursor, accountKey: key, source: .localIDE).id
                    context = beginAccountMutation(accountID: id)
                }
                commitIDEImport(quotas, provider: .cursor)
            }
        }
        
        // Scan Trae if opted in
        if options.scanTrae {
            // Cursor 的导入可能推进账号世代；Trae 使用当前已生效的值，且在挂起后仍须服从同一会话。
            let quotas = await traeFetcher.fetchAsProviderQuota(isCurrent: { [self, context, client] in
                await canCommitIDEScan(context, client: client)
            }).filter { !$0.value.isForbidden }
            guard canCommitScan() else { return }
            if !quotas.isEmpty {
                traeFound = true
                traeEmail = quotas.keys.first
                for key in quotas.keys {
                    let id = MonitorAccount.make(provider: .trae, accountKey: key, source: .localIDE).id
                    context = beginAccountMutation(accountID: id)
                }
                commitIDEImport(quotas, provider: .trae)
            }
        }
        
        // Scan CLI tools if opted in
        if options.scanCLITools {
            let cliNames = ["claude", "codex", "gh"]
            for name in cliNames {
                guard canCommitScan() else { return }
                if await CLIExecutor.shared.isCLIInstalled(name: name) {
                    cliToolsFound.append(name)
                }
            }
        }
        
        guard canCommitScan() else { return }
        let result = IDEScanResult(
            cursorFound: cursorFound,
            cursorEmail: cursorEmail,
            traeFound: traeFound,
            traeEmail: traeEmail,
            cliToolsFound: cliToolsFound,
            timestamp: Date()
        )
        
        ideScanSettings.updateScanResult(result)
        ideScanSettings.setScanningState(false)
        
        // Persist IDE quota data for Cursor and Trae
        savePersistedIDEQuotas()

        // Update menu bar items
        pruneMenuBarItems()
        autoSelectMenuBarItems()

        notifyQuotaDataChanged()
    }

    private func canCommitIDEScan(_ context: RefreshContext, client: ManagementAPIClient) -> Bool {
        canCommit(context) && canRefreshAccountQuotas && apiClient === client
    }

    /// 显式扫描可增加身份；一次无结果应保留以前已确认的账号和原成功时间。
    private func commitIDEImport(_ results: [String: ProviderQuotaData], provider: AIProvider) {
        let quotas = results.mapValues { result in
            var quota = result
            quota.refreshSource = .explicitConnection
            return quota
        }
        providerQuotas[provider, default: [:]].merge(quotas) { _, new in new }
        if let newest = quotas.values.map(\.lastUpdated).max() { recordAccountQuotaSuccess(at: newest) }
    }

    /// Save Cursor and Trae quota data to UserDefaults for persistence across app restarts
    func savePersistedIDEQuotas() {
        var dataToSave: [String: [String: ProviderQuotaData]] = [:]
        
        for provider in Self.ideProvidersToSave {
            if let quotas = providerQuotas[provider], !quotas.isEmpty {
                dataToSave[provider.rawValue] = quotas
            }
        }
        
        if dataToSave.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.ideQuotasKey)
            return
        }
        
        do {
            let encoded = try JSONEncoder().encode(dataToSave)
            UserDefaults.standard.set(encoded, forKey: Self.ideQuotasKey)
        } catch {
            Log.error("Failed to save IDE quotas: \(error)")
        }
    }

    /// Load persisted Cursor and Trae quota data from UserDefaults
    func loadPersistedIDEQuotas() {
        guard let data = UserDefaults.standard.data(forKey: Self.ideQuotasKey) else { return }
        
        do {
            let decoded = try JSONDecoder().decode([String: [String: ProviderQuotaData]].self, from: data)
            
            for (providerRaw, quotas) in decoded {
                if let provider = AIProvider(rawValue: providerRaw),
                   Self.ideProvidersToSave.contains(provider) {
                    providerQuotas[provider] = quotas
                }
            }
        } catch {
            Log.error("Failed to load IDE quotas: \(error)")
            // Clear corrupted data
            UserDefaults.standard.removeObject(forKey: Self.ideQuotasKey)
        }
    }
}
