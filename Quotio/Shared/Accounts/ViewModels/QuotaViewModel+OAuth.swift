//
//  QuotaViewModel+OAuth.swift
//  Quotio
//

import Foundation
import AppKit

/// CPA 管理接口和原 CLI 设备流程统一在原 ViewModel 发布会话状态。
extension QuotaViewModel {
    func startOAuth(for provider: AIProvider, authMethod: AuthCommand? = nil,
                    launchMode: OAuthLaunchMode = .manual) async {
        // 先同步失效旧 CPA 会话，迟到的轮询或手动回调不能发布到新弹窗。
        cpaOAuthSession.cancel()

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
            authorized: { [weak self] in
                guard let self, self.modeManager.revision == modeRevision, self.apiClient === client,
                      self.proxyManager.runtimeSessionID == runtimeSession else { return }
                // 授权新增账号之后复用已有账号变更桥接，菜单由单账号切换到账号池时不能保留旧说明。
                await self.refreshAfterCPAAccountChange()
            })
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
        let source = refreshContext(), client = apiClient
        oauthState = OAuthState(provider: .kiro, status: .waiting)
        
        let result = await proxyManager.runAuthCommand(method)
        guard canUseRefreshSource(source), apiClient === client else { return }
        
        if result.success {
            // Check if it's an import - simply wait and refresh, don't poll for new files (files might already exist)
            if method == .kiroImport {
                oauthState = OAuthState(provider: .kiro, status: .polling, error: "Importing quotas...")

                // Allow some time for file operations
                try? await Task.sleep(nanoseconds: 1_500_000_000)

                // 授权完成后由 CPA 确认目录；不能对其他本机 Kiro 凭据做批量续期。
                guard canUseRefreshSource(source), apiClient === client else { return }
                await refreshAfterCPAAccountChange()
                guard canUseRefreshSource(source), apiClient === client else { return }

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
        let source = refreshContext(), client = apiClient
        let startFileCount = authFiles.filter { $0.provider == "github-copilot" || $0.provider == "copilot" }.count
        
        for _ in 0..<90 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard canUseRefreshSource(source), apiClient === client else { return }
            
            await refreshData()
            guard canUseRefreshSource(source), apiClient === client else { return }
            
            let currentFileCount = authFiles.filter { $0.provider == "github-copilot" || $0.provider == "copilot" }.count
            if currentFileCount > startFileCount {
                await refreshModelsAfterCPAAccountChange(invalidateModelsAfterCPAAccountChange(source: source))
                guard canUseRefreshSource(source), apiClient === client else { return }
                oauthState = OAuthState(provider: .copilot, status: .success)
                return
            }
        }
        
        oauthState = OAuthState(provider: .copilot, status: .error, error: "Authentication timeout")
    }

    private func pollKiroAuthCompletion() async {
        let source = refreshContext(), client = apiClient
        let startFileCount = authFiles.filter { $0.provider == "kiro" }.count

        for _ in 0..<90 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard canUseRefreshSource(source), apiClient === client else { return }

            await refreshData()
            guard canUseRefreshSource(source), apiClient === client else { return }

            let currentFileCount = authFiles.filter { $0.provider == "kiro" }.count
            if currentFileCount > startFileCount {
                // 授权完成后由 CPA 确认目录；不能对其他本机 Kiro 凭据做批量续期。
                guard canUseRefreshSource(source), apiClient === client else { return }
                await refreshAfterCPAAccountChange()
                guard canUseRefreshSource(source), apiClient === client else { return }
                oauthState = OAuthState(provider: .kiro, status: .success)
                return
            }
        }

        oauthState = OAuthState(provider: .kiro, status: .error, error: "Authentication timeout")
    }

    func cancelOAuth() {
        cpaOAuthSession.cancel()
        oauthState = nil
    }
}
