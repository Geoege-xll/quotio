//
//  ClaudeCodeQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Claude auth files in ~/.cli-proxy-api/
//  Calls Anthropic OAuth API for usage data
//

import Foundation

/// API fetch result type
nonisolated enum ClaudeAPIResult: Sendable {
    case success(ClaudeCodeQuotaInfo)
    case authenticationError  // Token expired or invalid - needs re-authentication
    case otherError
}

/// Quota data from Claude Code OAuth API
nonisolated struct ClaudeCodeQuotaInfo: Sendable {
    let accessToken: String?
    let email: String?

    /// Usage quotas from OAuth API
    let fiveHour: QuotaUsage?
    let sevenDay: QuotaUsage?
    let sevenDaySonnet: QuotaUsage?
    let sevenDayOpus: QuotaUsage?
    let extraUsage: ExtraUsage?
    /// 两条获取路径共用完整窗口解析，兼容既有调用者构造的旧四窗口快照。
    var parsedModels: [ModelQuota]? = nil

    struct QuotaUsage: Sendable {
        let utilization: Double  // Percentage used (0-100)
        let resetsAt: String     // ISO8601 date string

        /// Remaining percentage (100 - utilization), clamped to 0-100
        var remaining: Double {
            max(0, min(100, 100 - utilization))
        }
    }

    struct ExtraUsage: Sendable {
        let isEnabled: Bool
        let monthlyLimit: Double?
        let usedCredits: Double?
        let utilization: Double?

        /// Remaining percentage for extra usage, clamped to 0-100
        var remaining: Double? {
            guard let util = utilization else { return nil }
            return max(0, min(100, 100 - util))
        }
    }
}

/// Fetches quota from Claude auth files using OAuth API
actor ClaudeCodeQuotaFetcher {

    /// Auth directory for CLI Proxy API
    private let authDir: String
    private let environment: [String: String]
    private let vault: any MonitorCredentialStore
    private let keychainData: @Sendable () -> Data?
    private let desktopCredential: @Sendable () -> ClaudeDesktopCredential?

    /// Anthropic OAuth usage API endpoint
    private let usageURL = "https://api.anthropic.com/api/oauth/usage"

    /// Anthropic OAuth profile API endpoint
    private let profileURL = "https://api.anthropic.com/api/oauth/profile"

    /// Anthropic OAuth token refresh endpoint
    private let tokenURL = "https://platform.claude.com/v1/oauth/token"
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// URLSession for network requests
    private var session: URLSession

    /// Cache for quota data to reduce API calls
    private var quotaCache: [String: CachedQuota] = [:]

    /// Cache TTL: 5 minutes
    private let cacheTTL: TimeInterval = 300

    /// 注入来源与会话可在临时目录中验证凭据边界，测试不会接触真实钥匙串或发出网络请求。
    init(
        authDir: String = "~/.cli-proxy-api",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        vault: any MonitorCredentialStore = MonitorCredentialVault.shared,
        session: URLSession? = nil,
        keychainData: (@Sendable () -> Data?)? = nil,
        desktopCredential: @escaping @Sendable () -> ClaudeDesktopCredential? = { ClaudeDesktopCredentialReader.load() }
    ) {
        self.authDir = authDir
        self.environment = environment
        self.vault = vault
        // 默认查询当前 Claude 目录对应的唯一服务；自定义目录找不到时不借用另一个默认账号。
        // 原无参数注入闭包仍兼容，所有回归继续可隔离系统钥匙串。
        self.keychainData = keychainData ?? {
            KeychainHelper.readExternalCredentialRecord(service: ClaudeCredentialOwnership.keychainService(environment: environment))?.data
        }
        self.desktopCredential = desktopCredential
        self.session = session ?? URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    private struct CachedQuota {
        let data: ProviderQuotaData
        let timestamp: Date

        func isValid(ttl: TimeInterval) -> Bool {
            Date().timeIntervalSince(timestamp) < ttl
        }
    }

    /// Parse a quota usage object from JSON
    private func parseQuotaUsage(from json: [String: Any]?) -> ClaudeCodeQuotaInfo.QuotaUsage? {
        guard let json = json else { return nil }
        
        // Handle both Int and Double for utilization
        let utilization: Double
        if let doubleVal = json["utilization"] as? Double {
            utilization = doubleVal
        } else if let intVal = json["utilization"] as? Int {
            utilization = Double(intVal)
        } else {
            return nil
        }
        
        // resets_at can be null
        let resetsAt = json["resets_at"] as? String ?? ""
        
        return ClaudeCodeQuotaInfo.QuotaUsage(utilization: utilization, resetsAt: resetsAt)
    }
    
    /// Parse extra usage object from JSON
    private func parseExtraUsage(from json: [String: Any]?) -> ClaudeCodeQuotaInfo.ExtraUsage? {
        guard let json = json else { return nil }
        
        let isEnabled = json["is_enabled"] as? Bool ?? false
        
        // Only parse if enabled
        guard isEnabled else { return nil }
        
        let monthlyLimit = json["monthly_limit"] as? Double
        let usedCredits = json["used_credits"] as? Double
        let utilization = json["utilization"] as? Double
        
        return ClaudeCodeQuotaInfo.ExtraUsage(
            isEnabled: isEnabled,
            monthlyLimit: monthlyLimit,
            usedCredits: usedCredits,
            utilization: utilization
        )
    }

    /// Check if the access token is expired based on the auth file's "expired" field
    /// Refresh an expired access token using the refresh token
    /// - Returns: Tuple of new access token, optional new refresh token, and optional expires_in
    private func refreshAccessToken(refreshToken: String) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int?) {
        guard let url = URL(string: tokenURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let params: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
            "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: params)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            NSLog("[ClaudeQuota] Token refresh failed with HTTP \(statusCode)")
            throw URLError(.userAuthenticationRequired)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String else {
            throw URLError(.cannotParseResponse)
        }

        let newRefreshToken = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? Int

        return (newAccessToken, newRefreshToken, expiresIn)
    }

    private func updatedAuthJSON(
        _ json: [String: Any],
        accessToken: String,
        refreshToken: String?,
        expiresIn: Int?
    ) -> [String: Any] {
        var updatedJSON = json
        let now = Date()
        let formatter = ISO8601DateFormatter()
        if var oauth = updatedJSON["claudeAiOauth"] as? [String: Any] {
            oauth["accessToken"] = accessToken
            if let refreshToken { oauth["refreshToken"] = refreshToken }
            if let expiresIn {
                oauth["expiresAt"] = Int(now.addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970 * 1000)
            }
            updatedJSON["claudeAiOauth"] = oauth
        } else {
            updatedJSON["access_token"] = accessToken
            if let refreshToken { updatedJSON["refresh_token"] = refreshToken }
            updatedJSON["last_refresh"] = formatter.string(from: now)
            if let expiresIn {
                updatedJSON["expired"] = formatter.string(from: now.addingTimeInterval(TimeInterval(expiresIn)))
            }
        }

        return updatedJSON
    }

    /// Fetch usage data from Anthropic OAuth API
    /// - Returns: ClaudeAPIResult indicating success, auth error, or other error
    private func fetchUsageFromAPI(accessToken: String, email: String?) async -> ClaudeAPIResult {
        guard let url = URL(string: usageURL) else {
            return .otherError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.addValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.data(for: request)

            // Check HTTP status code
            if let httpResponse = response as? HTTPURLResponse {
                // 401 Unauthorized indicates authentication error
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    return .authenticationError
                }
                // Other non-2xx status codes
                if !(200...299 ~= httpResponse.statusCode) {
                    NSLog("[ClaudeQuota] HTTP error: \(httpResponse.statusCode)")
                    return .otherError
                }
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[ClaudeQuota] Failed to parse JSON response")
                return .otherError
            }

            // Check for API error response
            if json["type"] as? String == "error" {
                // Check if it's an authentication error
                if let errorObj = json["error"] as? [String: Any],
                   let errorType = errorObj["type"] as? String,
                   errorType == "authentication_error" {
                    // Token expired or invalid
                    NSLog("[ClaudeQuota] Authentication error for \(email ?? "unknown")")
                    return .authenticationError
                }
                NSLog("[ClaudeQuota] API error: \(json)")
                return .otherError
            }

            // API returns data directly (no wrapper)
            let fiveHour = parseQuotaUsage(from: json["five_hour"] as? [String: Any])
            let sevenDay = parseQuotaUsage(from: json["seven_day"] as? [String: Any])
            let sevenDaySonnet = parseQuotaUsage(from: json["seven_day_sonnet"] as? [String: Any])
            let sevenDayOpus = parseQuotaUsage(from: json["seven_day_opus"] as? [String: Any])
            let extraUsage = parseExtraUsage(from: json["extra_usage"] as? [String: Any])

            let mapped = try ClaudeQuotaMapper.map(data: data)
            return .success(ClaudeCodeQuotaInfo(
                accessToken: accessToken,
                email: email,
                fiveHour: fiveHour,
                sevenDay: sevenDay,
                sevenDaySonnet: sevenDaySonnet,
                sevenDayOpus: sevenDayOpus,
                extraUsage: extraUsage,
                parsedModels: mapped.models
            ))
        } catch {
            NSLog("[ClaudeQuota] Network error: \(error.localizedDescription)")
            return .otherError
        }
    }

    /// Claude OAuth 画像解析结果
    private struct ClaudeProfileResult: Sendable {
        let email: String?
        let plan: String?
        let accountUuid: String?
        let organizationUuid: String?
    }

    /// 请求 Anthropic OAuth 画像接口获取套餐信息与账号身份，支持 rate_limit_tier 倍率提取
    private func fetchProfileFromAPI(
        accessToken: String,
        storedPlan: String? = nil,
        storedTier: String? = nil
    ) async -> ClaudeProfileResult? {
        guard let url = URL(string: profileURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.addValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 5

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  200...299 ~= httpResponse.statusCode else {
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let account = json["account"] as? [String: Any]
            let organization = json["organization"] as? [String: Any]
            let accountUuid = account?["uuid"] as? String
            let orgUuid = organization?["uuid"] as? String

            var email = (account?["email"] as? String) ?? (account?["email_address"] as? String)
            email = email?.trimmingCharacters(in: .whitespacesAndNewlines)
            if email?.isEmpty == true { email = nil }

            // 如果 profile 响应中未包含 email，尝试从 ~/.claude.json 读取并按 accountUuid / organizationUuid 校验
            if email == nil, let accountUuid {
                email = resolveEmailFromClaudeConfig(accountUuid: accountUuid, organizationUuid: orgUuid)
            }

            // 计算 plan：结合 live profile 与 stored credential，避免将存量 tier 错误附加上 live 不同的 plan
            let livePlan = CPAQuotaProfileMapper.claudePlan(data: data)
            let resolvedPlan: String?
            if let livePlan {
                resolvedPlan = livePlan
            } else if let storedPlan {
                let liveTier = organization?["rate_limit_tier"] as? String
                let tier = liveTier ?? storedTier
                resolvedPlan = CPAQuotaProfileMapper.formatClaudePlan(plan: storedPlan, tier: tier)
            } else {
                resolvedPlan = nil
            }

            return ClaudeProfileResult(
                email: email,
                plan: resolvedPlan,
                accountUuid: accountUuid,
                organizationUuid: orgUuid
            )
        } catch {
            return nil
        }
    }

    /// 从 ~/.claude.json 中匹配 accountUuid 和 organizationUuid 读取补充 email，避免在失败时覆盖已有账号名称
    private func resolveEmailFromClaudeConfig(accountUuid: String, organizationUuid: String?) -> String? {
        let base = ClaudeCredentialOwnership.configDirectory(environment: environment)
        let candidates = [
            NSString(string: "~/.claude.json").expandingTildeInPath,
            (base as NSString).appendingPathComponent(".claude.json")
        ]
        for path in candidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauthAccount = json["oauthAccount"] as? [String: Any],
                  let localAccountUuid = oauthAccount["accountUuid"] as? String,
                  localAccountUuid.caseInsensitiveCompare(accountUuid) == .orderedSame else {
                continue
            }
            let localOrgUuid = oauthAccount["organizationUuid"] as? String
            let orgMatches: Bool
            switch (localOrgUuid, organizationUuid) {
            case (.some(let local), .some(let live)):
                orgMatches = local.caseInsensitiveCompare(live) == .orderedSame
            case (.none, .none):
                orgMatches = true
            default:
                orgMatches = false
            }
            guard orgMatches else { continue }
            if let email = oauthAccount["emailAddress"] as? String {
                let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// 聚合全部来源后再统一判定归属与去重；定向刷新也必须先看到外部令牌，才能识别复制品。
    private func credentials(includeMonitorCredentials: Bool) async -> [ClaudeQuotaCredential] {
        var values: [ClaudeQuotaCredential] = []
        let nativeBase = ClaudeCredentialOwnership.configDirectory(environment: environment)
        let nativePath = (nativeBase as NSString).appendingPathComponent(".credentials.json")
        if let native = ClaudeQuotaCredential.load(path: nativePath, environment: environment) {
            values.append(native)
        }
        if let data = keychainData(), let native = ClaudeQuotaCredential.load(data: data, allowsRefresh: false) {
            values.append(native)
        }
        if let desktop = desktopCredential() {
            values.append(ClaudeQuotaCredential(accountKey: "Claude Desktop", accessToken: desktop.accessToken,
                                                refreshToken: nil, expiresAt: desktop.expiresAt, allowsRefresh: false))
        }
        let directory = NSString(string: authDir).expandingTildeInPath
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names.sorted() where name.hasPrefix("claude-") && name.hasSuffix(".json") {
            let path = (directory as NSString).appendingPathComponent(name)
            if let credential = ClaudeQuotaCredential.load(path: path, environment: environment) {
                values.append(credential)
            }
        }
        if includeMonitorCredentials {
            for account in await vault.accounts() where account.provider == .claude && !account.isDisabled {
                guard let stored = await vault.credential(for: account.id) else { continue }
                values.append(ClaudeQuotaCredential(accountKey: account.accountKey, accessToken: stored.accessToken,
                                                    refreshToken: stored.refreshToken, expiresAt: stored.expiresAt,
                                                    allowsRefresh: true, source: .vault(account)))
            }
        }
        return ClaudeQuotaCredential.uniqueByAccountKey(values)
    }

    func fetchAsProviderQuota(
        forceRefresh: Bool = false,
        includeMonitorCredentials: Bool = false
    ) async -> [String: ProviderQuotaData] {
        var results: [String: ProviderQuotaData] = [:]
        for credential in await credentials(includeMonitorCredentials: includeMonitorCredentials) {
            guard !Task.isCancelled else { break }
            if let quota = await fetchQuota(credential, forceRefresh: forceRefresh,
                                            includeMonitorCredentials: includeMonitorCredentials) {
                results[credential.accountKey] = quota
            }
        }
        return results
    }

    func fetchQuota(accountKey: String, forceRefresh: Bool = false) async -> ProviderQuotaData? {
        guard let credential = await credentials(includeMonitorCredentials: true).first(where: {
            $0.accountKey == accountKey
        }) else { return nil }
        return await fetchQuota(credential, forceRefresh: forceRefresh, includeMonitorCredentials: true)
    }

    /// 原生凭据只允许读取 usage；无论预先过期还是返回 401/403，都不能消耗 CLI 的刷新令牌。
    /// 自有凭据刷新前重新读取来源和归属，防止挂起期间来源被替换或变成外部令牌副本。
    private func fetchQuota(
        _ original: ClaudeQuotaCredential,
        forceRefresh: Bool,
        includeMonitorCredentials: Bool
    ) async -> ProviderQuotaData? {
        let key = original.accountKey
        if !forceRefresh, let cached = quotaCache[key], cached.isValid(ttl: cacheTTL) { return cached.data }
        var credential = original
        var accessToken = credential.accessToken
        if credential.allowsRefresh, credential.expiresAt.map({ $0.timeIntervalSinceNow < 60 }) == true,
           let refreshed = await refreshCredential(credential, includeMonitorCredentials: includeMonitorCredentials) {
            credential = refreshed
            accessToken = refreshed.accessToken
        }
        var response = await fetchUsageFromAPI(accessToken: accessToken, email: key)
        if credential.allowsRefresh, case .authenticationError = response,
           let refreshed = await refreshCredential(credential, includeMonitorCredentials: includeMonitorCredentials) {
            accessToken = refreshed.accessToken
            response = await fetchUsageFromAPI(accessToken: refreshed.accessToken, email: key)
        }
        guard !Task.isCancelled else { return nil }
        if case .success(let info) = response, var quota = quotaData(from: info) {
            // Profile 画像增强：仅在 usage API 成功后发起，维护 401 认证时序并提取套餐与倍率
            let token = accessToken
            if let profile = await fetchProfileFromAPI(
                accessToken: token,
                storedPlan: credential.subscriptionType,
                storedTier: credential.rateLimitTier
            ) {
                if let plan = profile.plan {
                    quota.planType = plan
                }
                if let email = profile.email, !email.isEmpty {
                    quota.accountDisplayName = email
                }
            }
            if quota.planType == nil, let storedPlan = credential.subscriptionType {
                quota.planType = CPAQuotaProfileMapper.formatClaudePlan(plan: storedPlan, tier: credential.rateLimitTier)
            }
            if quota.accountDisplayName == nil && credential.accountKey != "Claude Code" {
                quota.accountDisplayName = credential.accountKey
            }
            quotaCache[key] = CachedQuota(data: quota, timestamp: Date())
            return quota
        }
        // 外部凭据没有由 Quotio 重新登录的入口，认证失败保留缓存，等待原生客户端自行续期。
        if case .authenticationError = response, credential.allowsRefresh {
            // usage 请求期间，文件可能消失或被替换为原生令牌副本。错误展示也必须遵守最新归属，
            // 不能沿用请求前的可刷新标记，把只读凭据错误地显示为需要在 Quotio 重新登录。
            let latest = await credentials(includeMonitorCredentials: includeMonitorCredentials).first {
                $0.accountKey == credential.accountKey && $0.source == credential.source
            }
            guard !Task.isCancelled else { return nil }
            if latest?.allowsRefresh == true {
                return ProviderQuotaData(models: [], lastUpdated: Date(), isForbidden: true)
            }
        }
        return quotaCache[key]?.data
    }

    private func refreshCredential(
        _ original: ClaudeQuotaCredential,
        includeMonitorCredentials: Bool
    ) async -> ClaudeQuotaCredential? {
        guard !Task.isCancelled,
              let current = await credentials(includeMonitorCredentials: includeMonitorCredentials).first(where: {
                  $0.accountKey == original.accountKey && $0.source == original.source
              }), current.allowsRefresh, let expected = current.refreshToken else { return nil }
        do {
            let refresh = try await refreshAccessToken(refreshToken: expected)
            // 刷新结果仅写回匹配的原来源；保留自有 JSON 字段及保险库的并发写入保护。
            switch current.source {
            case .external:
                return nil
            case .file(let path):
                guard let file = SecureClaudeCredentialFile(path: path),
                      ClaudeCredentialOwnership.allowsRefresh(file: file, environment: environment),
                      let data = file.read(),
                      let latest = ClaudeQuotaCredential.load(data: data, allowsRefresh: true),
                      latest.accountKey == current.accountKey, latest.refreshToken == expected,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                let updated = updatedAuthJSON(json, accessToken: refresh.accessToken,
                                              refreshToken: refresh.refreshToken ?? expected, expiresIn: refresh.expiresIn)
                let encoded = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
                guard file.replaceAtomically(with: encoded) else { return nil }
            case .vault(let account):
                guard var stored = await vault.reloadLatest(accountID: account.id), stored.refreshToken == expected else { return nil }
                let originalCredential = stored
                stored.accessToken = refresh.accessToken
                stored.refreshToken = refresh.refreshToken ?? expected
                stored.expiresAt = refresh.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) } ?? stored.expiresAt
                try await vault.saveRefreshed(stored, replacing: originalCredential, accountID: account.id)
            }
            return ClaudeQuotaCredential(accountKey: current.accountKey, accessToken: refresh.accessToken,
                                         refreshToken: refresh.refreshToken ?? expected,
                                         expiresAt: refresh.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) } ?? current.expiresAt,
                                         allowsRefresh: true, source: current.source)
        } catch {
            return nil
        }
    }

    private func quotaData(from info: ClaudeCodeQuotaInfo) -> ProviderQuotaData? {
        if let models = info.parsedModels {
            return ProviderQuotaData(models: models, lastUpdated: Date())
        }
        var models: [ModelQuota] = []
        if let value = info.fiveHour {
            models.append(ModelQuota(name: "five-hour-session", percentage: value.remaining, resetTime: value.resetsAt))
        }
        if let value = info.sevenDay {
            models.append(ModelQuota(name: "seven-day-weekly", percentage: value.remaining, resetTime: value.resetsAt))
        }
        if let value = info.sevenDaySonnet {
            models.append(ModelQuota(name: "seven-day-sonnet", percentage: value.remaining, resetTime: value.resetsAt))
        }
        if let value = info.sevenDayOpus {
            models.append(ModelQuota(name: "seven-day-opus", percentage: value.remaining, resetTime: value.resetsAt))
        }
        if let extra = info.extraUsage, let remaining = extra.remaining {
            var model = ModelQuota(name: "extra-usage", percentage: remaining, resetTime: "")
            if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                model.used = Int(used)
                model.limit = Int(limit)
            }
            models.append(model)
        }
        guard !models.isEmpty else { return nil }
        return ProviderQuotaData(models: models, lastUpdated: Date(), isForbidden: false, planType: nil)
    }
    
    /// Clear the quota cache
    func clearCache() {
        quotaCache.removeAll()
    }
    
    /// Clear cache for a specific email
    func clearCache(for email: String) {
        quotaCache.removeValue(forKey: email)
    }

}
