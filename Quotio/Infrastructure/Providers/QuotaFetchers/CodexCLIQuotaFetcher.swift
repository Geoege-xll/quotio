//
//  CodexCLIQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Codex CLI by reading ~/.codex/auth.json and calling ChatGPT usage API
//  Used in Quota-Only mode for direct quota tracking without proxy
//

import Foundation

/// Auth file structure for Codex CLI (~/.codex/auth.json)
nonisolated struct CodexCLIAuthFile: Codable, Sendable {
    var OPENAI_API_KEY: String?
    var tokens: CodexCLITokens?
    var lastRefresh: String?
    
    enum CodingKeys: String, CodingKey {
        case OPENAI_API_KEY
        case tokens
        case lastRefresh = "last_refresh"
    }
}

nonisolated struct CodexCLITokens: Codable, Sendable {
    var idToken: String?
    var accessToken: String?
    var refreshToken: String?
    var accountId: String?
    
    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountId = "account_id"
    }
}

/// Decoded JWT claims from Codex id_token
nonisolated struct CodexJWTClaims: Sendable {
    let email: String?
    let emailVerified: Bool
    let planType: String?
    let accountId: String?
    let userId: String?
    let organizationName: String?
    let subscriptionActiveUntil: Date?
}

nonisolated struct CodexQuotaAccountIdentity: Sendable {
    let key: String
    let email: String?
    let accountID: String?
}

/// Fetches quota from Codex CLI auth file
actor CodexCLIQuotaFetcher {
    private let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    private let refreshURL = "https://auth.openai.com/oauth/token"
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    
    private var session: URLSession
    private let configuredAuthPaths: [String]?
    private let legacyDirectory: String
    private let vault: any MonitorCredentialStore
    private let metadata: MonitorMetadataStore
    private let keychainReader: @Sendable (String?) -> (data: Data, account: String)?
    
    /// 隔离测试可注入凭据路径、保险库与 HTTP 会话，生产环境继续采用原有来源。
    init(
        authPaths: [String]? = nil,
        legacyDirectory: String = "~/.cli-proxy-api",
        vault: any MonitorCredentialStore = MonitorCredentialVault.shared,
        metadata: MonitorMetadataStore = .shared,
        session: URLSession? = nil,
        keychainReader: @escaping @Sendable (String?) -> (data: Data, account: String)? = {
            KeychainHelper.readExternalCredentialRecord(service: "Codex Auth", account: $0)
        }
    ) {
        configuredAuthPaths = authPaths
        self.legacyDirectory = NSString(string: legacyDirectory).expandingTildeInPath
        self.vault = vault
        self.metadata = metadata
        self.keychainReader = keychainReader
        self.session = session ?? URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

#if DEBUG
    private func debugMask(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "<nil>" }
        if value.count <= 8 { return "\(value) (len=\(value.count))" }
        let prefix = value.prefix(4)
        let suffix = value.suffix(4)
        return "\(prefix)…\(suffix) (len=\(value.count))"
    }
#endif

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }
    
    private var authFilePaths: [String] {
        if let configuredAuthPaths { return configuredAuthPaths }
        var paths: [String] = []
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            paths.append((home as NSString).appendingPathComponent("auth.json"))
        }
        paths.append(NSString(string: "~/.config/codex/auth.json").expandingTildeInPath)
        paths.append(NSString(string: "~/.codex/auth.json").expandingTildeInPath)
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Check if any supported Codex auth source exists.
    func isAuthFilePresent() -> Bool {
        authFilePaths.contains { FileManager.default.fileExists(atPath: $0) }
    }
    
    /// Read auth file from ~/.codex/auth.json
    func readAuthFile() -> CodexCLIAuthFile? {
        for path in authFilePaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: data),
                  auth.tokens?.accessToken?.isEmpty == false else { continue }
            return auth
        }
        return nil
    }

    private func readAuthSources() -> [(path: String, auth: CodexCLIAuthFile)] {
        authFilePaths.compactMap { path in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: data),
                  auth.tokens?.accessToken?.isEmpty == false else { return nil }
            return (path, auth)
        }
    }
    
    /// Decode JWT to extract email and plan info
    func decodeJWT(token: String) -> CodexJWTClaims? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        
        var base64 = String(segments[1])
        // Add padding if needed
        let padLength = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padLength)
        
        // Replace URL-safe characters
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        
        guard let data = Data(base64Encoded: base64) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        
        // Extract email
        let email = json["email"] as? String
        let emailVerified = json["email_verified"] as? Bool ?? false
        
        // Extract plan info from nested auth object
        var planType: String? = nil
        var accountId: String? = nil
        var userId: String? = nil
        var orgName: String? = nil
        var subscriptionUntil: Date? = nil
        
        if let authInfo = json["https://api.openai.com/auth"] as? [String: Any] {
            planType = authInfo["chatgpt_plan_type"] as? String
            accountId = authInfo["chatgpt_account_id"] as? String
            userId = authInfo["chatgpt_user_id"] as? String
            
            // Parse organizations
            if let orgs = authInfo["organizations"] as? [[String: Any]], let firstOrg = orgs.first {
                orgName = firstOrg["title"] as? String
            }
            
            // Parse subscription end date
            if let untilStr = authInfo["chatgpt_subscription_active_until"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                subscriptionUntil = formatter.date(from: untilStr)
            }
        }
        
        return CodexJWTClaims(
            email: email,
            emailVerified: emailVerified,
            planType: planType,
            accountId: accountId,
            userId: userId,
            organizationName: orgName,
            subscriptionActiveUntil: subscriptionUntil
        )
    }
    
    /// Fetch quota from ChatGPT usage API
    func fetchQuota(accessToken: String, accountId: String?, identity: CodexQuotaIdentity, monitorIdentity: String? = nil) async throws -> ProviderQuotaData {
        guard await monitorIdentityIsEnabled(monitorIdentity) else { throw CodexCLIQuotaError.noAccessToken }
        guard let url = URL(string: usageURL) else {
            throw CodexCLIQuotaError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId, !accountId.isEmpty {
            request.addValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
#if DEBUG
        Log.quota("GET \(usageURL) accountId=\(debugMask(accountId))")
#endif
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexCLIQuotaError.invalidResponse
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            throw CodexCLIQuotaError.httpError(httpResponse.statusCode)
        }
        
        var quotaData = try CodexUsageMapper.map(data: data, identity: identity)
#if DEBUG
        Log.quota("plan_type=\(quotaData.planType ?? "<nil>")")
#endif
        if await monitorIdentityIsEnabled(monitorIdentity), let resetCreditAnalytics = await fetchResetCreditAnalytics(accessToken: accessToken, accountId: accountId) {
            quotaData.analytics = CodexResetCreditInventoryFetcher.merge(
                resetCreditAnalytics,
                into: quotaData.analytics
            )
        }
        if await monitorIdentityIsEnabled(monitorIdentity), let profileAnalytics = await fetchProfileAnalytics(accessToken: accessToken, accountId: accountId) {
            quotaData.analytics = quotaData.analytics?.merging(profileAnalytics) ?? profileAnalytics
        }
        return quotaData
    }

    private func fetchResetCreditAnalytics(accessToken: String, accountId: String?) async -> QuotaAnalytics? {
        do {
            return try await CodexResetCreditInventoryFetcher(urlSession: session).fetchAnalytics(
                accessToken: accessToken,
                accountID: accountId
            )
        } catch {
            Log.quota("Failed to fetch Codex reset credit inventory: \(error)")
            return nil
        }
    }

    private func fetchProfileAnalytics(accessToken: String, accountId: String?) async -> QuotaAnalytics? {
        do {
            return try await CodexProfileAnalyticsFetcher(urlSession: session).fetch(
                accessToken: accessToken,
                accountID: accountId
            )
        } catch {
            Log.quota("Failed to fetch Codex profile analytics: \(error)")
            return nil
        }
    }
    
    /// Refresh access token using refresh token
    nonisolated struct TokenRefresh: Sendable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let expiresIn: Int?
    }

    func refreshAccessToken(refreshToken: String, monitorIdentity: String? = nil) async throws -> TokenRefresh {
        guard await monitorIdentityIsEnabled(monitorIdentity) else { throw CodexCLIQuotaError.noAccessToken }
        var request = URLRequest(url: URL(string: refreshURL)!)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=refresh_token",
            "client_id=\(clientID.urlFormEncoded)",
            "refresh_token=\(refreshToken.urlFormEncoded)",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw CodexCLIQuotaError.tokenRefreshFailed
        }
        
        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let id_token: String?
            let expires_in: Int?
        }
        
        let tokenResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)
        return TokenRefresh(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            idToken: tokenResponse.id_token,
            expiresIn: tokenResponse.expires_in
        )
    }
    
    /// Check if access token is expired by decoding JWT
    func isTokenExpired(accessToken: String) -> Bool {
        let segments = accessToken.split(separator: ".")
        guard segments.count >= 2 else { return true }
        
        var base64 = String(segments[1])
        let padLength = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padLength)
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return true
        }
        
        // Refresh five minutes early so scheduled quota checks do not race token expiry.
        return Date(timeIntervalSince1970: exp) < Date().addingTimeInterval(300)
    }
    
    /// Fetch quota and convert to ProviderQuotaData for unified display
    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
        var results = await fetchOwnedQuotas()
        for (key, quota) in await fetchNativeKeychainQuotas() where results[key] == nil {
            results[key] = quota
        }
        for source in readAuthSources() {
            guard let tokens = source.auth.tokens, let originalAccessToken = tokens.accessToken else { continue }
            var email: String?
            var planType: String?
            var accountId = tokens.accountId
            if let idToken = tokens.idToken, let claims = decodeJWT(token: idToken) {
                email = claims.email
                planType = claims.planType
                accountId = accountId ?? claims.accountId
            }

            // 上游账号别名对齐：缺少 id_token 时仍以 account_id 对齐发现与定向刷新入口。
            let accountKey = canonicalLocalKey(email: email, accountID: accountId, fallback: "Codex")
            var accessToken = originalAccessToken
            var refreshToken = tokens.refreshToken
            if isTokenExpired(accessToken: accessToken), let currentRefresh = refreshToken {
                do {
                    let refreshed = try await refreshAccessToken(refreshToken: currentRefresh)
                    accessToken = refreshed.accessToken
                    refreshToken = refreshed.refreshToken ?? currentRefresh
                    try persistRefresh(refreshed, originalRefreshToken: currentRefresh, path: source.path)
                } catch {
                    Log.quota("Failed to refresh Codex token")
                }
            }

            do {
                let quota: ProviderQuotaData
                do {
                    quota = try await fetchQuota(
                        accessToken: accessToken,
                        accountId: accountId,
                        identity: CodexQuotaIdentity(planType: planType)
                    )
                } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
                    let latestTokens = readAuthFile(at: source.path)?.tokens
                    let currentRefresh = latestTokens?.refreshToken ?? refreshToken
                    guard let currentRefresh else { throw CodexCLIQuotaError.tokenRefreshFailed }
                    let latestClaims = latestTokens?.idToken.flatMap(decodeJWT)
                    let refreshed = try await refreshAccessToken(refreshToken: currentRefresh)
                    try persistRefresh(refreshed, originalRefreshToken: currentRefresh, path: source.path)
                    quota = try await fetchQuota(
                        accessToken: refreshed.accessToken,
                        accountId: latestTokens?.accountId ?? latestClaims?.accountId ?? accountId,
                        identity: CodexQuotaIdentity(planType: latestClaims?.planType ?? planType)
                    )
                }
#if DEBUG
                Log.quota("finalPlan=\(quota.planType ?? "<nil>") jwt=\(planType ?? "<nil>")")
#endif
                if results[accountKey] == nil { results[accountKey] = quota }
            } catch {
                Log.quota("Failed to fetch Codex quota for local credential: \(error.localizedDescription)")
            }
        }
        for (key, quota) in await fetchLegacyQuotas() where results[key] == nil {
            results[key] = quota
        }
        return await promoteFreshLegacyAliases(in: results)
    }

    /// Fetches only the credential represented by the canonical account key.
    func fetchQuota(forAccountKey accountKey: String) async -> ProviderQuotaData? {
        if let account = await vault.accounts().first(where: {
            $0.provider == .codex && !$0.isDisabled && $0.accountKey == accountKey
        }), let quota = await fetchOwnedQuota(account) {
            return quota
        }

        if let record = keychainReader(nil),
           let auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: record.data),
           let tokens = auth.tokens {
            let claims = tokens.idToken.flatMap(decodeJWT)
            let key = canonicalLocalKey(
                email: claims?.email,
                accountID: tokens.accountId ?? claims?.accountId,
                fallback: "Codex"
            )
            if key == accountKey, let quota = await fetchNativeKeychainQuotas().values.first {
                return quota
            }
        }

        for source in readAuthSources() {
            guard let tokens = source.auth.tokens else { continue }
            let claims = tokens.idToken.flatMap(decodeJWT)
            let key = canonicalLocalKey(
                email: claims?.email,
                accountID: tokens.accountId ?? claims?.accountId,
                fallback: "Codex"
            )
            guard key == accountKey else { continue }
            return await fetchLocalAuthQuota(source: source, claims: claims)
        }

        let directory = legacyDirectory
        guard let filename = try? FileManager.default.contentsOfDirectory(atPath: directory).first(where: {
            $0.hasPrefix("codex-") && $0.hasSuffix(".json") && $0.codexFilenameKey == accountKey
        }) else { return nil }
        let path = (directory as NSString).appendingPathComponent(filename)
        return await fetchLegacyQuota(at: path)
    }

    private func canonicalLocalKey(email: String?, accountID: String?, fallback: String) -> String {
        guard let accountID, !accountID.isEmpty else { return email ?? fallback }
        let aliases = readLegacyIdentities().filter { $0.accountID == accountID }.map(\.key)
        return Set(aliases).count == 1 ? aliases[0] : (email ?? accountID)
    }

    private func fetchLocalAuthQuota(
        source: (path: String, auth: CodexCLIAuthFile),
        claims: CodexJWTClaims?,
        monitorIdentity: String? = nil
    ) async -> ProviderQuotaData? {
        guard let tokens = source.auth.tokens, var accessToken = tokens.accessToken else { return nil }
        guard matchesMonitorIdentity(monitorIdentity, accountID: tokens.accountId ?? claims?.accountId,
                                     key: claims?.email ?? tokens.accountId ?? "Codex") else { return nil }
        var refreshToken = tokens.refreshToken
        if isTokenExpired(accessToken: accessToken), let currentRefreshToken = refreshToken {
            guard let refreshed = try? await refreshAccessToken(refreshToken: currentRefreshToken, monitorIdentity: monitorIdentity) else { return nil }
            accessToken = refreshed.accessToken
            try? self.persistRefresh(refreshed, originalRefreshToken: currentRefreshToken, path: source.path)
            refreshToken = refreshed.refreshToken ?? currentRefreshToken
        }
        do {
            return try await fetchQuota(
                accessToken: accessToken,
                accountId: tokens.accountId ?? claims?.accountId,
                identity: CodexQuotaIdentity(planType: claims?.planType), monitorIdentity: monitorIdentity
            )
        } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
            guard let latest = readAuthFile(at: source.path)?.tokens,
                  matchesMonitorIdentity(monitorIdentity, accountID: latest.accountId ?? latest.idToken.flatMap(decodeJWT)?.accountId,
                                         key: latest.idToken.flatMap(decodeJWT)?.email ?? latest.accountId ?? "Codex"),
                  let refresh = latest.refreshToken ?? refreshToken,
                  let refreshed = try? await refreshAccessToken(refreshToken: refresh, monitorIdentity: monitorIdentity) else { return nil }
            try? persistRefresh(refreshed, originalRefreshToken: refresh, path: source.path)
            let latestClaims = latest.idToken.flatMap(decodeJWT)
            return try? await fetchQuota(
                accessToken: refreshed.accessToken,
                accountId: latest.accountId ?? latestClaims?.accountId ?? claims?.accountId,
                identity: CodexQuotaIdentity(planType: latestClaims?.planType ?? claims?.planType), monitorIdentity: monitorIdentity
            )
        } catch {
            return nil
        }
    }

    func reconcileLegacyAliases(
        in quotas: [String: ProviderQuotaData]
    ) async -> [String: ProviderQuotaData] {
        Self.reconcileLegacyAliases(
            in: quotas,
            legacy: readLegacyIdentities(),
            current: await currentAccountIdentities()
        )
    }

    func promoteFreshLegacyAliases(
        in quotas: [String: ProviderQuotaData]
    ) async -> [String: ProviderQuotaData] {
        Self.promoteFreshLegacyAliases(
            in: quotas,
            legacy: readLegacyIdentities(),
            current: await currentAccountIdentities()
        )
    }

    nonisolated static func promoteFreshLegacyAliases(
        in quotas: [String: ProviderQuotaData],
        legacy: [CodexQuotaAccountIdentity],
        current: [CodexQuotaAccountIdentity]
    ) -> [String: ProviderQuotaData] {
        var promoted = quotas
        let uniqueLegacyByAccountID = Dictionary(grouping: legacy.compactMap { identity -> (String, CodexQuotaAccountIdentity)? in
            guard let accountID = identity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !accountID.isEmpty else { return nil }
            return (accountID, identity)
        }, by: \.0).compactMapValues { entries -> CodexQuotaAccountIdentity? in
            let identities = entries.map(\.1)
            guard Set(identities.map(\.key)).count == 1 else { return nil }
            return identities.first
        }
        let currentByKey = Dictionary(grouping: current, by: \.key)

        for (key, quota) in quotas {
            let identities = currentByKey[key, default: []]
            let accountIDs = identities.compactMap { identity -> String? in
                guard let accountID = identity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !accountID.isEmpty else { return nil }
                return accountID
            }
            let distinctAccountIDs = Set(accountIDs)
            guard accountIDs.count == identities.count,
                  distinctAccountIDs.count == 1,
                  let accountID = distinctAccountIDs.first,
                  let legacyIdentity = uniqueLegacyByAccountID[accountID],
                  legacyIdentity.key != key else { continue }
            if promoted[legacyIdentity.key].map({ $0.lastUpdated <= quota.lastUpdated }) ?? true {
                promoted[legacyIdentity.key] = quota
            }
            promoted.removeValue(forKey: key)
        }
        return promoted
    }

    private func currentAccountIdentities() async -> [CodexQuotaAccountIdentity] {
        var current = readAuthSources().map { source in
            let claims = source.auth.tokens?.idToken.flatMap(decodeJWT)
            return CodexQuotaAccountIdentity(
                key: claims?.email ?? source.auth.tokens?.accountId ?? "Codex User",
                email: claims?.email,
                accountID: source.auth.tokens?.accountId ?? claims?.accountId
            )
        }

        if let record = keychainReader(nil),
           let auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: record.data),
           let tokens = auth.tokens {
            let claims = tokens.idToken.flatMap(decodeJWT)
            current.append(CodexQuotaAccountIdentity(
                key: claims?.email ?? tokens.accountId ?? "Codex",
                email: claims?.email,
                accountID: tokens.accountId ?? claims?.accountId
            ))
        }

        for account in await vault.accounts().filter({ $0.provider == .codex }) {
            guard let credential = await vault.credential(for: account.id) else { continue }
            let claims = credential.idToken.flatMap(decodeJWT)
            current.append(CodexQuotaAccountIdentity(
                key: account.accountKey,
                email: claims?.email,
                accountID: credential.accountID ?? claims?.accountId
            ))
        }
        return current
    }

    nonisolated static func reconcileLegacyAliases(
        in quotas: [String: ProviderQuotaData],
        legacy: [CodexQuotaAccountIdentity],
        current: [CodexQuotaAccountIdentity]
    ) -> [String: ProviderQuotaData] {
        var reconciled = quotas
        let legacyByEmail = Dictionary(grouping: legacy.compactMap { identity -> (String, CodexQuotaAccountIdentity)? in
            guard let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !email.isEmpty else { return nil }
            return (email, identity)
        }, by: \.0)

        for (email, entries) in legacyByEmail {
            let legacyAccounts = entries.map(\.1)
            guard legacyAccounts.contains(where: { reconciled[$0.key] != nil }) else { continue }

            let legacyAccountIDs = Set(legacyAccounts.compactMap { identity -> String? in
                guard let accountID = identity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !accountID.isEmpty else { return nil }
                return accountID
            })
            let matchingCurrent = current.filter {
                $0.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email
            }
            for currentIdentity in matchingCurrent {
                guard let freshQuota = reconciled[currentIdentity.key],
                      let currentAccountID = currentIdentity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !currentAccountID.isEmpty,
                      matchingCurrent.filter({ $0.key == currentIdentity.key }).allSatisfy({
                    $0.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) == currentAccountID
                }) else { continue }
                for legacyAccount in legacyAccounts where
                    legacyAccount.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) == currentAccountID {
                    guard reconciled[legacyAccount.key].map({ $0.lastUpdated <= freshQuota.lastUpdated }) ?? true else {
                        continue
                    }
                    reconciled[legacyAccount.key] = freshQuota
                }
            }
            let hasDistinctCurrentAccount = matchingCurrent.contains { identity in
                guard let accountID = identity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !accountID.isEmpty, !legacyAccountIDs.isEmpty else { return true }
                return !legacyAccountIDs.contains(accountID)
            }
            guard !hasDistinctCurrentAccount else { continue }

            for key in reconciled.keys where key.lowercased() == email {
                reconciled.removeValue(forKey: key)
            }
        }
        return reconciled
    }

    private func readLegacyIdentities() -> [CodexQuotaAccountIdentity] {
        let directory = legacyDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return files.compactMap { filename in
            guard filename.hasPrefix("codex-"), filename.hasSuffix(".json") else { return nil }
            let path = (directory as NSString).appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else { return nil }
            let claims = auth.idToken.flatMap(decodeJWT)
            return CodexQuotaAccountIdentity(
                key: filename.codexFilenameKey,
                email: claims?.email,
                accountID: auth.accountId ?? claims?.accountId
            )
        }
    }

    private func fetchLegacyQuotas() async -> [String: ProviderQuotaData] {
        let directory = legacyDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [:] }
        var results: [String: ProviderQuotaData] = [:]

        for filename in files where filename.hasPrefix("codex-") && filename.hasSuffix(".json") {
            let path = (directory as NSString).appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else { continue }
            let claims = auth.idToken.flatMap(decodeJWT)
            let key = filename.codexFilenameKey
            let accountID = auth.accountId ?? claims?.accountId
            let identity = CodexQuotaIdentity(planType: claims?.planType)
            var accessToken = auth.accessToken
            var refreshToken = auth.refreshToken

            if isTokenExpired(accessToken: accessToken), let currentRefreshToken = refreshToken {
                if let refreshed = try? await refreshAccessToken(refreshToken: currentRefreshToken) {
                    accessToken = refreshed.accessToken
                    self.persistLegacyRefresh(refreshed, originalRefreshToken: currentRefreshToken, path: path)
                    refreshToken = refreshed.refreshToken ?? currentRefreshToken
                }
            }

            do {
                do {
                    results[key] = try await fetchQuota(accessToken: accessToken, accountId: accountID, identity: identity)
                } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
                    guard let latestData = try? Data(contentsOf: URL(fileURLWithPath: path)),
                          let latest = try? JSONDecoder().decode(CodexAuthFile.self, from: latestData),
                          let latestRefreshToken = latest.refreshToken ?? refreshToken else { continue }
                    let latestClaims = latest.idToken.flatMap(decodeJWT)
                    let refreshed = try await refreshAccessToken(refreshToken: latestRefreshToken)
                    persistLegacyRefresh(refreshed, originalRefreshToken: latestRefreshToken, path: path)
                    results[key] = try await fetchQuota(
                        accessToken: refreshed.accessToken,
                        accountId: latest.accountId ?? latestClaims?.accountId ?? accountID,
                        identity: CodexQuotaIdentity(planType: latestClaims?.planType ?? claims?.planType)
                    )
                }
            } catch {
                Log.quota("Failed to fetch Codex quota for legacy credential: \(error.localizedDescription)")
            }
        }
        return results
    }

    private func fetchLegacyQuota(at path: String, monitorIdentity: String? = nil) async -> ProviderQuotaData? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else { return nil }
        let claims = auth.idToken.flatMap(decodeJWT)
        guard matchesMonitorIdentity(monitorIdentity, accountID: auth.accountId ?? claims?.accountId, key: (path as NSString).lastPathComponent.codexFilenameKey) else { return nil }
        var accessToken = auth.accessToken
        var refreshToken = auth.refreshToken
        if isTokenExpired(accessToken: accessToken), let currentRefreshToken = refreshToken {
            guard let refreshed = try? await refreshAccessToken(refreshToken: currentRefreshToken, monitorIdentity: monitorIdentity) else { return nil }
            accessToken = refreshed.accessToken
            persistLegacyRefresh(refreshed, originalRefreshToken: currentRefreshToken, path: path)
            refreshToken = refreshed.refreshToken ?? currentRefreshToken
        }
        do {
            return try await fetchQuota(
                accessToken: accessToken,
                accountId: auth.accountId ?? claims?.accountId,
                identity: CodexQuotaIdentity(planType: claims?.planType), monitorIdentity: monitorIdentity
            )
        } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
            guard let latestData = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let latest = try? JSONDecoder().decode(CodexAuthFile.self, from: latestData),
                  matchesMonitorIdentity(monitorIdentity, accountID: latest.accountId ?? latest.idToken.flatMap(decodeJWT)?.accountId, key: (path as NSString).lastPathComponent.codexFilenameKey),
                  let refresh = latest.refreshToken ?? refreshToken,
                  let refreshed = try? await refreshAccessToken(refreshToken: refresh, monitorIdentity: monitorIdentity) else { return nil }
            persistLegacyRefresh(refreshed, originalRefreshToken: refresh, path: path)
            let latestClaims = latest.idToken.flatMap(decodeJWT)
            return try? await fetchQuota(
                accessToken: refreshed.accessToken,
                accountId: latest.accountId ?? latestClaims?.accountId ?? claims?.accountId,
                identity: CodexQuotaIdentity(planType: latestClaims?.planType ?? claims?.planType), monitorIdentity: monitorIdentity
            )
        } catch {
            return nil
        }
    }

    private func fetchNativeKeychainQuotas(monitorIdentity: String? = nil) async -> [String: ProviderQuotaData] {
        guard let record = keychainReader(nil),
              var auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: record.data),
              var tokens = auth.tokens,
              var accessToken = tokens.accessToken else { return [:] }
        let claims = tokens.idToken.flatMap(decodeJWT)
        let key = claims?.email ?? tokens.accountId ?? "Codex"
        guard matchesMonitorIdentity(monitorIdentity, accountID: tokens.accountId ?? claims?.accountId, key: key) else { return [:] }
        do {
            if isTokenExpired(accessToken: accessToken), let refresh = tokens.refreshToken {
                let refreshed = try await refreshAccessToken(refreshToken: refresh, monitorIdentity: monitorIdentity)
                accessToken = refreshed.accessToken
                tokens.accessToken = refreshed.accessToken
                tokens.refreshToken = refreshed.refreshToken ?? refresh
                tokens.idToken = refreshed.idToken ?? tokens.idToken
                auth.tokens = tokens
                if let data = try? JSONEncoder().encode(auth) {
                    _ = KeychainHelper.compareAndSwapExternalCredential(
                        service: "Codex Auth",
                        account: record.account,
                        expectedData: record.data,
                        newData: data
                    )
                }
            }
            do {
                return [key: try await fetchQuota(
                    accessToken: accessToken,
                    accountId: tokens.accountId ?? claims?.accountId,
                    identity: CodexQuotaIdentity(planType: claims?.planType), monitorIdentity: monitorIdentity
                )]
            } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
                guard let latest = keychainReader(record.account),
                      let latestAuth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: latest.data),
                      let latestTokens = latestAuth.tokens,
                      matchesMonitorIdentity(monitorIdentity, accountID: latestTokens.accountId ?? latestTokens.idToken.flatMap(decodeJWT)?.accountId, key: latestTokens.idToken.flatMap(decodeJWT)?.email ?? latestTokens.accountId ?? "Codex"),
                      let refresh = latestTokens.refreshToken else { return [:] }
                let latestClaims = latestTokens.idToken.flatMap(decodeJWT)
                let refreshed = try await refreshAccessToken(refreshToken: refresh, monitorIdentity: monitorIdentity)
                persistNativeKeychainRefresh(refreshed, originalRefreshToken: refresh, account: record.account)
                return [key: try await fetchQuota(
                    accessToken: refreshed.accessToken,
                    accountId: latestTokens.accountId ?? latestClaims?.accountId,
                    identity: CodexQuotaIdentity(planType: latestClaims?.planType), monitorIdentity: monitorIdentity
                )]
            }
        } catch {
            return [:]
        }
    }

    private func persistNativeKeychainRefresh(
        _ refreshed: TokenRefresh,
        originalRefreshToken: String,
        account: String
    ) {
        guard let latest = keychainReader(account),
              var auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: latest.data),
              var tokens = auth.tokens,
              tokens.refreshToken == originalRefreshToken else { return }
        tokens.accessToken = refreshed.accessToken
        tokens.refreshToken = refreshed.refreshToken ?? originalRefreshToken
        tokens.idToken = refreshed.idToken ?? tokens.idToken
        auth.tokens = tokens
        guard let data = try? JSONEncoder().encode(auth) else { return }
        _ = KeychainHelper.compareAndSwapExternalCredential(
            service: "Codex Auth",
            account: account,
            expectedData: latest.data,
            newData: data
        )
    }

    private func fetchOwnedQuotas() async -> [String: ProviderQuotaData] {
        var results: [String: ProviderQuotaData] = [:]
        for account in await vault.accounts().filter({ $0.provider == .codex && !$0.isDisabled }) {
            guard var credential = await vault.credential(for: account.id) else { continue }
            do {
                if credential.expiresAt.map({ $0.timeIntervalSinceNow < 300 }) ?? isTokenExpired(accessToken: credential.accessToken),
                   let refresh = credential.refreshToken {
                    let originalCredential = credential
                    let refreshed = try await refreshAccessToken(refreshToken: refresh)
                    credential.accessToken = refreshed.accessToken
                    credential.refreshToken = refreshed.refreshToken ?? refresh
                    credential.idToken = refreshed.idToken ?? credential.idToken
                    credential.expiresAt = refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                    try await vault.saveRefreshed(credential, replacing: originalCredential, accountID: account.id)
                }
                let claims = credential.idToken.flatMap(decodeJWT)
                do {
                    results[account.accountKey] = try await fetchQuota(
                        accessToken: credential.accessToken,
                        accountId: credential.accountID ?? claims?.accountId,
                        identity: CodexQuotaIdentity(planType: claims?.planType)
                    )
                } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
                    if let latest = await vault.reloadLatest(accountID: account.id) {
                        credential = latest
                    }
                    guard let refresh = credential.refreshToken else { throw CodexCLIQuotaError.tokenRefreshFailed }
                    let originalCredential = credential
                    let refreshed = try await refreshAccessToken(refreshToken: refresh)
                    credential.accessToken = refreshed.accessToken
                    credential.refreshToken = refreshed.refreshToken ?? refresh
                    credential.idToken = refreshed.idToken ?? credential.idToken
                    credential.expiresAt = refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                    try await vault.saveRefreshed(credential, replacing: originalCredential, accountID: account.id)
                    results[account.accountKey] = try await fetchQuota(
                        accessToken: credential.accessToken,
                        accountId: credential.accountID ?? claims?.accountId,
                        identity: CodexQuotaIdentity(planType: claims?.planType)
                    )
                }
            } catch {
                Log.quota("Failed to fetch Codex quota for Quotio credential")
            }
        }
        return results
    }

    private func fetchOwnedQuota(_ account: MonitorAccount, monitorIdentity: String? = nil) async -> ProviderQuotaData? {
        guard var credential = await vault.credential(for: account.id) else { return nil }
        guard matchesMonitorIdentity(monitorIdentity, accountID: credential.accountID ?? credential.idToken.flatMap(decodeJWT)?.accountId, key: account.accountKey) else { return nil }
        do {
            if credential.expiresAt.map({ $0.timeIntervalSinceNow < 300 }) ?? isTokenExpired(accessToken: credential.accessToken),
               let refresh = credential.refreshToken {
                let originalCredential = credential
                let refreshed = try await refreshAccessToken(refreshToken: refresh, monitorIdentity: monitorIdentity)
                credential.accessToken = refreshed.accessToken
                credential.refreshToken = refreshed.refreshToken ?? refresh
                credential.idToken = refreshed.idToken ?? credential.idToken
                credential.expiresAt = refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                try await vault.saveRefreshed(credential, replacing: originalCredential, accountID: account.id)
            }
            let claims = credential.idToken.flatMap(decodeJWT)
            do {
                return try await fetchQuota(
                    accessToken: credential.accessToken,
                    accountId: credential.accountID ?? claims?.accountId,
                    identity: CodexQuotaIdentity(planType: claims?.planType), monitorIdentity: monitorIdentity
                )
            } catch CodexCLIQuotaError.httpError(let status) where status == 401 || status == 403 {
                if let latest = await vault.reloadLatest(accountID: account.id) {
                    credential = latest
                }
                guard matchesMonitorIdentity(monitorIdentity, accountID: credential.accountID ?? credential.idToken.flatMap(decodeJWT)?.accountId, key: account.accountKey),
                      let refresh = credential.refreshToken else { return nil }
                let originalCredential = credential
                let refreshed = try await refreshAccessToken(refreshToken: refresh, monitorIdentity: monitorIdentity)
                credential.accessToken = refreshed.accessToken
                credential.refreshToken = refreshed.refreshToken ?? refresh
                credential.idToken = refreshed.idToken ?? credential.idToken
                credential.expiresAt = refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                try await vault.saveRefreshed(credential, replacing: originalCredential, accountID: account.id)
                let latestClaims = credential.idToken.flatMap(decodeJWT)
                return try await fetchQuota(
                    accessToken: credential.accessToken,
                    accountId: credential.accountID ?? latestClaims?.accountId,
                    identity: CodexQuotaIdentity(planType: latestClaims?.planType), monitorIdentity: monitorIdentity
                )
            }
        } catch {
            return nil
        }
    }

    private func persistRefresh(_ refreshed: TokenRefresh, originalRefreshToken: String, path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let currentData = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: currentData) as? [String: Any],
              var tokenJSON = json["tokens"] as? [String: Any],
              tokenJSON["refresh_token"] as? String == originalRefreshToken else {
            return
        }
        tokenJSON["access_token"] = refreshed.accessToken
        tokenJSON["refresh_token"] = refreshed.refreshToken ?? originalRefreshToken
        if let idToken = refreshed.idToken { tokenJSON["id_token"] = idToken }
        json["tokens"] = tokenJSON
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try SecureAtomicFileWriter.write(data, to: url)
    }

    private func persistLegacyRefresh(_ refreshed: TokenRefresh, originalRefreshToken: String, path: String) {
        let url = URL(fileURLWithPath: path)
        guard let currentData = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: currentData) as? [String: Any],
              json["refresh_token"] as? String == originalRefreshToken else { return }
        json["access_token"] = refreshed.accessToken
        json["refresh_token"] = refreshed.refreshToken ?? originalRefreshToken
        if let idToken = refreshed.idToken { json["id_token"] = idToken }
        let lifetime = TimeInterval(refreshed.expiresIn ?? 3600)
        json["expired"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(lifetime))
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? SecureAtomicFileWriter.write(data, to: url)
    }

    private func readAuthFile(at path: String) -> CodexCLIAuthFile? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(CodexCLIAuthFile.self, from: data)
    }
}

private extension String {
    nonisolated var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? self
    }
}

private extension CharacterSet {
    nonisolated static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

// MARK: - Errors

nonisolated enum CodexCLIQuotaError: LocalizedError {
    case invalidResponse
    case invalidURL
    case httpError(Int)
    case noAccessToken
    case tokenRefreshFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from ChatGPT"
        case .invalidURL: return "Invalid URL"
        case .httpError(let code): return "HTTP error: \(code)"
        case .noAccessToken: return "No access token found in Codex auth file"
        case .tokenRefreshFailed: return "Failed to refresh Codex token"
        }
    }
}

extension CodexCLIQuotaFetcher {
    /// 绑定已验证的稳定身份，来源在请求前或 401 重试期间换号时拒绝借用新账号令牌。
    private func matchesMonitorIdentity(_ expected: String?, accountID: String?, key: String) -> Bool {
        guard let expected else { return true }
        let actual = accountID.flatMap { $0.isEmpty ? nil : "id:" + $0 }
            ?? "key:" + key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return actual == expected
    }

    private func monitorIdentityIsEnabled(_ expected: String?) async -> Bool {
        guard let expected else { return true }
        guard !Task.isCancelled else { return false }
        return await monitorCredentialGroups().contains {
            !$0.account.isDisabled && $0.sources.contains { $0.identity == expected }
        }
    }

    /// 账号发现、禁用过滤和额度请求共用这一来源快照，避免三条路径各自猜测账号键。
    func monitorCredentialGroups() async -> [CodexMonitorGroup] {
        var sources: [CodexMonitorSource] = []
        for account in await vault.accounts() where account.provider == .codex {
            let credential = await vault.credential(for: account.id)
            let claims = credential?.idToken.flatMap(decodeJWT)
            sources.append(CodexMonitorSource(account: account, accountID: credential?.accountID ?? claims?.accountId,
                                             kind: .vault, isReadable: credential != nil))
        }
        if let record = keychainReader(nil),
           let auth = try? JSONDecoder().decode(CodexCLIAuthFile.self, from: record.data),
           let tokens = auth.tokens, tokens.accessToken?.isEmpty == false {
            let claims = tokens.idToken.flatMap(decodeJWT)
            let accountID = tokens.accountId ?? claims?.accountId
            let account = MonitorAccount.make(provider: .codex, accountKey: claims?.email ?? accountID ?? "Codex",
                                               source: .nativeCredential, credentialReference: "keychain:Codex Auth")
            sources.append(CodexMonitorSource(account: account, accountID: accountID, kind: .keychain))
        }
        for source in readAuthSources() {
            guard let tokens = source.auth.tokens else { continue }
            let claims = tokens.idToken.flatMap(decodeJWT)
            let accountID = tokens.accountId ?? claims?.accountId
            let account = MonitorAccount.make(provider: .codex, accountKey: claims?.email ?? accountID ?? "Codex",
                                               source: .nativeCredential, credentialReference: source.path)
            sources.append(CodexMonitorSource(account: account, accountID: accountID, kind: .file(source.path)))
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: legacyDirectory)) ?? []
        for name in files.sorted() where name.hasPrefix("codex-") && name.hasSuffix(".json") {
            let path = (legacyDirectory as NSString).appendingPathComponent(name)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data), !auth.accessToken.isEmpty else { continue }
            let claims = auth.idToken.flatMap(decodeJWT)
            let account = MonitorAccount.make(provider: .codex, accountKey: name.codexFilenameKey,
                                               displayName: claims?.email, source: .legacyCLIProxy, credentialReference: path)
            sources.append(CodexMonitorSource(account: account, accountID: auth.accountId ?? claims?.accountId, kind: .legacy(path)))
        }
        return CodexMonitorGroup.resolve(sources, disabledIDs: await metadata.disabledAccountIDs())
    }

    func fetchMonitorQuotas() async -> [String: ProviderQuotaData] {
        var quotas: [String: ProviderQuotaData] = [:]
        let initial = await monitorCredentialGroups()
        for group in initial where !group.account.isDisabled {
            guard !Task.isCancelled else { break }
            if let quota = await fetchMonitorQuota(forAccountKey: group.account.accountKey) {
                quotas[group.account.accountKey] = quota
            }
        }
        return CodexMonitorGroup.reconcile(quotas, groups: await monitorCredentialGroups())
    }

    func fetchMonitorQuota(forAccountKey key: String) async -> ProviderQuotaData? {
        // 每个网络来源开始前重新读取禁用元数据。同一账号通过别名或备用来源也不能绕过禁用。
        let initial = await monitorCredentialGroups()
        guard let group = initial.first(where: { $0.aliases.contains(key) }), !group.account.isDisabled else { return nil }
        for source in group.sources {
            guard !Task.isCancelled,
                  let liveGroup = await monitorCredentialGroups().first(where: {
                      $0.account.accountKey == group.account.accountKey && !$0.account.isDisabled
                  }) else { return nil }
            guard liveGroup.sources.contains(where: {
                $0.kind == source.kind && $0.account.id == source.account.id
                    && $0.account.credentialReference == source.account.credentialReference
            }) else { continue }
            let quota: ProviderQuotaData?
            switch source.kind {
            case .vault:
                quota = await fetchOwnedQuota(source.account, monitorIdentity: source.identity)
            case .keychain:
                quota = await fetchNativeKeychainQuotas(monitorIdentity: source.identity).values.first
            case .file(let path):
                guard let auth = readAuthFile(at: path) else { continue }
                quota = await fetchLocalAuthQuota(source: (path, auth), claims: auth.tokens?.idToken.flatMap(decodeJWT), monitorIdentity: source.identity)
            case .legacy(let path):
                quota = await fetchLegacyQuota(at: path, monitorIdentity: source.identity)
            }
            if var quota {
                guard await monitorCredentialGroups().contains(where: {
                    $0.account.accountKey == group.account.accountKey && !$0.account.isDisabled
                        && $0.sources.contains { $0.identity == source.identity }
                }) else { return nil }
                quota.monitorAccountIdentity = source.identity
                if quota.accountDisplayName == nil { quota.accountDisplayName = group.account.displayName }
                return quota
            }
        }
        return nil
    }
}
