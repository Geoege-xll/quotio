//
//  AntigravityQuotaFetcher.swift
//  Quotio
//

import Foundation
import SwiftUI

// MARK: - Models

// MARK: - Model Group

nonisolated enum AntigravityModelGroup: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case geminiPro = "Gemini Pro"
    case geminiFlash = "Gemini Flash"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var icon: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .geminiPro: return "sparkles"
        case .geminiFlash: return "bolt.fill"
        }
    }

    static func group(for modelName: String) -> AntigravityModelGroup? {
        let name = modelName.lowercased()

        // Claude group includes gpt and oss models
        if name.contains("claude") || name.contains("gpt") || name.contains("oss") {
            return .claude
        }

        if name.contains("gemini") && name.contains("pro") {
            return .geminiPro
        }

        if name.contains("gemini") && name.contains("flash") {
            return .geminiFlash
        }

        return nil
    }
}

nonisolated struct GroupedModelQuota: Identifiable, Sendable {
    let group: AntigravityModelGroup
    let models: [ModelQuota]

    var id: String { group.id }

    var percentage: Double {
        models.map(\.percentage).min() ?? 0
    }

    var formattedPercentage: String {
        if percentage == percentage.rounded() {
            return String(format: "%.0f%%", percentage)
        }
        return String(format: "%.2f%%", percentage)
    }

    // Uses earliest reset time among all models in the group
    var resetTime: String {
        models.compactMap { model -> Date? in
            parseISO8601Date(model.resetTime)
        }.min().map { date in
            ISO8601DateFormatter().string(from: date)
        } ?? ""
    }

    var formattedResetTime: String {
        guard !resetTime.isEmpty,
              let date = parseISO8601Date(resetTime) else {
            return "—"
        }

        let now = Date()
        let interval = date.timeIntervalSince(now)

        if interval <= 0 {
            return "now"
        }

        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let days = hours / 24
        let remainingHours = hours % 24

        if days > 0 {
            if remainingHours > 0 {
                return "\(days)d \(remainingHours)h"
            }
            return "\(days)d"
        } else if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours)h"
        } else {
            return "\(max(1, minutes))m"
        }
    }

    /// Parse ISO8601 date string, trying both with and without fractional seconds
    private func parseISO8601Date(_ dateString: String) -> Date? {
        let isoFormatterWithFractional = ISO8601DateFormatter()
        isoFormatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterStandard = ISO8601DateFormatter()
        isoFormatterStandard.formatOptions = [.withInternetDateTime]

        return isoFormatterWithFractional.date(from: dateString)
            ?? isoFormatterStandard.date(from: dateString)
    }

    var displayName: String { group.displayName }
}

// MARK: - Subscription Info Models

nonisolated struct SubscriptionTier: Codable, Sendable {
    let id: String
    let name: String
    let description: String
    let privacyNotice: PrivacyNotice?
    let isDefault: Bool?
    let upgradeSubscriptionUri: String?
    let upgradeSubscriptionText: String?
    let upgradeSubscriptionType: String?
    let userDefinedCloudaicompanionProject: Bool?
}

nonisolated struct PrivacyNotice: Codable, Sendable {
    let showNotice: Bool?
    let noticeText: String?
}

nonisolated struct SubscriptionInfo: Codable, Sendable {
    let currentTier: SubscriptionTier?
    let allowedTiers: [SubscriptionTier]?
    let cloudaicompanionProject: String?
    let gcpManaged: Bool?
    let upgradeSubscriptionUri: String?
    let paidTier: SubscriptionTier?

    /// Get the effective tier - prioritize paidTier over currentTier
    private var effectiveTier: SubscriptionTier? {
        paidTier ?? currentTier
    }

    var tierDisplayName: String {
        effectiveTier?.name ?? "Unknown"
    }

    var tierDescription: String {
        effectiveTier?.description ?? ""
    }

    var tierId: String {
        effectiveTier?.id ?? "unknown"
    }

    var isPaidTier: Bool {
        guard let id = effectiveTier?.id else { return false }
        return id.contains("pro") || id.contains("ultra")
    }

    var canUpgrade: Bool {
        effectiveTier?.upgradeSubscriptionUri != nil
    }

    var upgradeURL: URL? {
        guard let uri = effectiveTier?.upgradeSubscriptionUri else { return nil }
        return URL(string: uri)
    }
}

// MARK: - API Response Models

nonisolated private struct TokenRefreshResponse: Codable, Sendable {
    let accessToken: String
    let expiresIn: Int
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

// MARK: - Auth File Model

nonisolated struct AntigravityAuthFile: Codable, Sendable {
    var accessToken: String
    let email: String
    var expired: String?
    let expiresIn: Int?
    let refreshToken: String?
    let timestamp: Int?
    let type: String?
    // Fields preserved during token refresh (used by CLIProxyAPI)
    var prefix: String?
    var projectId: String?
    var proxyUrl: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case email
        case expired
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case timestamp
        case type
        case prefix
        case projectId = "project_id"
        case proxyUrl = "proxy_url"
    }

    /// 判定过期与切换账号写入数据库共用同一解析结果，保留 ISO8601 小数秒。
    nonisolated var expiryDate: Date? {
        guard let expired else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: expired) ?? ISO8601DateFormatter().date(from: expired)
    }

    nonisolated var isExpired: Bool {
        guard let expiryDate else { return true }
        return Date() > expiryDate
    }

}

// MARK: - Fetcher

actor AntigravityQuotaFetcher {
    private let loadProjectAPIURL = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let clientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private let clientSecret = "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"
    private let userAgent = AntigravityQuotaEndpoints.userAgent
    private let nativeCacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Quotio/Monitor/antigravity-shadow-v1.json")

    private var session: URLSession
    private let databaseService = AntigravityDatabaseService()

    // Cache subscription info to avoid duplicate API calls within same refresh cycle
    private var subscriptionCache: [String: SubscriptionInfo] = [:]

    private struct NativeToken: Sendable {
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Date?
    }

    private struct NativeTokenCache: Codable {
        var accessToken: String
        var expiresAt: Date
        var refreshFingerprint: String
    }

    /// 注入会话用于验证汇总优先与回退行为，测试不访问真实账号或网络。
    init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    /// Clear the subscription cache and release memory (call at start of refresh cycle)
    func clearCache() {
        // Create new empty dictionary to release old capacity, not just removeAll()
        subscriptionCache = [:]
    }

    func refreshAccessToken(refreshToken: String) async throws -> String {
        let (accessToken, _) = try await refreshAccessTokenWithExpiry(refreshToken: refreshToken)
        return accessToken
    }

    private func refreshAccessTokenWithExpiry(refreshToken: String) async throws -> (String, Int) {
        guard let url = URL(string: tokenURL) else {
            throw QuotaFetchError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]

        let body = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw QuotaFetchError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let tokenResponse = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
        return (tokenResponse.accessToken, tokenResponse.expiresIn)
    }

    /// Persist refreshed access token back to auth file using read-modify-write
    /// to preserve all existing fields (including `disabled`, etc.)
    private func persistRefreshedToken(at url: URL, originalData: Data, newAccessToken: String, expiresIn: Int) {
        guard (try? Data(contentsOf: url)) == originalData else { return }
        guard var json = try? JSONSerialization.jsonObject(with: originalData) as? [String: Any] else { return }
        json["access_token"] = newAccessToken

        let now = Date()
        let expiryDate = now.addingTimeInterval(TimeInterval(expiresIn))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        json["expired"] = formatter.string(from: expiryDate)
        json["expires_in"] = expiresIn
        json["timestamp"] = Int64(now.timeIntervalSince1970 * 1000)

        if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            try? SecureAtomicFileWriter.write(updatedData, to: url)
        }
    }

    /// 已导入账号使用凭据中明确的项目；本机 IDE 账号才通过 loadCodeAssist 发现项目。
    /// 汇总接口不可用时报告失败，不能以模型目录的 100% 替代真实会话／周限额。
    func fetchQuota(accessToken: String, projectId: String? = nil) async throws -> ProviderQuotaData {
        let resolvedProject: String?
        if let project = QuotaResponseValue.string(projectId) { resolvedProject = project }
        else { resolvedProject = await fetchProjectId(accessToken: accessToken) }
        guard let resolvedProject else { throw QuotaFetchError.invalidResponse }
        var lastError: Error = QuotaFetchError.invalidResponse
        for host in AntigravityQuotaEndpoints.hosts {
            try Task.checkCancellation()
            do {
                let data = try await postCloudCode(urlString: host + "/v1internal:retrieveUserQuotaSummary",
                    accessToken: accessToken, payload: ["project": resolvedProject])
                guard let models = AntigravityQuotaParser.summaryModels(from: data) else { throw QuotaFetchError.invalidResponse }
                return ProviderQuotaData(models: models, lastUpdated: Date())
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        if case QuotaFetchError.httpError(403) = lastError { return ProviderQuotaData(isForbidden: true) }
        throw lastError
    }

    private func postCloudCode(urlString: String, accessToken: String, payload: [String: Any]) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw QuotaFetchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuotaFetchError.invalidResponse
        }
        guard 200...299 ~= httpResponse.statusCode else {
            throw QuotaFetchError.httpError(httpResponse.statusCode)
        }

        return data
    }

    private func fetchProjectId(accessToken: String) async -> String? {
        // Use cached subscription info if available, otherwise fetch
        if let cached = subscriptionCache[accessToken] {
            return cached.cloudaicompanionProject
        }
        let result = await fetchSubscriptionInfo(accessToken: accessToken)
        if let info = result {
            subscriptionCache[accessToken] = info
        }
        return result?.cloudaicompanionProject
    }

    func fetchSubscriptionInfo(accessToken: String) async -> SubscriptionInfo? {
        guard let url = URL(string: loadProjectAPIURL) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ["metadata": ["ideType": "ANTIGRAVITY"]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  200...299 ~= httpResponse.statusCode else {
                return nil
            }

            let subscriptionInfo = try JSONDecoder().decode(SubscriptionInfo.self, from: data)
            return subscriptionInfo

        } catch {
            return nil
        }
    }




    /// Fetch both quota and subscription for an auth file in one operation
    /// This reuses the subscription info fetched during quota fetch (via fetchProjectId)
    func fetchQuotaAndSubscriptionForAuthFile(at path: String) async -> (quota: ProviderQuotaData?, subscription: SubscriptionInfo?) {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let authFile = try? JSONDecoder().decode(AntigravityAuthFile.self, from: data) else {
            return (nil, nil)
        }

        var accessToken = authFile.accessToken

        if authFile.isExpired, let refreshToken = authFile.refreshToken {
            do {
                let (token, expiresIn) = try await refreshAccessTokenWithExpiry(refreshToken: refreshToken)
                accessToken = token
                persistRefreshedToken(at: url, originalData: data, newAccessToken: accessToken, expiresIn: expiresIn)
            } catch {
                return (nil, nil)
            }
        }

        // Fetch quota - this internally calls fetchProjectId which fetches and caches subscription
        var quota: ProviderQuotaData? = nil
        do {
            quota = try await fetchQuota(accessToken: accessToken, projectId: authFile.projectId)
        } catch {
            // Quota fetch failed, but we might still have subscription in cache
        }

        // Get subscription from cache (was fetched during fetchProjectId in fetchQuota)
        let subscription: SubscriptionInfo?
        if let cached = subscriptionCache[accessToken] { subscription = cached }
        else { subscription = await fetchSubscriptionInfo(accessToken: accessToken) }

        return (quota, subscription)
    }


    /// Fetch all Antigravity data (quotas + subscriptions) in one call
    /// This avoids duplicate API calls by reusing cached subscription info
    func fetchAllAntigravityData(
        authDir: String = "~/.cli-proxy-api",
        includeMonitorCredentials: Bool = false
    ) async -> (quotas: [String: ProviderQuotaData], subscriptions: [String: SubscriptionInfo]) {
        // Clear cache at start of refresh cycle
        clearCache()

        let expandedPath = NSString(string: authDir).expandingTildeInPath
        let fileManager = FileManager.default

        var quotaResults: [String: ProviderQuotaData] = [:]
        var subscriptionResults: [String: SubscriptionInfo] = [:]

        if includeMonitorCredentials {
            for account in await MonitorCredentialVault.shared.accounts().filter({ $0.provider == .antigravity && !$0.isDisabled }) {
                guard var credential = await MonitorCredentialVault.shared.credential(for: account.id) else { continue }
                if credential.expiresAt.map({ $0.timeIntervalSinceNow < 300 }) ?? false,
                   let refresh = credential.refreshToken,
                   let (access, expiresIn) = try? await refreshAccessTokenWithExpiry(refreshToken: refresh) {
                    let originalCredential = credential
                    credential.accessToken = access
                    credential.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
                    try? await MonitorCredentialVault.shared.saveRefreshed(credential, replacing: originalCredential, accountID: account.id)
                }
                do {
                    var quota = try await fetchQuota(accessToken: credential.accessToken)
                    if quota.isForbidden,
                       let latest = await MonitorCredentialVault.shared.reloadLatest(accountID: account.id),
                       let refresh = latest.refreshToken,
                       let (access, expiresIn) = try? await refreshAccessTokenWithExpiry(refreshToken: refresh) {
                        credential = latest
                        let originalCredential = credential
                        credential.accessToken = access
                        credential.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
                        try? await MonitorCredentialVault.shared.saveRefreshed(credential, replacing: originalCredential, accountID: account.id)
                        quota = try await fetchQuota(accessToken: access)
                    }
                    quotaResults[account.accountKey] = quota
                    if let subscription = subscriptionCache[credential.accessToken] {
                        subscriptionResults[account.accountKey] = subscription
                    }
                } catch QuotaFetchError.httpError(let status) where status == 401 || status == 403 {
                    if let latest = await MonitorCredentialVault.shared.reloadLatest(accountID: account.id),
                       let refresh = latest.refreshToken,
                       let (access, expiresIn) = try? await refreshAccessTokenWithExpiry(refreshToken: refresh) {
                        credential = latest
                        let originalCredential = credential
                        credential.accessToken = access
                        credential.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
                        try? await MonitorCredentialVault.shared.saveRefreshed(credential, replacing: originalCredential, accountID: account.id)
                        quotaResults[account.accountKey] = try? await fetchQuota(accessToken: access)
                        if let subscription = subscriptionCache[access] {
                            subscriptionResults[account.accountKey] = subscription
                        }
                    }
                } catch {
                    continue
                }
            }
        }

        if let ideToken = try? await databaseService.getCurrentTokenInfo(),
           let accessToken = await usableNativeAccessToken(from: NativeToken(
               accessToken: ideToken.accessToken,
               refreshToken: ideToken.refreshToken,
               expiresAt: ideToken.expiry.map {
                   let raw = TimeInterval($0)
                   return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
               }
           )),
           let quota = try? await fetchQuota(accessToken: accessToken) {
            let key = await nativeAccountName(accessToken: accessToken)
            quotaResults[key] = quota
            if let subscription = subscriptionCache[accessToken] {
                subscriptionResults[key] = subscription
            }
        }

        guard let files = try? fileManager.contentsOfDirectory(atPath: expandedPath) else {
            return (quotaResults, subscriptionResults)
        }

        // Run all fetches concurrently using TaskGroup
        await withTaskGroup(of: (String, ProviderQuotaData?, SubscriptionInfo?).self) { group in
            for file in files where file.hasPrefix("antigravity-") && file.hasSuffix(".json") {
                let filePath = (expandedPath as NSString).appendingPathComponent(file)
                let email = file
                    .replacingOccurrences(of: "antigravity-", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                    .replacingOccurrences(of: "_", with: ".")
                    .replacingOccurrences(of: ".gmail.com", with: "@gmail.com")

                group.addTask {
                    // Fetch both quota and subscription in one call
                    let result = await self.fetchQuotaAndSubscriptionForAuthFile(at: filePath)
                    return (email, result.quota, result.subscription)
                }
            }

            for await (email, quota, subscription) in group {
                if let quota = quota, quotaResults[email] == nil {
                    quotaResults[email] = quota
                }
                if let subscription = subscription, subscriptionResults[email] == nil {
                    subscriptionResults[email] = subscription
                }
            }
        }

        return (quotaResults, subscriptionResults)
    }

    /// Fetches quota and subscription for exactly one canonical account key.
    func fetchData(forAccountKey accountKey: String) async -> (
        quota: ProviderQuotaData?,
        subscription: SubscriptionInfo?
    ) {
        if let account = await MonitorCredentialVault.shared.accounts().first(where: {
            $0.provider == .antigravity && !$0.isDisabled && $0.accountKey == accountKey
        }), var credential = await MonitorCredentialVault.shared.credential(for: account.id) {
            if credential.expiresAt.map({ $0.timeIntervalSinceNow < 300 }) ?? false,
               let refresh = credential.refreshToken,
               let (access, expiresIn) = try? await refreshAccessTokenWithExpiry(refreshToken: refresh) {
                let originalCredential = credential
                credential.accessToken = access
                credential.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
                try? await MonitorCredentialVault.shared.saveRefreshed(credential, replacing: originalCredential, accountID: account.id)
            }
            var quota: ProviderQuotaData?
            do {
                quota = try await fetchQuota(accessToken: credential.accessToken)
            } catch QuotaFetchError.httpError(let status) where status == 401 || status == 403 {
                quota = nil
            } catch {
                return (nil, subscriptionCache[credential.accessToken])
            }
            var didRetryCredential = false
            if quota?.isForbidden == true,
               let latest = await MonitorCredentialVault.shared.reloadLatest(accountID: account.id),
               let refresh = latest.refreshToken,
               let (access, expiresIn) = try? await refreshAccessTokenWithExpiry(refreshToken: refresh) {
                didRetryCredential = true
                credential = latest
                let originalCredential = credential
                credential.accessToken = access
                credential.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
                try? await MonitorCredentialVault.shared.saveRefreshed(credential, replacing: originalCredential, accountID: account.id)
                quota = try? await fetchQuota(accessToken: access)
            }
            if quota == nil, !didRetryCredential,
               let latest = await MonitorCredentialVault.shared.reloadLatest(accountID: account.id),
               let refresh = latest.refreshToken,
               let (access, expiresIn) = try? await refreshAccessTokenWithExpiry(refreshToken: refresh) {
                credential = latest
                let originalCredential = credential
                credential.accessToken = access
                credential.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
                try? await MonitorCredentialVault.shared.saveRefreshed(credential, replacing: originalCredential, accountID: account.id)
                quota = try? await fetchQuota(accessToken: access)
            }
            return (quota, subscriptionCache[credential.accessToken])
        }

        if let ideToken = try? await databaseService.getCurrentTokenInfo(),
           let access = await usableNativeAccessToken(from: NativeToken(
               accessToken: ideToken.accessToken,
               refreshToken: ideToken.refreshToken,
               expiresAt: ideToken.expiry.map {
                   let raw = TimeInterval($0)
                   return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
               }
           )), await nativeAccountName(accessToken: access) == accountKey {
            let quota = try? await fetchQuota(accessToken: access)
            return (quota, subscriptionCache[access])
        }

        let directory = NSString(string: "~/.cli-proxy-api").expandingTildeInPath
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return (nil, nil)
        }
        for file in files where file.hasPrefix("antigravity-") && file.hasSuffix(".json") {
            let path = (directory as NSString).appendingPathComponent(file)
            let key = file
                .replacingOccurrences(of: "antigravity-", with: "")
                .replacingOccurrences(of: ".json", with: "")
                .replacingOccurrences(of: "_", with: ".")
                .replacingOccurrences(of: ".gmail.com", with: "@gmail.com")
            guard key == accountKey else { continue }
            return await fetchQuotaAndSubscriptionForAuthFile(at: path)
        }
        return (nil, nil)
    }

    private func usableNativeAccessToken(from token: NativeToken) async -> String? {
        if let access = token.accessToken,
           token.expiresAt.map({ $0.timeIntervalSinceNow > 300 }) ?? true {
            return access
        }
        guard let refresh = token.refreshToken else { return token.accessToken }
        let fingerprint = MonitorIdentity.fingerprint(refresh)
        if let data = try? Data(contentsOf: nativeCacheURL),
           let cached = try? JSONDecoder().decode(NativeTokenCache.self, from: data),
           cached.refreshFingerprint == fingerprint,
           cached.expiresAt.timeIntervalSinceNow > 300 {
            return cached.accessToken
        }
        guard let (access, expiresIn) = try? await refreshAccessTokenWithExpiry(refreshToken: refresh) else { return nil }
        let cache = NativeTokenCache(
            accessToken: access,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            refreshFingerprint: fingerprint
        )
        if let data = try? JSONEncoder().encode(cache) {
            try? SecureAtomicFileWriter.write(data, to: nativeCacheURL)
        }
        return access
    }

    private func nativeAccountName(accessToken: String) async -> String {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else { return "Antigravity" }
        var request = URLRequest(url: url)
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200...299 ~= http.statusCode,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String,
              !email.isEmpty else { return "Antigravity" }
        return email
    }

    private func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

}

// MARK: - Errors

nonisolated enum QuotaFetchError: LocalizedError {
    case invalidURL
    case invalidResponse
    case forbidden
    case httpError(Int)
    case unknown
    case apiErrorMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response from server"
        case .forbidden: return "Access forbidden"
        case .httpError(let code): return "HTTP error: \(code)"
        case .unknown: return "Unknown error"
        case .apiErrorMessage(let msg): return "API error: \(msg)"
        }
    }
}
