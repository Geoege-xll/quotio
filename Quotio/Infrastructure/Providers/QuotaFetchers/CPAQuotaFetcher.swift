import Foundation

/// 代理运行时始终以 CPA 当前加载的 authIndex 查询同一凭据，避免固定目录、文件名前缀、
/// 本机 CLI 登录状态或同邮箱的另一套餐导致账号串用。$TOKEN$ 由 CPA 替换并刷新。
/// 依赖注入仅用于离线响应测试，生产请求复用现有 ManagementAPIClient。
nonisolated struct CPAQuotaFetcher: Sendable {
    let call: @Sendable (APICallRequest) async throws -> APICallResponse
    let download: @Sendable (String) async throws -> Data

    init(client: ManagementAPIClient) {
        call = { try await client.apiCall($0) }
        download = { try await client.downloadAuthFile(name: $0) }
    }

    init(call: @escaping @Sendable (APICallRequest) async throws -> APICallResponse,
         download: @escaping @Sendable (String) async throws -> Data) {
        self.call = call; self.download = download
    }

    static func supports(_ provider: AIProvider) -> Bool {
        [.antigravity, .codex, .claude, .grok].contains(provider)
    }

    func fetch(file: AuthFile) async throws -> ProviderQuotaData {
        guard !file.disabled, let provider = file.providerType, Self.supports(provider),
              let index = QuotaResponseValue.string(file.authIndex) else { throw QuotaFetchError.invalidResponse }
        // 管理列表已提供的非秘密元数据优先，避免远程 CPA 禁止下载凭据时整账号无法刷新。
        // 只在路由字段缺失时尝试下载补齐；任何 access_token 都不会离开 CPA 用于直连请求。
        var metadata = CPAQuotaMetadata(
            projectID: file.quotaProjectID,
            accountID: file.quotaAccountID,
            plan: file.quotaPlan,
            userID: file.quotaUserID
        )
        let needsDownloadedMetadata = (provider == .codex && metadata.accountID == nil)
            || (provider == .antigravity && metadata.projectID == nil)
            || (provider == .grok && metadata.userID == nil)
        if needsDownloadedMetadata, let raw = try? await download(file.name) {
            metadata.fillMissing(from: CPAQuotaMetadata(data: raw))
        }
        try Task.checkCancellation()
        var headers = ["Authorization": "Bearer $TOKEN$", "Content-Type": "application/json"]

        switch provider {
        case .grok:
            // 与官方客户端一致：credits 负责周额度，普通 billing 负责月度及按需计费。
            // 两个请求都让 CPA 用同一个 authIndex 替换 $TOKEN$，不回退本机 Grok CLI 的其他账号。
            headers["x-xai-token-auth"] = "xai-grok-cli"
            headers["x-grok-client-version"] = "0.2.91"
            headers["Accept"] = "*/*"
            headers["User-Agent"] = "grok-pager/0.2.91 grok-shell/0.2.91 (macos; aarch64)"
            if let userID = metadata.userID { headers["x-userid"] = userID }
            async let weekly = requestResult(index: index, url: "https://cli-chat-proxy.grok.com/v1/billing?format=credits", headers: headers)
            async let monthly = requestResult(index: index, url: "https://cli-chat-proxy.grok.com/v1/billing", headers: headers)
            let (weeklyResult, monthlyResult) = await (weekly, monthly)
            try Task.checkCancellation()
            let weeklyBody = try? weeklyResult.get()
            let monthlyBody = try? monthlyResult.get()
            if let quota = GrokQuotaMapper.mapBillingResponses(weekly: weeklyBody, monthly: monthlyBody, plan: metadata.plan) {
                return quota
            }
            // 一个接口拒绝、另一个接口成功时优先保留成功结果；只有都未成功才将账号标记为拒绝。
            if weeklyBody == nil, monthlyBody == nil {
                for result in [weeklyResult, monthlyResult] {
                    if case .failure(let error) = result,
                       let quotaError = error as? QuotaFetchError,
                       case .httpError(let status) = quotaError,
                       status == 401 || status == 403 {
                        return ProviderQuotaData(isForbidden: true)
                    }
                }
            }
            // 无可识别额度时保留实际请求错误；不发送官方客户端可选的付费健康探测消息。
            if case .failure(let error) = weeklyResult { throw error }
            if case .failure(let error) = monthlyResult { throw error }
            throw QuotaFetchError.invalidResponse
        case .codex:
            headers["User-Agent"] = "codex-tui/0.149.1 (Mac OS; arm64)"
            if let account = metadata.accountID { headers["Chatgpt-Account-Id"] = account }
            var profileHeaders = headers
            profileHeaders["Originator"] = "Codex Desktop"
            var inventoryHeaders = profileHeaders
            inventoryHeaders["OpenAI-Beta"] = "codex-1"
            // 三类数据并发读取，附加画像或库存失败只影响对应附加信息，不推翻已经成功的主额度。
            async let body = request(index: index, url: "https://chatgpt.com/backend-api/wham/usage", headers: headers)
            async let profileResult = requestResult(index: index, url: "https://chatgpt.com/backend-api/wham/profiles/me", headers: profileHeaders)
            async let inventoryResult = requestResult(index: index, url: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", headers: inventoryHeaders)
            var quota = try CodexUsageMapper.map(data: await body, identity: CodexQuotaIdentity(planType: metadata.plan))
            if case .success(let profile) = await profileResult,
               let parsed = try? CodexProfileAnalyticsResponse(data: profile),
               let analytics = CodexProfileAnalyticsFetcher.analytics(from: parsed) {
                quota.analytics = quota.analytics?.merging(analytics) ?? analytics
            }
            if case .success(let inventory) = await inventoryResult,
               let analytics = try? CodexResetCreditInventoryFetcher.analytics(data: inventory) {
                quota.analytics = CodexResetCreditInventoryFetcher.merge(analytics, into: quota.analytics)
            }
            try Task.checkCancellation()
            return quota
        case .claude:
            headers["anthropic-beta"] = "oauth-2025-04-20"
            async let body = request(index: index, url: "https://api.anthropic.com/api/oauth/usage", headers: headers)
            async let profileResult = requestResult(index: index, url: "https://api.anthropic.com/api/oauth/profile", headers: headers)
            var quota = try ClaudeQuotaMapper.map(data: await body)
            if case .success(let profile) = await profileResult {
                quota.planType = CPAQuotaProfileMapper.claudePlan(data: profile) ?? quota.planType ?? metadata.plan
            } else {
                quota.planType = quota.planType ?? metadata.plan
            }
            try Task.checkCancellation()
            return quota
        case .antigravity:
            headers["User-Agent"] = AntigravityQuotaEndpoints.userAgent
            // 即使已有项目仍读取有效订阅；没有项目时也可用同一账号的 loadCodeAssist 发现项目。
            async let subscription = loadAntigravitySubscription(index: index, headers: headers)
            let project: String
            if let knownProject = metadata.projectID { project = knownProject }
            else {
                let discoveredProject = await subscription?.cloudaicompanionProject
                try Task.checkCancellation()
                guard let discoveredProject else { throw QuotaFetchError.invalidResponse }
                project = discoveredProject
            }
            let payload = String(decoding: try JSONEncoder().encode(["project": project]), as: UTF8.self)
            var lastError: Error = QuotaFetchError.invalidResponse
            for host in AntigravityQuotaEndpoints.hosts {
                try Task.checkCancellation()
                do {
                    let body = try await request(index: index, url: host + "/v1internal:retrieveUserQuotaSummary",
                                                 headers: headers, payload: payload)
                    guard let models = AntigravityQuotaParser.summaryModels(from: body) else { throw QuotaFetchError.invalidResponse }
                    let subscriptionInfo = await subscription
                    try Task.checkCancellation()
                    return ProviderQuotaData(
                        models: models,
                        planType: subscriptionInfo.flatMap(CPAQuotaProfileMapper.antigravityPlan) ?? metadata.plan,
                        subscriptionInfo: subscriptionInfo
                    )
                } catch is CancellationError { throw CancellationError() }
                catch { lastError = error }
            }
            // 模型目录的 remainingFraction 不是周／会话限额，不能在汇总失败后伪装成满额。
            throw lastError
        default: throw QuotaFetchError.invalidResponse
        }
    }

    /// 使用 Result 保留每个计费接口独立的成功或失败，避免一个接口抛错取消另一个有效查询。
    private func requestResult(index: String, url: String, headers: [String: String]) async -> Result<Data, Error> {
        do { return .success(try await request(index: index, url: url, headers: headers)) }
        catch { return .failure(error) }
    }

    /// 套餐接口仅提供辅助信息，失败时保留可用的主配额；按相同官方主机顺序兼容不同环境。
    private func loadAntigravitySubscription(index: String, headers: [String: String]) async -> SubscriptionInfo? {
        for host in AntigravityQuotaEndpoints.hosts {
            guard !Task.isCancelled else { return nil }
            do {
                let data = try await request(
                    index: index,
                    url: host + "/v1internal:loadCodeAssist",
                    headers: headers,
                    payload: "{\"metadata\":{\"ideType\":\"ANTIGRAVITY\"}}"
                )
                if let subscription = CPAQuotaProfileMapper.antigravitySubscription(data: data) { return subscription }
            } catch is CancellationError { return nil }
            catch { continue }
        }
        return nil
    }

    private func request(index: String, url: String, headers: [String: String], payload: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        let response = try await call(APICallRequest(authIndex: index, method: payload == nil ? "GET" : "POST",
                                                     url: url, header: headers, data: payload))
        guard (200...299).contains(response.statusCode) else { throw QuotaFetchError.httpError(response.statusCode) }
        guard let body = response.body else { throw QuotaFetchError.invalidResponse }
        return Data(body.utf8)
    }
}
