//
//  QuotaViewModel+OAuth.swift
//  Quotio
//

import Foundation
import AppKit

/// CPA、Monitor 与 CLI 的原有授权入口及 UI 状态发布。
/// 扩展继续访问主类唯一持有的 CPAOAuthSessionCoordinator 与 Kiro 获取器，不复制会话所有者。
/// CPA 的 client／模式／代理会话检查、手动回调与取消继续委托原协调器；各提供商协议与轮询规则保留。
/// Monitor 的 Claude 手动交换及跨提供商取消使用所属会话校验，拒绝旧请求、旧通知和旧收尾覆盖新授权。
/// 原有局部 Task 仍在原方法内创建，任务句柄、账号世代及 oauthState 存储继续归主类。
extension QuotaViewModel {
    func startOAuth(for provider: AIProvider, authMethod: AuthCommand? = nil, launchMode: OAuthLaunchMode = .manual,
                    githubHost: GitHubHost? = nil) async {
        // 企业主机只属于监控模式的 Copilot 设备流；不能静默丢弃后启动另一个提供商／公共站点授权。
        guard githubHost == nil || (provider == .copilot && modeManager.isMonitorMode) else {
            oauthState = OAuthState(provider: provider, status: .error, error: "oauth.githubHost.invalid".localized())
            return
        }
        // 新授权意图先同步废弃旧 Claude 交换；即使 actor 尚在等待网络，也不能再保存旧凭据。
        let claudeRevision = monitorOAuth.advanceClaudeSession()
        // 切换提供商或认证模式时先结束旧 CPA 会话；Monitor/CLI 登录继续走原有实现。
        cpaOAuthSession.cancel()
        if modeManager.isMonitorMode {
            await startMonitorOAuth(for: provider, claudeRevision: claudeRevision, githubHost: githubHost)
            return
        }

        // GitHub Copilot uses Device Code Flow via CLI binary, not Management API
        if provider == .copilot {
            await startCopilotAuth()
            return
        }
        
        // Kiro uses CLI-based auth with multiple options
        if provider == .kiro {
            await startKiroAuth(method: authMethod ?? .kiroGoogleLogin)
            return
        }

        guard let client = apiClient else {
            oauthState = OAuthState(provider: provider, status: .error, error: "Proxy not running. Please start the proxy first.")
            return
        }

        let modeRevision = modeManager.revision
        let runtimeSession = proxyManager.runtimeSessionID
        await cpaOAuthSession.start(provider: provider, client: client,
            contextIsCurrent: { [weak self] in
                guard let self else { return false }
                return self.modeManager.revision == modeRevision && self.apiClient === client
                    && self.proxyManager.runtimeSessionID == runtimeSession
            },
            update: { [weak self] in self?.oauthState = $0 },
            openURL: { if launchMode == .autoOpen { NSWorkspace.shared.open($0) } },
            authorized: { [weak self] in _ = await self?.refreshData() })
    }

    private func startMonitorOAuth(for provider: AIProvider, claudeRevision: UInt64, githubHost: GitHubHost? = nil) async {
        // 防止旧入口或程序调用绕过页面过滤；已有账号的发现、导入和额度能力完全保留。
        guard provider.supportsManualAuth(in: .monitor) else {
            oauthState = OAuthState(provider: provider, status: .error, error: "oauth.cpa8InvalidResponse".localized())
            return
        }
        beginAccountMutation()
        let authorization = OAuthState(provider: provider, status: .waiting)
        oauthState = authorization
        let modeRevision = modeManager.revision
        func ownsPresentation() -> Bool {
            modeManager.isMonitorMode && modeManager.revision == modeRevision
                && oauthState?.sessionID == authorization.sessionID
        }
        if provider == .claude {
            do {
                let pending = try await monitorOAuth.beginClaudeLogin(revision: claudeRevision)
                guard !Task.isCancelled, ownsPresentation() else { return }
                oauthState = OAuthState(
                    provider: provider,
                    status: .polling,
                    state: pending.state,
                    authURL: pending.url.absoluteString,
                    sessionID: authorization.sessionID
                )
            } catch is CancellationError {
                if ownsPresentation() { oauthState = nil }
            } catch {
                guard ownsPresentation() else { return }
                oauthState = OAuthState(provider: provider, status: .error, error: error.localizedDescription,
                                        sessionID: authorization.sessionID)
            }
            return
        }
        let observer = NotificationCenter.default.addObserver(
            forName: .monitorOAuthDeviceCode,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let code = notification.userInfo?["code"] as? String
            let url = notification.userInfo?["url"] as? String
            let sourceRevision = notification.userInfo?["revision"] as? UInt64
            let sourceProvider = notification.userInfo?["provider"] as? String
            Task { @MainActor [weak self] in
                // 设备授权的迟到通知同样不能覆盖随后开始的 Claude 会话。
                guard let self, self.modeManager.revision == modeRevision,
                      self.oauthState?.sessionID == authorization.sessionID,
                      sourceRevision == nil || sourceRevision == claudeRevision,
                      sourceProvider == nil || sourceProvider == provider.rawValue else { return }
                self.oauthState = OAuthState(
                    provider: provider,
                    status: .polling,
                    state: code,
                    error: code.map { String(format: "oauth.enterDeviceCode".localized(), $0) },
                    authURL: url,
                    sessionID: authorization.sessionID
                )
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        do {
            let account = try await monitorOAuth.login(provider: provider, revision: claudeRevision, githubHost: githubHost)
            guard !Task.isCancelled, ownsPresentation() else { return }
            beginAccountMutation(accountID: account.id)
            oauthState = OAuthState(provider: provider, status: .success, sessionID: authorization.sessionID)
            await refreshQuotasDirectly(force: true)
        } catch is CancellationError {
            if ownsPresentation() { oauthState = nil }
        } catch {
            guard ownsPresentation() else { return }
            guard !Task.isCancelled else { oauthState = nil; return }
            oauthState = OAuthState(provider: provider, status: .error, error: error.localizedDescription,
                                    sessionID: authorization.sessionID)
        }
    }

    func completeMonitorOAuthCode(_ code: String, provider: AIProvider) async {
        // 只接受当前 polling 会话；状态先改为 waiting，阻止重复点击再次交换同一个授权码。
        guard !Task.isCancelled, modeManager.isMonitorMode, provider == .claude,
              var authorization = oauthState, authorization.provider == provider,
              authorization.status == .polling, let expectedState = authorization.state else { return }
        beginAccountMutation()
        let modeRevision = modeManager.revision
        let sessionID = authorization.sessionID
        func ownsPresentation() -> Bool {
            modeManager.isMonitorMode && modeManager.revision == modeRevision
                && oauthState?.sessionID == sessionID && oauthState?.provider == provider
        }
        authorization.status = .waiting
        oauthState = authorization
        do {
            let account = try await monitorOAuth.completeClaudeLogin(code: code, expectedState: expectedState)
            guard !Task.isCancelled, ownsPresentation() else { return }
            beginAccountMutation(accountID: account.id)
            oauthState = OAuthState(provider: provider, status: .success, sessionID: sessionID)
            await refreshQuotasDirectly(force: true)
        } catch is CancellationError {
            // 取消仅清理本轮；新一轮即使同为 Claude，也不能被旧任务的收尾清空。
            if ownsPresentation() { oauthState = nil }
        } catch {
            guard ownsPresentation() else { return }
            // URLSession 可能以 URLError.cancelled 结束调用任务；沿用取消语义，不发布失败提示。
            guard !Task.isCancelled else { oauthState = nil; return }
            oauthState = OAuthState(provider: provider, status: .error, error: error.localizedDescription, sessionID: sessionID)
        }
    }

    /// 页面只提交点击时的会话 ID；当前 state、client 和反馈归属统一由会话协调器校验。
    func submitOAuthCallback(_ rawInput: String, for provider: AIProvider, sessionID: UUID) async throws {
        try await cpaOAuthSession.submitCallback(rawInput, provider: provider, sessionID: sessionID,
            defaultPort: Int(proxyManager.port))
    }

    /// Start GitHub Copilot authentication using Device Code Flow
    private func startCopilotAuth() async {
        oauthState = OAuthState(provider: .copilot, status: .waiting)
        
        let result = await proxyManager.runAuthCommand(.copilotLogin)
        
        if result.success {
            if let deviceCode = result.deviceCode {
                oauthState = OAuthState(provider: .copilot, status: .polling, state: deviceCode, error: result.message)
            } else {
                oauthState = OAuthState(provider: .copilot, status: .polling, error: result.message)
            }
            
            await pollCopilotAuthCompletion()
        } else {
            oauthState = OAuthState(provider: .copilot, status: .error, error: result.message)
        }
    }

    private func startKiroAuth(method: AuthCommand) async {
        oauthState = OAuthState(provider: .kiro, status: .waiting)
        
        let result = await proxyManager.runAuthCommand(method)
        
        if result.success {
            // Check if it's an import - simply wait and refresh, don't poll for new files (files might already exist)
            if method == .kiroImport {
                oauthState = OAuthState(provider: .kiro, status: .polling, error: "Importing quotas...")

                // Allow some time for file operations
                try? await Task.sleep(nanoseconds: 1_500_000_000)

                let refreshedCount = await kiroFetcher.refreshAllTokensIfNeeded()
                if refreshedCount > 0 {
                    Log.quota("[Kiro] Refreshed \(refreshedCount) token(s) after import")
                }

                await refreshData()

                // For import, we assume success if the command succeeded
                oauthState = OAuthState(provider: .kiro, status: .success)
                return
            }
            
            // For other methods (login), poll for new auth files
            if let deviceCode = result.deviceCode {
                oauthState = OAuthState(provider: .kiro, status: .polling, state: deviceCode, error: result.message)
            } else {
                oauthState = OAuthState(provider: .kiro, status: .polling, error: result.message)
            }
            
            await pollKiroAuthCompletion()
        } else {
            oauthState = OAuthState(provider: .kiro, status: .error, error: result.message)
        }
    }

    /// Poll for Copilot auth completion by monitoring auth files
    private func pollCopilotAuthCompletion() async {
        let startFileCount = authFiles.filter { $0.provider == "github-copilot" || $0.provider == "copilot" }.count
        
        for _ in 0..<90 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            
            await refreshData()
            
            let currentFileCount = authFiles.filter { $0.provider == "github-copilot" || $0.provider == "copilot" }.count
            if currentFileCount > startFileCount {
                oauthState = OAuthState(provider: .copilot, status: .success)
                return
            }
        }
        
        oauthState = OAuthState(provider: .copilot, status: .error, error: "Authentication timeout")
    }

    private func pollKiroAuthCompletion() async {
        let startFileCount = authFiles.filter { $0.provider == "kiro" }.count

        for _ in 0..<90 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            await refreshData()

            let currentFileCount = authFiles.filter { $0.provider == "kiro" }.count
            if currentFileCount > startFileCount {
                let refreshedCount = await kiroFetcher.refreshAllTokensIfNeeded()
                if refreshedCount > 0 {
                    Log.quota("[Kiro] Refreshed \(refreshedCount) token(s) after login")
                }
                await refreshData()
                oauthState = OAuthState(provider: .kiro, status: .success)
                return
            }
        }

        oauthState = OAuthState(provider: .kiro, status: .error, error: "Authentication timeout")
    }

    func cancelOAuth() {
        cpaOAuthSession.cancel()
        // UI 清空前先同步使实际写入失效；排队的 actor 清理携带截止世代，不能晚到取消新授权。
        let revision = monitorOAuth.advanceClaudeSession()
        Task { await monitorOAuth.cancel(throughClaudeRevision: revision) }
        oauthState = nil
    }
}
