//
//  QuotaViewModel+AccountMutations.swift
//  Quotio
//

import Foundation

/// 原账号变更入口复用主类的世代、凭据和 IDE 切换器。
extension QuotaViewModel {
    /// 用户主动删除 IDE 导入的账号时，同步移除偏好镜像，并定点清理旧监控快照与禁用标记。
    /// 历史兼容写入仍核对该账号的变更世代，不重写其他账号及额度历史。
    func deleteAutoDetectedAccount(provider: AIProvider, accountKey: String) async {
        guard provider.isImportedFromLocalIDE else { return }
        let accountID = MonitorAccount.make(provider: provider, accountKey: accountKey, source: .localIDE).id
        let context = beginAccountMutation(accountID: accountID)
        removeQuotaEntry(provider: provider, accountKey: accountKey)
        await monitorCoordinator.forgetSnapshotAccount(provider: provider, accountKey: accountKey, revision: context.revision, mutationAccountID: accountID)
        guard canApplyMutation(context) else { return }
        await finishScopedRefresh(context: refreshContext())
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
        if removed { persistAccountSnapshot() }
        return removed
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
        persistAccountSnapshot()
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
        persistAccountSnapshot()
        notifyQuotaDataChanged()
    }

    /// Warp 过去以配置名称作为额度键。换密钥或改名时立即废弃在途额度并清除旧值，
    /// 同名换密钥仍保留固定项。若同名本就属于多条配置，清理歧义额度但保留共享名称的固定项。
    func prepareWarpQuotaMutation(previous: WarpService.WarpToken, replacement: WarpService.WarpToken?) {
        guard previous.name != replacement?.name || previous.token != replacement?.token else { return }
        beginAccountMutation(accountID: "warp:" + previous.id.uuidString)
        let sameNameStillExists = WarpService.shared.tokens.contains { $0.id != previous.id && $0.name == previous.name }
        let keepPin = sameNameStillExists || replacement?.name == previous.name
        clearQuotaAccounts(provider: .warp, keys: [previous.name], preservingPins: keepPin ? [previous.name] : [])
        persistAccountSnapshot()
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
        guard hasCurrentCPAAccountDirectory, let client = apiClient else { return }
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
            // 删除立即同步改写展示快照；之后仅以 CPA 再确认目录，不扫描本机凭据。
            await refreshData(refreshQuotas: false)
            await refreshModelsAfterCPAAccountChange(modelRefresh)
        } catch {
            if canApplyMutation(context), apiClient === client, proxyManager.runtimeSessionID == session {
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleAuthFileDisabled(_ file: AuthFile) async {
        guard hasCurrentCPAAccountDirectory, let client = apiClient else {
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

            // 使禁用更新前在途的额度或目录拒绝提交；新目录通过原入口重新确认。
            beginAccountMutation(accountID: "cpa:" + file.id)
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
        guard hasCurrentCPAAccountDirectory, let client = apiClient else {
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
        guard hasCurrentCPAAccountDirectory, let client = apiClient else {
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
            await refreshQuota(for: .antigravity)
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
