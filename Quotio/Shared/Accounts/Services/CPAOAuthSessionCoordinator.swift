import Foundation

/// 原账号授权会话协调器按业务归位，全部私有字段、Task、世代、期限和回调随同一个类型保留。
/// 仍由原 QuotaViewModel 唯一持有；传输协议与管理客户端适配留在 CPA API，不创建第二份 OAuthState。
/// 保留设备流、远端取消、手动回调、模式／运行会话复核和迟到结果隔离的原执行顺序。
/// CPA 授权和手动回调共用一个会话所有者；Monitor、Copilot 与 Kiro 的独立登录实现继续保留。
/// 每次开始/取消都更换代号，旧任务即使忽略取消或稍后返回也不能覆盖新弹窗状态。
@MainActor
final class CPAOAuthSessionCoordinator {
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var pendingState: String?
    private var client: (any CPAOAuthSessionClient)?
    private var displayed: OAuthState?
    private var deadline: ContinuousClock.Instant?
    private var update: ((OAuthState?) -> Void)?
    private var contextIsCurrent: () -> Bool = { true }
    private let sleep: @Sendable () async throws -> Void
    private let now: () -> ContinuousClock.Instant

    /// 单调时钟不受用户调整系统日期影响；测试可推进时钟，验证长设备流而无需真实等待。
    init(sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.sleep = sleep
        self.now = now
    }

    func start(provider: AIProvider, client: any CPAOAuthSessionClient,
               contextIsCurrent: @escaping () -> Bool = { true },
               update: @escaping (OAuthState?) -> Void,
               openURL: @escaping (URL) -> Void = { _ in },
               authorized: @escaping () async -> Void) async {
        cancel()
        let current = UUID()
        generation = current
        self.client = client
        self.update = update
        self.contextIsCurrent = contextIsCurrent
        let running = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.run(provider: provider, client: client, generation: current,
                openURL: openURL, authorized: authorized)
        }
        task = running
        await withTaskCancellationHandler {
            await running.value
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.generation == current { self?.cancel() }
            }
        }
        if generation == current { task = nil }
    }

    func cancel() {
        generation = UUID()
        // URL 尚未返回时保留传输，以便取得迟到 state 并远端取消；已开始的轮询立即取消。
        if pendingState != nil { task?.cancel() }
        cancelPendingState()
        task = nil
        client = nil
        displayed = nil
        deadline = nil
        update?(nil)
        update = nil
        contextIsCurrent = { true }
    }

    /// 调用者必须携带点击时的会话身份，不能在提交时借用新提供商或同提供商重试后的 state。
    /// 请求与反馈均绑定原 client/provider/state/generation；迟到的成功或失败只静默结束。
    func submitCallback(_ input: String, provider: AIProvider, sessionID: UUID, defaultPort: Int) async throws {
        let current = generation
        // 先验证调用者身份，旧弹窗或已取消的提交 Task 不能结束一个后来开始的新会话。
        guard !Task.isCancelled, var snapshot = displayed, snapshot.sessionID == sessionID,
              snapshot.provider == provider, snapshot.supportsManualCallback,
              snapshot.callbackStatus != .submitting, snapshot.callbackStatus != .submitted,
              let state = pendingState, snapshot.state == state, let client,
              let deadline, now() < deadline else { throw CancellationError() }
        guard isCurrent(current) else {
            finishInvalidatedSession(current)
            throw CancellationError()
        }
        guard let redirectURL = ManagementAPIClient.resolveCallbackURL(
            provider: provider, input: input, state: state, defaultPort: defaultPort) else {
            snapshot.callbackStatus = .failed
            publish(snapshot)
            throw APIError.invalidResponse
        }
        snapshot.callbackStatus = .submitting
        publish(snapshot)
        do {
            try await client.submitOAuthCallback(provider: provider, redirectURL: redirectURL)
            guard isCurrent(current), pendingState == state, displayed?.status == .polling else { return }
            snapshot.callbackStatus = .submitted
            publish(snapshot)
        } catch {
            guard isCurrent(current), pendingState == state, displayed?.status == .polling else { return }
            snapshot.callbackStatus = .failed
            publish(snapshot)
            throw error
        }
    }

    /// 自动恢复可能直接更换 CPA 运行世代，不经过页面的停止入口；同一会话必须结束等待，
    /// 让用户可以重新授权。若 generation 已被新会话替换，则绝不能清空新弹窗。
    private func finishInvalidatedSession(_ current: UUID) {
        if generation == current { cancel() }
    }

    private func publish(_ state: OAuthState) { displayed = state; update?(state) }
    private func isCurrent(_ value: UUID) -> Bool { generation == value && !Task.isCancelled && contextIsCurrent() }

    private func cancelPendingState() {
        guard let pendingState, let client else { return }
        self.pendingState = nil
        Self.cancelRemotely(client: client, state: pendingState)
    }

    private static func cancelRemotely(client: any CPAOAuthSessionClient, state: String) {
        // 清理独立于已取消的轮询；失败不重试有副作用的管理请求，不记录 state、授权码或密钥。
        Task {
            do { _ = try await client.cancelOAuthSession(state: state) }
            catch { Log.quota("CPA OAuth 会话取消未得到确认") }
        }
    }

    private func run(provider: AIProvider, client: any CPAOAuthSessionClient, generation current: UUID,
                     openURL: (URL) -> Void, authorized: () async -> Void) async {
        guard isCurrent(current) else { finishInvalidatedSession(current); return }
        var snapshot = OAuthState(provider: provider, status: .waiting, sessionID: current)
        publish(snapshot)
        do {
            let requestedAt = now()
            let response = try await client.getOAuthURL(for: provider)
            guard isCurrent(current) else {
                if let state = response.state, !state.isEmpty { Self.cancelRemotely(client: client, state: state) }
                finishInvalidatedSession(current)
                return
            }
            guard response.status == "ok", let state = response.state, !state.isEmpty,
                  let text = response.url, let url = URL(string: text), let host = url.host, !host.isEmpty,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  response.expiresIn.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                if let state = response.state, !state.isEmpty { Self.cancelRemotely(client: client, state: state) }
                snapshot.status = .error
                snapshot.error = response.error ?? "oauth.cpa8InvalidResponse".localized()
                publish(snapshot)
                return
            }
            pendingState = state
            snapshot.state = state
            snapshot.userCode = response.userCode
            snapshot.authURL = text
            // 官方 xAI 是设备流；旧响应未带 flow 时也不展示无效回调入口。
            snapshot.isDeviceFlow = response.flow?.lowercased() == "device" || provider == .grok
                || response.userCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            // 使用服务端有效期并受 CPA 的 30 分钟会话 TTL 限制；旧浏览器流保留两分钟默认值。
            // 从发起请求时计时，不能因为 URL 请求较慢而额外延长授权码本身的寿命。
            let lifetime = min(response.expiresIn ?? (snapshot.isDeviceFlow ? 1800 : 120), 1800)
            let expiresAt = requestedAt.advanced(by: .seconds(lifetime))
            deadline = expiresAt
            snapshot.status = .polling
            publish(snapshot)
            if now() < expiresAt { openURL(url) }
            while now() < expiresAt {
                try await sleep()
                guard isCurrent(current) else { break }
                guard now() < expiresAt else { break }
                let response = try await client.pollOAuthStatus(state: state)
                guard isCurrent(current) else { break }
                switch response.status {
                case "ok":
                    pendingState = nil
                    snapshot.status = .success
                    publish(snapshot)
                    await authorized()
                    return
                case "wait": continue
                case "error":
                    cancelPendingState()
                    snapshot.status = .error
                    snapshot.error = response.error
                    publish(snapshot)
                    return
                default: throw APIError.invalidResponse
                }
            }
            // 被新会话替换时不能取消新 state；模式或 CPA 世代变更仍须清理原挂起授权。
            guard generation == current else { return }
            cancelPendingState()
            guard isCurrent(current) else { finishInvalidatedSession(current); return }
            snapshot.status = .error
            snapshot.error = "OAuth timeout"
            publish(snapshot)
        } catch {
            guard generation == current else { return }
            cancelPendingState()
            guard isCurrent(current) else { finishInvalidatedSession(current); return }
            snapshot.status = .error
            snapshot.error = error.localizedDescription
            publish(snapshot)
        }
    }
}
