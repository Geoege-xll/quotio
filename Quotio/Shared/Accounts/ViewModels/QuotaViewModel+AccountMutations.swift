//
//  QuotaViewModel+AccountMutations.swift
//  Quotio
//

import Foundation

/// 账号禁用、删除、监控密钥账号保存、自定义连接变更及 Antigravity IDE 切换的原有入口。
/// 全部方法仍作用于同一个 QuotaViewModel；监控账号复用原协调器，IDE 切换复用主类原切换器。
/// 凭据与连接变更仍在原时点推进世代；IDE 切换不新增世代，每次挂起后的原校验和账号范围不变。
/// 删除继续同步清理同一身份对应的目录、额度、套餐、错误、固定项及需要持久化的 IDE 镜像。
/// 同名不同凭据、不同认证目录、独立账号并行操作与用户保留的固定项继续沿用既有保护。
/// 刷新收尾及禁用偏好读写仍调用主类原入口；不增加任务、重复状态或第二个凭据存储服务。
extension QuotaViewModel {
    func setMonitorAccountDisabled(_ disabled: Bool, accountID: String) async {
        let context = beginAccountMutation(accountID: accountID)
        let account = monitorAccounts.first { $0.id == accountID }
        if disabled, let account { removeQuotaEntry(provider: account.provider, accountKey: account.accountKey) }
        await monitorCoordinator.setDisabled(disabled, accountID: accountID, revision: context.revision)
        guard canApplyMutation(context) else { return }
        await finishScopedRefresh(provider: account?.provider ?? .codex, context: refreshContext())
    }

    func deleteMonitorAccount(accountID: String) async {
        guard let account = monitorAccounts.first(where: { $0.id == accountID }), account.canDelete else { return }
        let context = beginAccountMutation(accountID: accountID)
        removeQuotaEntry(provider: account.provider, accountKey: account.accountKey)
        monitorAccounts.removeAll { $0.id == accountID }
        await monitorCoordinator.deleteOwnedAccount(accountID: accountID, revision: context.revision)
        guard canApplyMutation(context) else { return }
        await monitorCoordinator.forgetSnapshotAccount(provider: account.provider, accountKey: account.accountKey,
                                                       revision: context.revision, mutationAccountID: accountID)
        guard canApplyMutation(context) else { return }
        await finishScopedRefresh(provider: account.provider, context: refreshContext())
    }

    /// Delete an account imported from a local IDE (Cursor, Trae) via "Scan for IDEs".
    ///
    /// These accounts own no credential — they exist only as imported quota data — so
    /// deleting one means clearing every copy of that data: the in-memory quotas, the
    /// `persisted.ideQuotas` UserDefaults mirror, the Monitor snapshot, any Monitor
    /// disabled flag, and the menu bar selection (issue #213).
    ///
    /// The Monitor state is cleared in **every** mode, not only Monitor mode: these rows
    /// are only shown outside Monitor mode (Monitor rows are dispatched to
    /// `deleteMonitorAccount` first), while `initializeQuotaOnlyMode()` bootstraps from
    /// the Monitor snapshot, so a stale entry would restore the account on the next
    /// switch back into Monitor mode. The removal is targeted rather than a
    /// `finish(quotas:)` rewrite because outside Monitor mode `providerQuotas` holds
    /// that mode's quota data, which must not overwrite the Monitor snapshot.
    func deleteAutoDetectedAccount(provider: AIProvider, accountKey: String) async {
        guard provider.isImportedFromLocalIDE else { return }
        let accountID = MonitorAccount.make(provider: provider, accountKey: accountKey, source: .localIDE).id
        let context = beginAccountMutation(accountID: accountID)
        removeQuotaEntry(provider: provider, accountKey: accountKey)
        monitorAccounts.removeAll { $0.provider == provider && $0.accountKey == accountKey }
        await monitorCoordinator.forgetSnapshotAccount(provider: provider, accountKey: accountKey, revision: context.revision, mutationAccountID: accountID)
        guard canApplyMutation(context) else { return }
        await finishScopedRefresh(provider: provider, context: refreshContext())
    }

    /// Remove one account's quota entry from the in-memory map and, for IDE-imported
    /// providers, from the `persisted.ideQuotas` UserDefaults mirror.
    ///
    /// Deliberately synchronous so it can be re-applied after a suspension point without
    /// introducing another one.
    ///
    /// - Returns: `true` when an entry was actually removed.
    @discardableResult
    func removeQuotaEntry(provider: AIProvider, accountKey: String) -> Bool {
        // 订阅和账号错误可独立于 quota 存在，删除时必须一起清理。
        subscriptionInfos[provider]?.removeValue(forKey: accountKey)
        monitorAccountIssues.removeValue(forKey: QuotaAccountID(provider: provider, accountKey: accountKey))
        var quotas = providerQuotas[provider] ?? [:]
        let removed = quotas.removeValue(forKey: accountKey) != nil
        if quotas.isEmpty {
            providerQuotas.removeValue(forKey: provider)
        } else {
            providerQuotas[provider] = quotas
        }
        if Self.ideProvidersToSave.contains(provider) {
            // Cursor/Trae quotas are mirrored into UserDefaults; rewrite the mirror so
            // the deleted account does not resurrect on the next launch (issue #213).
            savePersistedIDEQuotas()
        }
        return removed
    }

    func saveOpenRouterAccount(label: String, apiKey: String, existingAccountID: String? = nil) async throws {
        try await saveMonitorAPIKeyAccount(
            provider: .openRouter,
            label: label,
            apiKey: apiKey,
            existingAccountID: existingAccountID
        )
    }

    func saveAmpAccount(label: String, apiKey: String, existingAccountID: String? = nil) async throws {
        try await saveMonitorAPIKeyAccount(
            provider: .amp,
            label: label,
            apiKey: apiKey,
            existingAccountID: existingAccountID
        )
    }

    func saveFactoryDroidAccount(label: String, apiKey: String, existingAccountID: String? = nil) async throws {
        try await saveMonitorAPIKeyAccount(
            provider: .factoryDroid,
            label: label,
            apiKey: apiKey,
            existingAccountID: existingAccountID
        )
    }

    private func saveMonitorAPIKeyAccount(
        provider: AIProvider,
        label: String,
        apiKey: String,
        existingAccountID: String?
    ) async throws {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let mutationID = existingAccountID ?? MonitorAccount.make(provider: provider, accountKey: trimmedLabel, source: .quotioKeychain).id
        let context = beginAccountMutation(accountID: mutationID)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedKey.isEmpty else { throw MonitorRuntimeError.invalidCredential }
        guard provider != .amp || trimmedLabel.caseInsensitiveCompare(AmpQuotaFetcher.localAccountKey) != .orderedSame else {
            throw MonitorRuntimeError.invalidCredential
        }

        let account: MonitorAccount
        if let existingAccountID,
           let existing = monitorAccounts.first(where: { $0.id == existingAccountID && $0.provider == provider }) {
            guard !monitorAccounts.contains(where: {
                $0.id != existing.id
                    && $0.provider == provider
                    && $0.accountKey.caseInsensitiveCompare(trimmedLabel) == .orderedSame
            }) else { throw MonitorRuntimeError.invalidCredential }
            account = MonitorAccount(
                id: existing.id,
                provider: existing.provider,
                accountKey: trimmedLabel,
                displayName: trimmedLabel,
                source: existing.source,
                credentialReference: existing.credentialReference,
                canDelete: existing.canDelete,
                isDisabled: existing.isDisabled
            )
            _ = await MonitorCredentialVault.shared.credential(for: existing.id)
            guard canCommit(context) else { return }
            if existing.accountKey != trimmedLabel {
                providerQuotas[provider]?.removeValue(forKey: existing.accountKey)
            }
        } else {
            guard !monitorAccounts.contains(where: {
                $0.provider == provider && $0.accountKey.caseInsensitiveCompare(trimmedLabel) == .orderedSame
            }) else { throw MonitorRuntimeError.invalidCredential }
            account = .make(
                provider: provider,
                accountKey: trimmedLabel,
                source: .quotioKeychain,
                credentialReference: "keychain",
                canDelete: true
            )
        }

        try await MonitorCredentialVault.shared.save(
            MonitorOAuthCredential(
                accessToken: trimmedKey,
                refreshToken: nil,
                idToken: nil,
                accountID: nil,
                expiresAt: nil,
                extra: [:]
            ),
            metadata: account
        )
        let accounts = await discoverMonitorAccounts(merging: providerQuotas)
        guard canCommit(context) else { return }
        monitorAccounts = accounts
        await refreshQuotasDirectly(force: true)
    }

    /// 删除完成后立即更新目录、额度、套餐和固定项。推进账号世代，使删除前
    /// 已挂起的上游请求不能把同键账号重新写回；并行删除不同账号仍保持独立。
    func commitAuthFileDeletion(_ file: AuthFile) {
        _ = beginAccountMutation(accountID: "cpa:" + file.id)
        // CPA 按文件名删除，而不是只删除一个 authIndex。清理该文件所有运行描述，
        // 但同名、明确不同目录的本地文件不能被顺带移除。
        let removed = authFiles.filter { $0.name == file.name && $0.providerType == file.providerType }
        let records = removed.isEmpty ? [file] : removed
        let aliases = AuthFileIdentity.quotaAliases(mode: .localProxy,
            proxyRunning: true, authFiles: authFiles, directFiles: directAuthFiles)
        let matchingDisks = directAuthFiles.filter { disk in
            disk.provider == file.providerType && disk.filename == file.name && records.contains { record in
                guard let path = record.path, !path.isEmpty else { return false }
                return URL(fileURLWithPath: path).standardizedFileURL.path
                    == URL(fileURLWithPath: disk.filePath).standardizedFileURL.path
            }
        }
        if let provider = file.providerType {
            let canonical = Set(records.map { $0.quotaLookupKey.isEmpty ? $0.name : $0.quotaLookupKey })
            let keys = canonical.union((aliases[provider] ?? [:]).filter { canonical.contains($0.value) }.map(\.key))
            clearQuotaAccounts(provider: provider, keys: keys)
        }
        authFiles.removeAll { $0.name == file.name && $0.providerType == file.providerType }
        let diskIDs = Set(matchingDisks.map(\.id))
        directAuthFiles.removeAll { diskIDs.contains($0.id) }
        syncMenuBarSelection()
        notifyQuotaDataChanged()
    }

    /// 编辑／删除插件连接时，只清理实际移除或换密钥的额度；未改动的 Key、
    /// 其它连接和用户手动选择偏好保留。名称旧键仅在目录明确唯一时清理。
    func prepareCustomProviderQuotaMutation(previous: CustomProvider?, replacement: CustomProvider?,
                                            legacyNameIsUnique: Bool = false) {
        let isMainstream = { (type: CustomProviderType?) -> Bool in
            guard let type else { return false }
            return type == .glmCompatibility || type == .clinePass
                || type == .deepseekCompatibility || type == .moonshotCompatibility || type == .minimaxCompatibility
        }
        let relevant = isMainstream(previous?.type) || isMainstream(replacement?.type)
        guard relevant else { return }
        _ = beginAccountMutation(accountID: "custom:" + (previous?.id ?? replacement?.id ?? UUID()).uuidString)
        guard let previous, isMainstream(previous.type) else { return }
        let provider: AIProvider
        switch previous.type {
        case .glmCompatibility: provider = .glm
        case .clinePass: provider = .clinePass
        case .deepseekCompatibility: provider = .deepseek
        case .moonshotCompatibility: provider = .moonshot
        case .minimaxCompatibility: provider = .minimax
        default: return
        }
        var removed = Set<String>()
        var preservedPins = Set<String>()
        if previous.type == .glmCompatibility || previous.type == .deepseekCompatibility || previous.type == .moonshotCompatibility {
            let keyBuilder: (UUID, UUID) -> String
            switch previous.type {
            case .glmCompatibility: keyBuilder = GLMQuotaFetcher.quotaAccountKey
            case .deepseekCompatibility: keyBuilder = DeepSeekQuotaFetcher.quotaAccountKey
            case .moonshotCompatibility: keyBuilder = MoonshotQuotaFetcher.quotaAccountKey
            default: keyBuilder = GLMQuotaFetcher.quotaAccountKey
            }
            let retained = replacement?.type == previous.type ? replacement?.apiKeys ?? [] : []
            // 编辑密钥内容不改变该条目的 UUID 身份。丢弃旧额度，但保留用户对此
            // 槽位的固定选择；只有实际删除 Key／连接才移除固定项。
            preservedPins = Set(retained.map { keyBuilder(previous.id, $0.id) })
            for key in previous.apiKeys where !retained.contains(where: { $0.id == key.id && $0.apiKey == key.apiKey }) {
                removed.insert(keyBuilder(previous.id, key.id))
            }
        } else {
            if replacement?.type == previous.type && replacement?.name == previous.name { preservedPins.insert(previous.name) }
            let sameKeys = replacement?.apiKeys.map(\.apiKey) == previous.apiKeys.map(\.apiKey)
            if replacement?.type != previous.type || replacement?.name != previous.name || !sameKeys {
                removed.insert(previous.name)
            }
        }
        if legacyNameIsUnique, replacement == nil || replacement?.name != previous.name || !removed.isEmpty {
            removed.insert(previous.name)
            if replacement?.type == previous.type && replacement?.name == previous.name { preservedPins.insert(previous.name) }
        }
        clearQuotaAccounts(provider: provider, keys: removed, preservingPins: preservedPins)
        notifyQuotaDataChanged()
    }

    private func clearQuotaAccounts(provider: AIProvider, keys: Set<String>, preservingPins: Set<String> = []) {
        for key in keys {
            providerQuotas[provider]?.removeValue(forKey: key)
            subscriptionInfos[provider]?.removeValue(forKey: key)
            monitorAccountIssues.removeValue(forKey: QuotaAccountID(provider: provider, accountKey: key))
        }
        if providerQuotas[provider]?.isEmpty == true { providerQuotas.removeValue(forKey: provider) }
        menuBarSettings.selectedItems.removeAll {
            $0.aiProvider == provider && keys.contains($0.accountKey) && !preservingPins.contains($0.accountKey)
        }
    }

    func deleteAuthFile(_ file: AuthFile) async {
        guard let client = apiClient else { return }
        let context = beginAccountMutation(accountID: "cpa:" + file.id)
        let session = proxyManager.runtimeSessionID
        do {
            try await client.deleteAuthFile(name: file.name)
            guard canApplyMutation(context), modeManager.revision == context.modeRevision,
                  apiClient === client, proxyManager.runtimeSessionID == session else { return }
            // 删除与启停共用目录失效边界。先废弃旧模型请求，再等待原扫描和目录事务，
            // 删除前的迟到响应不能让已失去唯一账号的型号重新进入配置页或受管菜单。
            let modelRefresh = invalidateModelsAfterCPAAccountChange(source: refreshContext())
            commitAuthFileDeletion(file)
            var disabledSet = loadDisabledAuthFiles()
            disabledSet.remove(file.name)
            disabledSet.remove(file.quotaLookupKey)
            saveDisabledAuthFiles(disabledSet)
            // 没有 path 的 CPA 响应不能证明本地文件归属，删除后重新扫描本地目录，
            // 以磁盘实际结果消除旧快照，而不是按同名误删另一认证目录的记录。
            await loadDirectAuthFiles()
            await refreshData(refreshQuotas: false)
            await refreshModelsAfterCPAAccountChange(modelRefresh)
        } catch {
            if canApplyMutation(context), apiClient === client, proxyManager.runtimeSessionID == session {
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleAuthFileDisabled(_ file: AuthFile) async {
        guard let client = apiClient else {
            Log.error("toggleAuthFileDisabled: No API client available")
            return
        }

        let newDisabled = !file.disabled
        let source = refreshContext()

        do {
            Log.debug("toggleAuthFileDisabled: Setting \(file.name) disabled=\(newDisabled)")
            try await client.setAuthFileDisabled(name: file.name, disabled: newDisabled)
            // 管理请求返回时可能已切模式／代理会话；旧操作不能废弃新页面的目录或修改其禁用偏好。
            guard canUseRefreshSource(source), apiClient === client else { return }

            // Update local persistence
            var disabledSet = loadDisabledAuthFiles()
            if newDisabled {
                disabledSet.insert(file.name)
            } else {
                disabledSet.remove(file.name)
            }
            saveDisabledAuthFiles(disabledSet)

            let modelRefresh = invalidateModelsAfterCPAAccountChange(source: source)

            Log.debug("toggleAuthFileDisabled: Success, refreshing data")
            await refreshData()
            // 保留原账号刷新顺序，随后复用原目录加载入口；过期页面／手动新刷新由原世代校验拒绝。
            await refreshModelsAfterCPAAccountChange(modelRefresh)
        } catch {
            guard canUseRefreshSource(source), apiClient === client else { return }
            Log.error("toggleAuthFileDisabled: Failed - \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// 重置单个凭据在 CPA 内核中的冷却或配额耗尽惩罚状态。
    func resetAuthFileCooldown(authIndex: String) async {
        guard let client = apiClient else {
            Log.error("resetAuthFileCooldown: No API client available")
            return
        }
        let trimmed = authIndex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let source = refreshContext()
        do {
            Log.debug("resetAuthFileCooldown: Resetting cooldown for authIndex=\(trimmed)")
            try await client.resetCredentialCooldown(authIndex: trimmed)
            guard canUseRefreshSource(source), apiClient === client else { return }
            // 冷却解除会让凭据重新加入可用来源集合，同型号可能从单账号恢复为账号池。
            let modelRefresh = invalidateModelsAfterCPAAccountChange(source: source)
            await refreshData(refreshQuotas: false)
            await refreshModelsAfterCPAAccountChange(modelRefresh)
        } catch {
            guard canUseRefreshSource(source), apiClient === client else { return }
            Log.error("resetAuthFileCooldown: Failed - \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// 一键解除所有当前处于冷却或限流惩罚期的凭据。
    func resetAllCooldowns() async {
        guard let client = apiClient else {
            Log.error("resetAllCooldowns: No API client available")
            return
        }
        let coolingIndexes = Set(authFiles.filter(\.hasActiveCooldown).compactMap(\.authIndex).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        guard !coolingIndexes.isEmpty else { return }
        let source = refreshContext()
        var firstError: String?
        var didReset = false
        for index in coolingIndexes {
            do {
                try await client.resetCredentialCooldown(authIndex: index)
                didReset = true
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        guard canUseRefreshSource(source), apiClient === client else { return }
        if let firstError {
            errorMessage = firstError
        }
        let modelRefresh = didReset ? invalidateModelsAfterCPAAccountChange(source: source) : nil
        await refreshData(refreshQuotas: false)
        await refreshModelsAfterCPAAccountChange(modelRefresh)
    }

    // MARK: - Antigravity IDE 账号切换

    /// 活跃状态仍读取主类持有的原切换器，不在扩展重复探测 IDE 数据库。
    /// Check if an Antigravity account is currently active in the IDE
    /// Simply compares email from database with the given email
    func isAntigravityAccountActive(email: String) -> Bool {
        return antigravitySwitcher.isActiveAccount(email: email)
    }

    /// 完整保留原切换执行；只有成功状态才调用不重新检测活跃账号的额度刷新，顺序不变。
    /// Switch Antigravity account in the IDE
    func switchAntigravityAccount(email: String) async {
        await antigravitySwitcher.executeSwitchForEmail(email)

        // Refresh to update active account
        if case .success = antigravitySwitcher.switchState {
            await refreshAntigravityQuotasWithoutDetect()
        }
    }

    /// 确认入口继续写入原切换器的状态机，不增加 ViewModel 状态或账号刷新世代。
    /// Begin the switch confirmation flow
    func beginAntigravitySwitch(accountId: String, email: String) {
        antigravitySwitcher.beginSwitch(accountId: accountId, accountEmail: email)
    }

    /// 取消继续委托原切换器，不引入新的任务句柄或取消规则。
    /// Cancel the switch operation
    func cancelAntigravitySwitch() {
        antigravitySwitcher.cancelSwitch()
    }

    /// 结果关闭继续复用原切换器的收尾，不清理其他账号状态或额度。
    /// Dismiss switch result
    func dismissAntigravitySwitchResult() {
        antigravitySwitcher.dismissResult()
    }
}
