import Foundation

/// CPA v8 授权所需的最小传输契约与现有管理客户端适配成组维护。
/// 只描述原四个异步 API，不保存授权 UI 状态、轮询任务、会话期限或世代；业务编排归共享账号协调器。
/// 注入最小的 v8 OAuth 契约，让取消、迟到响应和会话替换可在不登录真实账号的情况下回归。
nonisolated protocol CPAOAuthSessionClient: Sendable {
    func getOAuthURL(for provider: AIProvider) async throws -> OAuthURLResponse
    func pollOAuthStatus(state: String) async throws -> OAuthStatusResponse
    func cancelOAuthSession(state: String) async throws -> Bool
    func submitOAuthCallback(provider: AIProvider, redirectURL: String) async throws
}

extension ManagementAPIClient: CPAOAuthSessionClient {}
