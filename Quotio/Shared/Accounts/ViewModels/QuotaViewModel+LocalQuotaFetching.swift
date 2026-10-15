//
//  QuotaViewModel+LocalQuotaFetching.swift
//  Quotio
//

import Foundation

/// 本地凭据、CLI 与提供商直连接口的原有取数方法，仍属于同一个 QuotaViewModel。
/// 所有获取器继续由主类唯一创建；这里只复用原只读引用，不持有状态、刷新任务或额外缓存。
/// CPA 可接管的提供商仍先调用原接管入口；已接管但失败时保留旧值及失败提示，不改用本机其他账号。
/// 每次挂起后的账号／模式／代理会话检查、空结果处理、合并顺序与账号身份重映射保持原样。
/// 批量及单账号刷新协调继续留在主类；仅开放原跨文件调用点必需的方法，局部辅助保留 private。
extension QuotaViewModel {
    /// Claude 保持 CPA 优先；本地回退仍强制读取新值，并按原规则合并已有来源。
    /// Refresh Claude Code quota using CLI
    func refreshClaudeCodeQuotasInternal() async {
        let context = refreshContext()
        if await refreshCPAQuotas(provider: .claude) { return }
        // 用户主动刷新必须获取新值，不能继续命中五分钟的直连缓存。
        let quotas = await fetchLocalQuota(for: .claude) { await self.claudeCodeFetcher.fetchAsProviderQuota(forceRefresh: true) }
        guard canCommit(context) else { return }
        if quotas.isEmpty {
            // Only remove if no other source has Claude data
            if providerQuotas[.claude]?.isEmpty ?? true {
                providerQuotas.removeValue(forKey: .claude)
            }
        } else {
            // Merge with existing data (don't overwrite proxy data)
            if var existing = providerQuotas[.claude] {
                for (email, quota) in quotas {
                    existing[email] = quota
                }
                providerQuotas[.claude] = existing
            } else {
                providerQuotas[.claude] = quotas
            }
        }
    }

    /// Codex CLI 回退仅用于监控模式且没有现存额度时；不扩大本机凭据的适用范围。
    /// Refresh Codex quota using CLI auth file (~/.codex/auth.json)
    private func refreshCodexCLIQuotasInternal() async {
        let context = refreshContext()
        guard modeManager.isMonitorMode else { return }
        if let existing = providerQuotas[.codex], !existing.isEmpty { return }

        let quotas = await codexCLIFetcher.fetchMonitorQuotas()
        guard canCommit(context) else { return }
        if !quotas.isEmpty {
            providerQuotas[.codex] = quotas
        }
    }

    /// 只替换本地外部读取的原 Debug 钩子；钩子仍存储在主类，生产路径直接执行原读取闭包。
    private func fetchLocalQuota(for provider: AIProvider,
                                 action: @MainActor () async -> [String: ProviderQuotaData]) async -> [String: ProviderQuotaData] {
        #if DEBUG
        if let hook = localQuotaFetchHookForTesting { return await hook(provider) }
        #endif
        return await action()
    }

    /// GLM 沿用原密钥服务与空结果清理规则，异步读取完成后仍复核原刷新上下文。
    /// Refresh GLM quota using API keys from CustomProviderService
    func refreshGlmQuotasInternal() async {
        let context = refreshContext()
        let quotas = await fetchLocalQuota(for: .glm) { await self.glmFetcher.fetchAllQuotas() }
        guard canCommit(context) else { return }
        if !quotas.isEmpty {
            providerQuotas[.glm] = quotas
        } else {
            providerQuotas.removeValue(forKey: .glm)
        }
    }

    /// ClinePass 沿用原获取器和结果提交条件，不增加缓存或跨提供商回退。
    /// Refresh ClinePass quota using API keys from CustomProviderService
    func refreshClinePassQuotasInternal() async {
        let context = refreshContext()
        let quotas = await clinePassFetcher.fetchAllQuotas()
        guard canCommit(context) else { return }
        if !quotas.isEmpty {
            providerQuotas[.clinePass] = quotas
        } else {
            providerQuotas.removeValue(forKey: .clinePass)
        }
    }

    /// Warp 仍串行读取已启用条目，单条失败继续记录日志，最后按原条目名称提交。
    /// Refresh Warp quota using API keys from WarpService
    func refreshWarpQuotasInternal() async {
        let context = refreshContext()
        let warpTokens = await MainActor.run {
            WarpService.shared.tokens.filter { $0.isEnabled }
        }
        
        var results: [String: ProviderQuotaData] = [:]
        
        for entry in warpTokens {
            do {
                let quota = try await warpFetcher.fetchQuota(apiKey: entry.token)
                results[entry.name] = quota
            } catch {
                Log.quota("Failed to fetch Warp quota for \(entry.name): \(error)")
            }
        }
        
        guard canCommit(context) else { return }
        if !results.isEmpty {
            providerQuotas[.warp] = results
        } else {
            providerQuotas.removeValue(forKey: .warp)
        }
    }

    /// Kiro 保留 CPA 凭据、直读凭据、未消费原始键的三阶段映射与去重顺序。
    /// Refresh Kiro quota using IDE JSON tokens
    func refreshKiroQuotasInternal() async {
        let context = refreshContext()
        let rawQuotas = await kiroFetcher.fetchAllQuotas()
        guard canCommit(context) else { return }
        
        var remappedQuotas: [String: ProviderQuotaData] = [:]
        
        // Helper: clean filename (remove .json)
        func cleanName(_ name: String) -> String {
            name.replacingOccurrences(of: ".json", with: "")
        }
        
        // 1. Remap for Proxy AuthFiles
        var consumedRawKeys = Set<String>()
        
        for file in authFiles where file.providerType == .kiro {
            // The fetcher returns data keyed by clean filename
            let filenameKey = cleanName(file.name)
            
            if let data = rawQuotas[filenameKey] {
                // Store under the key the UI expects (AuthFile.quotaLookupKey)
                let targetKey = file.quotaLookupKey.isEmpty ? file.name : file.quotaLookupKey
                remappedQuotas[targetKey] = data
                consumedRawKeys.insert(filenameKey)
            }
        }
        
        // 2. Remap for Direct AuthFiles (fallback when proxy authFiles not yet loaded)
        for file in directAuthFiles where file.provider == .kiro {
            let filenameKey = cleanName(file.filename)

            // Skip if already processed by Proxy loop
            if consumedRawKeys.contains(filenameKey) { continue }

            if let data = rawQuotas[filenameKey] {
                let targetKey = file.menuBarAccountKey
                remappedQuotas[targetKey] = data
                consumedRawKeys.insert(filenameKey)
            }
        }
        
        // 3. Fallback: Include original keys ONLY if not mapped
        for (key, data) in rawQuotas {
            if !consumedRawKeys.contains(key) {
                remappedQuotas[key] = data
            }
        }

        if remappedQuotas.isEmpty {
            providerQuotas.removeValue(forKey: .kiro)
        } else {
            providerQuotas[.kiro] = remappedQuotas
        }
    }

    /// Antigravity 仍一次读取额度和套餐、合并套餐旧值，并在提交后按原时点检测 IDE 活跃账号。
    func refreshAntigravityQuotasInternal() async {
        let context = refreshContext()
        if await refreshCPAQuotas(provider: .antigravity) { return }
        // Fetch both quotas and subscriptions in one call (avoids duplicate API calls)
        let (quotas, subscriptions) = await antigravityFetcher.fetchAllAntigravityData()
        guard canCommit(context) else { return }
        
        providerQuotas[.antigravity] = quotas
        
        // Merge instead of replace to preserve data if API fails
        var providerInfos = subscriptionInfos[.antigravity] ?? [:]
        for (email, info) in subscriptions {
            providerInfos[email] = info
        }
        subscriptionInfos[.antigravity] = providerInfos
        
        // Detect active account in IDE (reads email directly from database)
        await antigravitySwitcher.detectActiveAccount()
    }

    /// 切换账号后的取数复用原无检测路径，避免重新探测覆盖刚完成的账号切换。
    /// Refresh Antigravity quotas without re-detecting active account
    /// Used after switching accounts (active account already set by switch operation)
    func refreshAntigravityQuotasWithoutDetect() async {
        let context = refreshContext()
        if await refreshCPAQuotas(provider: .antigravity) { return }
        let (quotas, subscriptions) = await antigravityFetcher.fetchAllAntigravityData()
        guard canCommit(context) else { return }
        
        providerQuotas[.antigravity] = quotas
        
        var providerInfos = subscriptionInfos[.antigravity] ?? [:]
        for (email, info) in subscriptions {
            providerInfos[email] = info
        }
        subscriptionInfos[.antigravity] = providerInfos
        // Note: Don't call detectActiveAccount() here - already set by switch operation
    }

    /// Codex 的 CPA 接管判定保持在直连读取之前，原会话失效时不发布迟到额度。
    func refreshOpenAIQuotasInternal() async {
        let context = refreshContext()
        if await refreshCPAQuotas(provider: .codex) { return }
        let quotas = await openAIFetcher.fetchAllCodexQuotas()
        guard canCommit(context) else { return }
        providerQuotas[.codex] = quotas
    }

    /// 监控与完整模式继续采用各自原来源；CLI 回退开关和调用顺序不合并。
    func refreshCodexQuotasInternal(includeCLIFallback: Bool) async {
        let context = refreshContext()
        if modeManager.isMonitorMode {
            let quotas = await codexCLIFetcher.fetchMonitorQuotas()
            guard canCommit(context) else { return }
            providerQuotas[.codex] = quotas
            return
        }
        await refreshOpenAIQuotasInternal()
        if includeCLIFallback {
            await refreshCodexCLIQuotasInternal()
        }
    }

    /// 本地 Copilot 沿用原获取器及提交校验；监控模式的别名合并另在监控扩展维护。
    func refreshCopilotQuotasInternal() async {
        let context = refreshContext()
        let quotas = await copilotFetcher.fetchAllCopilotQuotas()
        guard canCommit(context) else { return }
        providerQuotas[.copilot] = quotas
    }
}
