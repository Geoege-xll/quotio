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
    /// Refresh Cursor quota using browser cookies
    func refreshCursorQuotasInternal() async {
        let context = refreshContext()
        let quotas = await cursorFetcher.fetchAsProviderQuota()
        guard canCommit(context) else { return }
        if quotas.isEmpty {
            // No Cursor auth found - remove from providerQuotas
            providerQuotas.removeValue(forKey: .cursor)
        } else {
            providerQuotas[.cursor] = quotas
        }
    }

    /// Refresh Trae quota using SQLite database
    func refreshTraeQuotasInternal() async {
        let context = refreshContext()
        let quotas = await traeFetcher.fetchAsProviderQuota()
        guard canCommit(context) else { return }
        if quotas.isEmpty {
            providerQuotas.removeValue(forKey: .trae)
        } else {
            providerQuotas[.trae] = quotas
        }
    }

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

    /// Refresh the quota of already-imported IDE-derived accounts (Cursor, Trae).
    ///
    /// This is the piece the global refresh actions were missing: `refreshAllQuotas`,
    /// `refreshQuotasUnified` and `refreshQuotasDirectly` all skip Cursor/Trae, so the
    /// menu bar refresh never updated them (issues #163, #257). Unlike the per-provider
    /// re-import in `refreshQuota(for:)`, this only touches account keys that are
    /// already imported, so it never re-imports from the IDE databases.
    ///
    /// Internal rather than private so the reentrancy regression tests can drive this
    /// path directly instead of going through a global refresh that hits the network.
    func refreshImportedIDEQuotas() async {
        // `Set` iteration order is unspecified; sort so the sequence of suspension
        // points is deterministic (and therefore testable).
        for provider in Self.ideProvidersToSave.sorted(by: { $0.rawValue < $1.rawValue }) {
            await refreshImportedIDEQuotas(for: provider)
        }
    }

    /// Refresh a single IDE-derived provider while holding its refresh-coordination slot.
    ///
    /// `QuotaViewModel` is `@MainActor`, but a main actor is *reentrant*: the `await` on
    /// the IDE fetcher below is a suspension point at which any other main-actor work can
    /// run — a scoped refresh, an account deletion (issue #213), a re-scan. The previous
    /// version of this method sampled `providerQuotas` and `activeRefreshProviders`
    /// before that await and then wrote the resulting merge unconditionally, so anything
    /// that changed while the fetch was suspended got clobbered by the stale snapshot.
    ///
    /// Two things close that window:
    /// 1. The provider's slot in `activeRefreshProviders` is held for the *whole*
    ///    fetch/write, so a scoped refresh cannot start midway through it (and if one is
    ///    already running, this refresh yields to it instead of racing).
    /// 2. `providerQuotas` is re-read *after* the await and the merge is applied to the
    ///    keys that still exist at write time, so an account removed during the fetch
    ///    stays removed instead of being resurrected from the pre-await snapshot.
    private func refreshImportedIDEQuotas(for provider: AIProvider) async {
        let context = refreshContext()
        // Nothing imported for this provider: respect the explicit-scan consent model
        // (issue #29) and do not pull anything in. No await between this read and the
        // slot acquisition below, so the check cannot go stale.
        guard providerQuotas[provider]?.isEmpty == false else { return }
        // Claims the same slot `refreshQuota(for:)` uses, for the full fetch/write.
        // Fails if a scoped refresh for this provider is already in flight — that one wins.
        guard beginBatchRefresh(providers: [provider]) else { return }
        defer { endBatchRefresh(providers: [provider]) }

        let fetched = await fetchImportedIDEQuotas(for: provider)
        // 上游 9954e49：取消可能发生在数据库读取挂起期间；恢复后不能发布或落盘旧任务结果。
        guard canCommit(context) else { return }

        // Re-read after the suspension point: the account may have been deleted, or the
        // whole provider removed, while the fetch was in flight.
        guard let current = providerQuotas[provider], !current.isEmpty else { return }
        providerQuotas[provider] = Self.mergeImportedIDEQuotas(fetched: fetched, into: current)
        // Persisted synchronously with the write so the saved snapshot cannot capture a
        // half-applied state from a concurrent mutation.
        savePersistedIDEQuotas()
    }

    private func fetchImportedIDEQuotas(for provider: AIProvider) async -> [String: ProviderQuotaData] {
        #if DEBUG
        if let hook = ideQuotaFetchHookForTesting {
            return await hook(provider)
        }
        #endif
        switch provider {
        case .cursor:
            return await cursorFetcher.fetchAsProviderQuota()
        case .trae:
            return await traeFetcher.fetchAsProviderQuota()
        default:
            return [:]
        }
    }

    /// Scan IDEs with explicit user consent - addresses issue #29
    /// Only scans what the user has opted into
    func scanIDEsWithConsent(options: IDEScanOptions) async {
        var context = beginAccountMutation()
        ideScanSettings.setScanningState(true)
        defer { ideScanSettings.setScanningState(false) }
        
        var cursorFound = false
        var cursorEmail: String?
        var traeFound = false
        var traeEmail: String?
        var cliToolsFound: [String] = []
        
        // Scan Cursor if opted in
        if options.scanCursor {
            let quotas = await cursorFetcher.fetchAsProviderQuota()
            guard canCommit(context) else { return }
            if !quotas.isEmpty {
                cursorFound = true
                cursorEmail = quotas.keys.first
                for key in quotas.keys {
                    let id = MonitorAccount.make(provider: .cursor, accountKey: key, source: .localIDE).id
                    context = beginAccountMutation(accountID: id)
                }
                providerQuotas[.cursor] = quotas
            } else {
                // Clear stale data when not found (consistent with refreshCursorQuotasInternal)
                providerQuotas.removeValue(forKey: .cursor)
            }
        }
        
        // Scan Trae if opted in
        if options.scanTrae {
            let quotas = await traeFetcher.fetchAsProviderQuota()
            guard canCommit(context) else { return }
            if !quotas.isEmpty {
                traeFound = true
                traeEmail = quotas.keys.first
                for key in quotas.keys {
                    let id = MonitorAccount.make(provider: .trae, accountKey: key, source: .localIDE).id
                    context = beginAccountMutation(accountID: id)
                }
                providerQuotas[.trae] = quotas
            } else {
                // Clear stale data when not found (consistent with refreshTraeQuotasInternal)
                providerQuotas.removeValue(forKey: .trae)
            }
        }
        
        // Scan CLI tools if opted in
        if options.scanCLITools {
            let cliNames = ["claude", "codex", "gh"]
            for name in cliNames {
                if await CLIExecutor.shared.isCLIInstalled(name: name) {
                    cliToolsFound.append(name)
                }
            }
        }
        
        guard canCommit(context) else { return }
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

        if modeManager.isMonitorMode {
            let accounts = await discoverMonitorAccounts(merging: providerQuotas)
            guard canCommit(context) else { return }
            monitorAccounts = accounts
            removeDisabledMonitorQuotas()
        }

        // Update menu bar items
        pruneMenuBarItems()
        autoSelectMenuBarItems()

        notifyQuotaDataChanged()
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
