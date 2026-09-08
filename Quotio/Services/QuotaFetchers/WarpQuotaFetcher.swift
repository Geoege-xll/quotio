//
//  WarpQuotaFetcher.swift
//  Quotio
//
//  Fetches quota information from Warp AI Terminal GraphQL API.
//

import Foundation

struct WarpQuotaResponse: Codable, Sendable {
    let data: WarpDataWrapper?
    
    struct WarpDataWrapper: Codable, Sendable {
        let user: WarpUserOutput?
    }
    
    struct WarpUserOutput: Codable, Sendable {
        let user: WarpUser?
    }
    
    struct WarpUser: Codable, Sendable {
        let requestLimitInfo: WarpRequestLimitInfo?
        let workspaces: [WarpWorkspace]?
        let bonusGrants: [WarpBonusGrant]?
    }
    
    struct WarpWorkspace: Codable, Sendable {
        let uid: String?
        let bonusGrantsInfo: WarpBonusGrantsInfo?
    }
    
    struct WarpBonusGrantsInfo: Codable, Sendable {
        let grants: [WarpBonusGrant]?
    }
    
    struct WarpBonusGrant: Codable, Sendable {
        let createdAt: String?
        let costCents: Int?
        let expiration: String?
        let reason: String?
        let userFacingMessage: String?
        let requestCreditsGranted: Int?
        let requestCreditsRemaining: Int?
    }
    
    struct WarpRequestLimitInfo: Codable, Sendable {
        let isUnlimited: Bool?
        let nextRefreshTime: String?
        let requestLimit: Int?
        let requestsUsedSinceLastRefresh: Int?
    }
}

actor WarpQuotaFetcher {
    private let apiURL = "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo"
    private var session: URLSession

    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        config.httpAdditionalHeaders = [
            "Content-Type": "application/json",
            "x-warp-client-id": "warp-app",
            "x-warp-client-version": "v0.2026.01.07.08.13.stable_01"
        ]
        self.session = URLSession(configuration: config)
    }

    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        config.httpAdditionalHeaders = [
            "Content-Type": "application/json",
            "x-warp-client-id": "warp-app",
            "x-warp-client-version": "v0.2026.01.07.08.13.stable_01"
        ]
        self.session = URLSession(configuration: config)
    }

    func fetchQuota(apiKey: String) async throws -> ProviderQuotaData {
        guard let url = URL(string: apiURL) else { throw QuotaFetchError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let query = """
        query GetRequestLimitInfo($requestContext: RequestContext!) {
          user(requestContext: $requestContext) {
            __typename
            ... on UserOutput {
              user {
                requestLimitInfo {
                  isUnlimited
                  nextRefreshTime
                  requestLimit
                  requestsUsedSinceLastRefresh
                }
                workspaces {
                  uid
                  bonusGrantsInfo {
                    grants {
                      createdAt
                      costCents
                      expiration
                      reason
                      userFacingMessage
                      requestCreditsGranted
                      requestCreditsRemaining
                    }
                    spendingInfo {
                      currentMonthCreditsPurchased
                      currentMonthPeriodEnd
                      currentMonthSpendCents
                    }
                  }
                }
                bonusGrants {
                  createdAt
                  costCents
                  expiration
                  reason
                  userFacingMessage
                  requestCreditsGranted
                  requestCreditsRemaining
                }
              }
            }
          }
        }
        """
        
        let variables: [String: Any] = [
            "requestContext": [
                "clientContext": [:],
                "osContext": [
                    "category": "macOS",
                    "name": "macOS",
                    "version": "26.2"
                ]
            ]
        ]
        
        let body: [String: Any] = [
            "query": query,
            "variables": variables,
            "operationName": "GetRequestLimitInfo"
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuotaFetchError.invalidResponse
        }

        guard 200...299 ~= httpResponse.statusCode else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return await MainActor.run { ProviderQuotaData(isForbidden: true) }
            }
            throw QuotaFetchError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let warpResponse = try await MainActor.run {
            try decoder.decode(WarpQuotaResponse.self, from: data)
        }

        return try await mapQuotaResponse(warpResponse)
    }

    /// 把网络请求与固定响应映射分开，允许用确定时间验证赠送额度的到期边界。
    func mapQuotaResponse(_ warpResponse: WarpQuotaResponse, now: Date = Date()) async throws -> ProviderQuotaData {
        guard let info = warpResponse.data?.user?.user?.requestLimitInfo else {
            throw QuotaFetchError.invalidResponse
        }

        let workspaces = warpResponse.data?.user?.user?.workspaces ?? []
        let userBonusGrants = warpResponse.data?.user?.user?.bonusGrants ?? []

        return await MainActor.run {
            var models: [ModelQuota] = []

            let used = info.requestsUsedSinceLastRefresh
            let limit = info.requestLimit
            let remaining = used.flatMap { used in limit.map { max(0, $0 - used) } }
            let isUnlimited = info.isUnlimited ?? false

            let percentage: Double
            if isUnlimited {
                percentage = -1
            } else if let limit, limit > 0, let remaining {
                percentage = min(100, max(0, Double(remaining) / Double(limit) * 100))
            } else {
                percentage = -1
            }

            models.append(ModelQuota(
                name: "warp-usage",
                percentage: percentage,
                resetTime: Self.normalizedResetTime(info.nextRefreshTime),
                presentation: isUnlimited ? .status(text: "不限额") : nil,
                used: used,
                limit: limit,
                remaining: remaining
            ))

            var allGrants: [WarpQuotaResponse.WarpBonusGrant] = []

            for workspace in workspaces {
                if let grants = workspace.bonusGrantsInfo?.grants {
                    allGrants.append(contentsOf: grants)
                }
            }

            allGrants.append(contentsOf: userBonusGrants)

            for (index, grant) in allGrants.enumerated() {
                // 到期时间决定赠额是否还能使用；接口即使保留历史剩余数，也不能继续计入可用额度。
                let expirationDate = Self.parseResetDate(grant.expiration)
                if let expirationDate, expirationDate <= now { continue }
                guard let granted = grant.requestCreditsGranted,
                      let remainingCredits = grant.requestCreditsRemaining,
                      granted > 0 else {
                    continue
                }

                let bonusPercentage: Double
                if granted > 0 {
                    bonusPercentage = min(100, max(0, Double(remainingCredits) / Double(granted) * 100))
                } else {
                    bonusPercentage = 0
                }

                let bonusResetTime = expirationDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""

                let _ = grant.userFacingMessage?.components(separatedBy: ".").first ?? grant.reason ?? "bonus-\(index)"

                models.append(ModelQuota(
                    name: "warp-bonus-\(index)",
                    percentage: bonusPercentage,
                    resetTime: bonusResetTime,
                    used: granted - remainingCredits,
                    limit: granted,
                    remaining: remainingCredits,
                    tooltip: grant.userFacingMessage
                ))
            }

            return ProviderQuotaData(models: models, lastUpdated: Date())
        }
    }

    private nonisolated static func parseResetDate(_ timeString: String?) -> Date? {
        guard let timeString else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: timeString) ?? ISO8601DateFormatter().date(from: timeString)
    }

    private nonisolated static func normalizedResetTime(_ value: String?) -> String {
        parseResetDate(value).map { ISO8601DateFormatter().string(from: $0) } ?? ""
    }
}
