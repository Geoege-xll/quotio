import Foundation

/// 代理运行时始终以 CPA 当前加载的 authIndex 查询同一凭据，避免固定目录、文件名前缀、
/// 本机 CLI 登录状态或同邮箱的另一套餐导致账号串用。$TOKEN$ 由 CPA 替换并刷新。
/// 主查询与精确副查询复用同一个 ManagementAPIClient，副查询只使用指定目录项对应的凭据。
nonisolated struct CPAQuotaFetcher: Sendable {
    let call: @Sendable (APICallRequest) async throws -> APICallResponse
    let download: @Sendable (String) async throws -> Data
    private let list: (@Sendable () async throws -> [AuthFile])?
    private let copilot: CopilotQuotaFetcher?
    private let kiro: KiroQuotaFetcher?
    private let checkSession: @Sendable () async throws -> Void

    init(client: ManagementAPIClient, copilot: CopilotQuotaFetcher? = nil, kiro: KiroQuotaFetcher? = nil,
         isCurrent: @escaping @Sendable () async -> Bool = { true }) {
        // 手动刷新可能仍在等待网络。除了 Task 取消，还要在每个阶段复核原代理会话，
        // 避免旧响应在停机或会话切换之后继续发起带凭据的请求。
        let checkSession: @Sendable () async throws -> Void = {
            try Task.checkCancellation()
            guard await isCurrent() else { throw CancellationError() }
            try Task.checkCancellation()
        }
        self.checkSession = checkSession
        call = {
            try await checkSession()
            return try await client.apiCall($0)
        }
        download = {
            try await checkSession()
            return try await client.downloadAuthFile(name: $0)
        }
        list = {
            try await checkSession()
            return try await client.fetchAuthFiles()
        }
        self.copilot = copilot
        self.kiro = kiro
    }

    init(call: @escaping @Sendable (APICallRequest) async throws -> APICallResponse,
         download: @escaping @Sendable (String) async throws -> Data) {
        self.call = call; self.download = download
        list = nil
        copilot = nil
        kiro = nil
        checkSession = { try Task.checkCancellation() }
    }

    static func supports(_ provider: AIProvider) -> Bool {
        [.antigravity, .codex, .claude, .grok].contains(provider)
    }

    static func supportsSupplemental(_ provider: AIProvider) -> Bool {
        provider == .copilot || provider == .kiro
    }

    /// 只有明确无 CPA 主查询的提供商才可走此入口；主查询的请求错误不参与此判断。
    /// 下载端点只接受文件名，下载后必须从同一个管理会话复核该名称唯一且仍指向原索引。
    func fetchSupplemental(file: AuthFile) async throws -> ProviderQuotaData {
        guard let provider = file.providerType, Self.supportsSupplemental(provider),
              let list, !file.disabled, !file.unavailable, file.runtimeOnly != true,
              let index = QuotaResponseValue.string(file.authIndex),
              file.name.lowercased().hasSuffix(".json"),
              !file.name.contains("/"), !file.name.contains("\\"),
              file.name.rangeOfCharacter(from: .controlCharacters) == nil else { throw QuotaFetchError.invalidResponse }
        let fetch: @Sendable (Data, AuthFile) async throws -> ProviderQuotaData
        switch provider {
        case .copilot:
            guard let copilot, GitHubHost.saved(file.quotaMetadata.githubHost) != nil else {
                throw QuotaFetchError.invalidResponse
            }
            fetch = { try await copilot.fetchCPAQuota(credential: $0, file: $1, checkSession: checkSession) }
        case .kiro:
            guard let kiro else { throw QuotaFetchError.invalidResponse }
            fetch = { try await kiro.fetchCPAQuota(credential: $0, file: $1, checkSession: checkSession) }
        default:
            throw QuotaFetchError.invalidResponse
        }

        try Task.checkCancellation()
        let data = try await download(file.name)
        try await checkSession()
        // 凭据正文通常不回显文件名或索引；若有回显，任何冲突都应在出站之前拒绝。
        let identity = try JSONDecoder().decode(DownloadedIdentity.self, from: data)
        guard (identity.name?.utf8.elementsEqual(file.name.utf8) ?? true),
              (identity.authIndex == nil || identity.authIndex == index),
              (identity.camelCaseAuthIndex == nil || identity.camelCaseAuthIndex == index) else {
            throw QuotaFetchError.invalidResponse
        }
        // CPA 可同时返回同一文件的磁盘与运行描述。仅当原始记录均能归到同一索引、
        // 提供商和已有身份时才复用现有目录合并；不能由合并顺序决定用哪个凭据。
        let records = try await list().filter { $0.name == file.name }
        try await checkSession()
        guard records.allSatisfy({ record in
            let recordIndex = QuotaResponseValue.string(record.authIndex)
            return record.name.utf8.elementsEqual(file.name.utf8) && record.providerType == provider
                && (recordIndex == nil || recordIndex == index)
                && (record.account == nil || record.account == file.account)
                && (record.email == nil || record.email == file.email)
                && (record.quotaUserID == nil || record.quotaUserID == file.quotaUserID)
        }) else { throw QuotaFetchError.invalidResponse }
        let matches = AuthFileIdentity.deduplicated(records)
        guard matches.count == 1, let current = matches.first,
              current.id == file.id, current.providerType == provider,
              QuotaResponseValue.string(current.authIndex) == index,
              !current.disabled, !current.unavailable, current.runtimeOnly != true,
              current.account == file.account, current.email == file.email, current.quotaUserID == file.quotaUserID,
              current.quotaMetadata.githubHost == file.quotaMetadata.githubHost else {
            throw QuotaFetchError.invalidResponse
        }
        return try await fetch(data, current)
    }

    private nonisolated struct DownloadedIdentity: Decodable {
        let name: String?
        let authIndex: String?
        let camelCaseAuthIndex: String?

        enum CodingKeys: String, CodingKey {
            case name, authIndex = "auth_index", camelCaseAuthIndex = "authIndex"
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            name = fields.contains(.name) ? try fields.decode(String.self, forKey: .name) : nil
            authIndex = try Self.index(in: fields, field: .authIndex)
            camelCaseAuthIndex = try Self.index(in: fields, field: .camelCaseAuthIndex)
        }

        private static func index(in fields: KeyedDecodingContainer<CodingKeys>, field: CodingKeys) throws -> String? {
            guard fields.contains(field) else { return nil }
            if let number = try? fields.decode(Int64.self, forKey: field) { return String(number) }
            if let number = try? fields.decode(UInt64.self, forKey: field) { return String(number) }
            return try fields.decode(String.self, forKey: field)
        }
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
        try await checkSession()
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
            try await checkSession()
            let weeklyBody = try? weeklyResult.get()
            let monthlyBody = try? monthlyResult.get()
            if let quota = GrokQuotaMapper.mapBillingResponses(weekly: weeklyBody, monthly: monthlyBody, plan: metadata.plan) {
                return quota
            }
            // 一个接口拒绝、另一个接口成功时优先保留成功结果；都失败时保留真实 HTTP 状态，
            // 让调用方展示鉴权失败并保留上次额度，不把拒绝包装成带新时间戳的空额度。
            if weeklyBody == nil, monthlyBody == nil {
                for result in [weeklyResult, monthlyResult] {
                    if case .failure(let error) = result,
                       let quotaError = error as? QuotaFetchError,
                       case .httpError(let status) = quotaError,
                       status == 401 || status == 403 {
                        throw quotaError
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
            try await checkSession()
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
            try await checkSession()
            return quota
        case .antigravity:
            headers["User-Agent"] = AntigravityQuotaEndpoints.userAgent
            // 即使已有项目仍读取有效订阅；没有项目时也可用同一账号的 loadCodeAssist 发现项目。
            async let subscription = loadAntigravitySubscription(index: index, headers: headers)
            let project: String
            if let knownProject = metadata.projectID { project = knownProject }
            else {
                let discoveredProject = await subscription?.cloudaicompanionProject
                try await checkSession()
                guard let discoveredProject else { throw QuotaFetchError.invalidResponse }
                project = discoveredProject
            }
            // 把本轮精确凭据绑定到原管理客户端，统一 Reader 只负责 Antigravity 协议。
            // 项目、authIndex、令牌占位符始终成组使用；不读取本机另一个账号，不跨环境拼接周期。
            let quotaHeaders = headers
            let reader = AntigravityQuotaReader { url, payload in
                try await request(index: index, url: url, headers: quotaHeaders, payload: payload)
            }
            let models = try await reader.fetch(projectID: project)
            let subscriptionInfo = await subscription
            try await checkSession()
            return ProviderQuotaData(
                models: models,
                planType: subscriptionInfo.flatMap(CPAQuotaProfileMapper.antigravityPlan) ?? metadata.plan,
                subscriptionInfo: subscriptionInfo
            )
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
        try await checkSession()
        guard (200...299).contains(response.statusCode) else { throw QuotaFetchError.httpError(response.statusCode) }
        guard let body = response.body else { throw QuotaFetchError.invalidResponse }
        return Data(body.utf8)
    }
}
