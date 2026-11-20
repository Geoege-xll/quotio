//
//  QuotaViewModel+ProxyLifecycle.swift
//  Quotio
//

import Foundation
import Observation

/// 代理启动以进程已就绪为完成边界。主类继续持有客户端、后台初始化及轮询任务。
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
        await deepseekFetcher.updateProxyConfiguration()
        await moonshotFetcher.updateProxyConfiguration()
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

    /// 启动后的禁用同步保留原目录与偏好来源，每个账号请求前都复核取消、客户端身份和代理运行会话。
    /// Sync local disabled state to backend after proxy starts
    private func syncDisabledStatesToBackend() async {
        guard hasCurrentCPAAccountDirectory, let client = apiClient else { return }
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
            guard canUseRefreshSource(source), apiClient === client,
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
        // 首轮额度绕过节流。第二次目录失败时继续保留快照，启动后的其他服务仍按原流程处理。
        if hasCurrentCPAAccountDirectory { await refreshQuotas() }
        try checkSession()
    }

    #if DEBUG
    /// 仅替换额度 I/O 的范围，真实目录、禁用同步、来源复核及调用顺序仍经过生产流水线。
    /// 该入口不暴露状态写入权限；测试不启动真实 CPA，也不改变生产批量提供商集合。
    func refreshProxyStartupDataForTesting(sessionID: UUID, refreshQuotas: () async -> Void) async throws {
        try await refreshProxyStartupData(sessionID: sessionID, refreshQuotas: refreshQuotas)
    }
    #endif

    /// 多个入口仍使用同一个启动协调器。进程就绪后立即装配客户端并返回，
    /// 账号目录和首轮额度交由可取消的会话初始化任务处理。
    func startProxy() async {
        await proxyStartFlow.run { [self] in
            guard !proxyManager.proxyStatus.running || apiClient == nil else { return }
            invalidateAgentModelSource()
            errorMessage = nil
            do {
                try await proxyManager.start()
                try Task.checkCancellation()
                guard proxyManager.proxyStatus.running else { return }
                let session = proxyManager.runtimeSessionID
                setupAPIClient()
                startAutoRefresh()
                restartWarmupScheduler()
                scheduleProxyStartupData(sessionID: session)
            } catch is CancellationError {
                // 停止服务属于正常操作，不显示启动错误，也不继续旧初始化。
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    /// 原目录、禁用同步、额度与预热顺序继续在同一会话内执行。
    func completeProxyStartupData(sessionID: UUID) async {
        do {
            try await refreshProxyStartupData(sessionID: sessionID)
            await runWarmupCycle()
            try Task.checkCancellation()
            guard proxyManager.runtimeSessionID == sessionID, proxyManager.proxyStatus.running else { return }

            Task { [weak self] in
                guard let self, proxyManager.runtimeSessionID == sessionID,
                      proxyManager.proxyStatus.running else { return }
                await proxyManager.checkForUpgrade()
            }

            if UserDefaults.standard.bool(forKey: "autoStartTunnel"), tunnelManager.installation.isInstalled {
                await tunnelManager.startTunnel(port: proxyManager.port)
            }
        } catch is CancellationError {
            // 旧会话结束后退出后台流水线，保留新会话的界面状态。
        } catch {
            if !Task.isCancelled, proxyManager.runtimeSessionID == sessionID {
                errorMessage = error.localizedDescription
            }
        }
    }
}
