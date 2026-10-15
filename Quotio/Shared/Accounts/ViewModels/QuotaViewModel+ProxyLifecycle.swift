//
//  QuotaViewModel+ProxyLifecycle.swift
//  Quotio
//

import Foundation
import Observation

/// 代理启动、切换、完整模式初始化及附属配置／用量观察的原有流程，仍属于同一个 QuotaViewModel。
/// 本扩展不新增存储、Task 句柄或管理器；ProxyStartFlow、管理客户端、采集器及所有状态继续由主类持有。
/// 启动仍经原协调器合并重复操作；首次读取、禁用同步、再次读取、预热、升级检查与隧道启动不重新排序。
/// 停止、客户端替换、三种自动刷新循环和独立恢复任务仍在主类，保留原取消传播、会话隔离和受保护写入。
/// 跨文件仅调用主类原同步／异步入口，不开放可变私有存储或 private(set)，不另建启动或恢复状态副本。
/// Observation 回调、原非持有句柄的 Task 及强弱引用随完整方法保留，不重复注册或改变运行时任务所有权。
extension QuotaViewModel {
    /// 主类初始化仍只注册一次原观察；回调继续弱引用同一实例并在 MainActor 重订阅，采集仍复用唯一 usageMonitor。
    /// 在组合层监听真实代理会话，无窗口/登录启动和代理自动恢复也会启动采集。
    /// Observation 的回调是一次性的；每次变化后回到 MainActor 重新订阅。
    func observeUsageLifecycle() {
        withObservationTracking {
            if proxyManager.proxyStatus.running {
                usageMonitor.start(baseURL: proxyManager.baseURL, managementKey: proxyManager.managementKey,
                                   sessionID: proxyManager.runtimeSessionID)
            } else {
                usageMonitor.stop()
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeUsageLifecycle() }
        }
    }

    /// 代理配置更新仍依次通知主类原有的十六个获取器；不并行化、不替换实例，也不增加会话或缓存。
    /// Update proxy configuration for all quota fetchers
    func updateProxyConfiguration() async {
        await antigravityFetcher.updateProxyConfiguration()
        await openAIFetcher.updateProxyConfiguration()
        await copilotFetcher.updateProxyConfiguration()
        await glmFetcher.updateProxyConfiguration()
        await claudeCodeFetcher.updateProxyConfiguration()
        await cursorFetcher.updateProxyConfiguration()
        await codexCLIFetcher.updateProxyConfiguration()
        await warpFetcher.updateProxyConfiguration()
        await clinePassFetcher.updateProxyConfiguration()
        await traeFetcher.updateProxyConfiguration()
        await kiroFetcher.updateProxyConfiguration()
        await factoryDroidFetcher.updateProxyConfiguration()
        await devinFetcher.updateProxyConfiguration()
        await grokFetcher.updateProxyConfiguration()
        await openRouterFetcher.updateProxyConfiguration()
        await ampFetcher.updateProxyConfiguration()
    }

    /// 完整模式仍先直读额度，再按原偏好决定自动启动代理或启动停服直读定时器；模式选择入口继续留在主类。
    func initializeFullMode() async {
        // Always refresh quotas directly first (works without proxy)
        await refreshQuotasUnified()
        
        let autoStartProxy = UserDefaults.standard.bool(forKey: "autoStartProxy")
        if autoStartProxy && proxyManager.isBinaryInstalled {
            await startProxy()
            // Note: checkForProxyUpgrade() is now called inside startProxy()
        } else {
            // If not auto-starting proxy, start quota auto-refresh
            startQuotaAutoRefreshWithoutProxy()
        }
    }

    /// 启动后的禁用同步保留原目录与偏好来源，每个账号请求前都复核取消、客户端身份和代理运行会话。
    /// Sync local disabled state to backend after proxy starts
    private func syncDisabledStatesToBackend() async {
        guard let client = apiClient else { return }
        let session = proxyManager.runtimeSessionID

        let localDisabled = loadDisabledAuthFiles()
        guard !localDisabled.isEmpty else { return }

        for name in localDisabled {
            // 启停或换客户端后，旧初始化不能继续向新服务同步旧账号状态。
            guard !Task.isCancelled, apiClient === client,
                  proxyManager.runtimeSessionID == session, proxyManager.proxyStatus.running else { return }
            // Only sync if this auth file exists
            guard authFiles.contains(where: { $0.name == name }) else { continue }

            do {
                try await client.setAuthFileDisabled(name: name, disabled: true)
            } catch {
                Log.error("syncDisabledStatesToBackend: Failed for \(name) - \(error.localizedDescription)")
            }
        }
    }

    /// 保留原非阻塞升级检查的被调用方法；启动流程中的 Task 创建位置、会话校验和触发顺序不变。
    /// Check for proxy upgrade (non-blocking)
    private func checkForProxyUpgrade() async {
        await proxyManager.checkForUpgrade()
    }

    /// 代理启动后的账号初始化使用真实运行会话，不依赖账号页是否打开或上一次本地刷新时间。
    /// 两次目录读取仅更新目录／客户端密钥，避免它们额外派生额度任务；禁用同步后明确执行首轮额度读取。
    /// 首轮复用原批量槽位并等待已有刷新释放，保留精确 CPA 身份、失败回退边界及菜单栏原通知入口。
    func refreshProxyStartupData(sessionID: UUID) async throws {
        try await refreshProxyStartupData(sessionID: sessionID) {
            await refreshAllQuotas(waitForAvailability: true)
        }
    }

    /// 流水线继续运行在原启动任务中；闭包只隔离最后一步取数，不保存状态或派生新任务。
    /// 生产入口固定调用原批量刷新；离线回归可使用同样带槽位与会话校验的单提供商入口，
    /// 避免测试批量路径时顺带读取本机其他提供商的真实凭据。
    private func refreshProxyStartupData(sessionID: UUID, refreshQuotas: () async -> Void) async throws {
        let source = refreshContext()
        guard let client = apiClient else { throw CancellationError() }
        func checkSession() throws {
            try Task.checkCancellation()
            guard !modeManager.isMonitorMode, canUseRefreshSource(source), apiClient === client,
                  proxyManager.proxyStatus.running, proxyManager.runtimeSessionID == sessionID else {
                throw CancellationError()
            }
        }
        try checkSession()
        await refreshData(refreshQuotas: false)
        try checkSession()
        await syncDisabledStatesToBackend()
        try checkSession()
        await refreshData(refreshQuotas: false)
        try checkSession()
        // 启动是数据来源从本地切到 CPA 的边界，必须绕过旧来源节流；手动频率也需要这一轮初始化。
        // 若启动前的直读仍占用槽位，在原启动 Task 内等待，不能静默丢掉这次 CPA 首轮读取。
        await refreshQuotas()
        try checkSession()
    }

    #if DEBUG
    /// 仅替换额度 I/O 的范围，真实目录、禁用同步、来源复核及调用顺序仍经过生产流水线。
    /// 该入口不暴露状态写入权限；测试不启动真实 CPA，也不改变生产批量提供商集合。
    func refreshProxyStartupDataForTesting(sessionID: UUID, refreshQuotas: () async -> Void) async throws {
        try await refreshProxyStartupData(sessionID: sessionID, refreshQuotas: refreshQuotas)
    }
    #endif

    /// 保留原启动协调器、目录／禁用同步、预热及后续副作用顺序；首轮额度现在明确等待完成。
    func startProxy() async {
        await proxyStartFlow.run { [self] in
            errorMessage = nil
            do {
                try await proxyManager.start()
                try Task.checkCancellation()
                guard proxyManager.proxyStatus.running else { return }
                let session = proxyManager.runtimeSessionID
                setupAPIClient()
                startAutoRefresh()
                restartWarmupScheduler()

                try await refreshProxyStartupData(sessionID: session)

                await runWarmupCycle()
                try Task.checkCancellation()
                guard proxyManager.runtimeSessionID == session, proxyManager.proxyStatus.running else { return }

                // Check for proxy upgrade (non-blocking, fire-and-forget)
                Task {
                    guard !Task.isCancelled, proxyManager.runtimeSessionID == session,
                          proxyManager.proxyStatus.running else { return }
                    await checkForProxyUpgrade()
                }

                let autoStartTunnel = UserDefaults.standard.bool(forKey: "autoStartTunnel")
                if autoStartTunnel && tunnelManager.installation.isInstalled {
                    await tunnelManager.startTunnel(port: proxyManager.port)
                }
            } catch is CancellationError {
                // 停止服务属于正常操作，不显示启动错误，也不继续旧初始化。
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    /// 切换入口继续读取真实运行状态，调用同一实例的原停止或启动方法；停止事务仍在主类写回私有状态。
    func toggleProxy() async {
        if proxyManager.proxyStatus.running {
            stopProxy()
        } else {
            await startProxy()
        }
    }
}
