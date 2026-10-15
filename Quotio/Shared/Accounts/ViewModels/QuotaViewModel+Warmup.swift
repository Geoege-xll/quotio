//
//  QuotaViewModel+Warmup.swift
//  Quotio
//

import Foundation

/// 预热设置、时间计算、认证及模型选择和逐模型执行的原有流程，仍作用于同一个 QuotaViewModel。
/// 扩展不保存状态、任务或缓存；预热设置与 WarmupService 继续由主类持有，生产环境默认仍复用原共享设置。
/// 调度任务、整轮及单账号防重、模型缓存和可观察状态字典继续留在主类，不开放可变私有存储或 private(set)。
/// 单账号入口取得原防重标记后才调用本文件的执行重载；原 await、串行顺序、取消检查、错误与进度提交不重排。
/// 主类同步状态更新入口继续以原读改写方式发布 Observation 状态；计划更新不会借此清除上次失败。
/// 模型目录仍经主类原八小时缓存读取；不增加回退、账号别名、会话规则或新的请求来源。
extension QuotaViewModel {
    /// 启用状态仍从原设置实例读取；默认共享实例与账号标识格式不变。
    func isWarmupEnabled(for provider: AIProvider, accountKey: String) -> Bool {
        warmupSettings.isEnabled(provider: provider, accountKey: accountKey)
    }

    /// 切换仍只支持 Antigravity；复用原设置回调触发调度，不在扩展另建任务。
    func toggleWarmup(for provider: AIProvider, accountKey: String) {
        guard provider == .antigravity else {
            // Warmup not supported for this provider; no log.
            return
        }
        warmupSettings.toggle(provider: provider, accountKey: accountKey)
        // Warmup toggle state changed; no log.
    }

    /// 保留提供商限制与重复值直接返回规则，继续通过原 manager 持久化。
    func setWarmupEnabled(_ enabled: Bool, provider: AIProvider, accountKey: String) {
        guard provider == .antigravity else {
            // Warmup not supported for this provider; no log.
            return
        }
        if warmupSettings.isEnabled(provider: provider, accountKey: accountKey) == enabled {
            return
        }
        warmupSettings.setEnabled(enabled, provider: provider, accountKey: accountKey)
        // Warmup toggle state changed; no log.
    }

    /// 保留 Calendar.current 与严格晚于当前时间的判定；相同或已过的时刻仍安排到明天。
    func nextDailyRunDate(minutes: Int, now: Date) -> Date {
        let calendar = Calendar.current
        let hour = minutes / 60
        let minute = minutes % 60
        let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if today > now {
            return today
        }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// 逐模型执行仍由主类完成账号防重后调用；保留所选与可用模型交集、串行执行、取消及错误进度规则。
    func warmupAccount(
        provider: AIProvider,
        accountKey: String,
        availableModels: [WarmupModelInfo],
        authIndex: String,
        apiClient: ManagementAPIClient
    ) async {
        guard provider == .antigravity else {
            // Warmup not supported for this provider; no log.
            return
        }
        let availableIds = availableModels.map(\.id)
        let selectedModels = warmupSettings.selectedModels(provider: provider, accountKey: accountKey)
        let models = selectedModels.filter { availableIds.contains($0) }
        guard !models.isEmpty else {
            // Warmup skipped when no matching models; no log.
            return
        }
        let account = WarmupAccountKey(provider: provider, accountKey: accountKey)
        updateWarmupStatus(for: account) { status in
            status.isRunning = true
            status.lastError = nil
            status.progressTotal = models.count
            status.progressCompleted = 0
            status.currentModel = nil
            for model in models {
                status.modelStates[model] = .pending
            }
        }
        
        for model in models {
            if Task.isCancelled { break }
            do {
                updateWarmupStatus(for: account) { status in
                    status.currentModel = model
                    status.modelStates[model] = .running
                }
                try await warmupService.warmup(
                    managementClient: apiClient,
                    authIndex: authIndex,
                    model: model
                )
                updateWarmupStatus(for: account) { status in
                    status.progressCompleted += 1
                    status.modelStates[model] = .succeeded
                }
            } catch {
                updateWarmupStatus(for: account) { status in
                    status.progressCompleted += 1
                    status.modelStates[model] = .failed
                    status.lastError = error.localizedDescription
                }
            }
        }
        updateWarmupStatus(for: account) { status in
            status.isRunning = false
            status.currentModel = nil
            status.lastRun = Date()
        }
    }

    /// 仍按原账号身份寻找凭据并复用主类缓存入口，排序只影响返回展示，不改缓存内容。
    func warmupAvailableModels(provider: AIProvider, accountKey: String) async -> [String] {
        guard provider == .antigravity else { return [] }
        guard let apiClient else { return [] }
        guard let authInfo = warmupAuthInfo(provider: provider, accountKey: accountKey) else { return [] }
        let models = await fetchWarmupModels(
            provider: provider,
            accountKey: accountKey,
            authFileName: authInfo.authFileName,
            apiClient: apiClient
        )
        return models.map(\.id).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// 认证信息仍只按提供商和精确 quotaLookupKey 匹配，保留非空 authIndex 与文件名校验，不猜测同邮箱账号。
    func warmupAuthInfo(provider: AIProvider, accountKey: String) -> (authIndex: String, authFileName: String)? {
        guard let authFile = authFiles.first(where: {
            $0.providerType == provider && $0.quotaLookupKey == accountKey
        }) else {
            // Warmup skipped when auth file is missing; no log.
            return nil
        }
        
        guard let authIndex = authFile.authIndex, !authIndex.isEmpty else {
            // Warmup skipped when auth index is missing; no log.
            return nil
        }
        
        let name = authFile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            // Warmup skipped when auth file name is missing; no log.
            return nil
        }
        
        return (authIndex: authIndex, authFileName: name)
    }

    /// 启用目标仍按原格式解析、仅保留 Antigravity 并按原顺序排序，不改变调度对象。
    func warmupTargets() -> [WarmupAccountKey] {
        let keys = warmupSettings.enabledAccountIds.compactMap { id in
            WarmupSettingsManager.parseAccountId(id)
        }
        return keys.filter { $0.provider == .antigravity }.sorted { lhs, rhs in
            if lhs.provider.displayName == rhs.provider.displayName {
                return lhs.accountKey < rhs.accountKey
            }
            return lhs.provider.displayName < rhs.provider.displayName
        }
    }
}
