//
//  GLMQuotaFetcher.swift
//  Quotio
//
//  Fetches quota information from GLM (BigModel) API.
//  Uses API key authentication stored in CustomProviderService.
//

import Foundation

// MARK: - API Response Models

nonisolated struct GLMQuotaResponse: Codable, Sendable {
    let code: Int?
    let msg: String?
    let data: GLMQuotaData?
    let success: Bool?
}

nonisolated struct GLMQuotaData: Codable, Sendable {
    let limits: [GLMLimit]
}

nonisolated struct GLMSubscriptionResponse: Codable, Sendable {
    let data: [GLMSubscription]?
}

nonisolated struct GLMSubscription: Codable, Sendable {
    let productName: String?
}

nonisolated struct GLMLimit: Codable, Sendable {
    let type: String?
    let name: String?
    let unit: Double?
    let number: Double?
    let usage: Double?
    let currentValue: Double?
    let remaining: Double?
    let percentage: Double?
    let usageDetails: [GLMUsageDetail]?
    let nextResetTime: Double?

    enum CodingKeys: String, CodingKey {
        case type, name, unit, number, usage
        case currentValue = "currentValue"
        case remaining, percentage
        case usageDetails = "usageDetails"
        case nextResetTime = "nextResetTime"
    }

    init(
        type: String,
        unit: Int? = nil,
        number: Int? = nil,
        usage: Int? = nil,
        currentValue: Int? = nil,
        remaining: Int? = nil,
        percentage: Double? = nil,
        usageDetails: [GLMUsageDetail]? = nil,
        nextResetTime: Int64? = nil
    ) {
        self.type = type
        name = nil
        self.unit = unit.map(Double.init)
        self.number = number.map(Double.init)
        self.usage = usage.map(Double.init)
        self.currentValue = currentValue.map(Double.init)
        self.remaining = remaining.map(Double.init)
        self.percentage = percentage
        self.usageDetails = usageDetails
        self.nextResetTime = nextResetTime.map(Double.init)
    }
}

nonisolated struct GLMUsageDetail: Codable, Sendable {
    let modelCode: String?
    let usage: Double?

    enum CodingKeys: String, CodingKey {
        case modelCode = "modelCode"
        case usage
    }
}

// MARK: - Quota Fetcher

actor GLMQuotaFetcher {
    private var session: URLSession

    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    /// Fetch quota for a single API key
    func fetchQuota(apiKey: String, baseURL: String) async throws -> ProviderQuotaData {
        guard let rootURL = Self.apiRoot(from: baseURL),
              let quotaURL = URL(string: rootURL + "/api/monitor/usage/quota/limit") else {
            throw QuotaFetchError.invalidURL
        }

        async let quotaResult = fetch(apiKey: apiKey, url: quotaURL)
        async let subscriptionName = fetchSubscriptionName(apiKey: apiKey, rootURL: rootURL)
        let (data, httpResponse) = try await quotaResult

        guard 200...299 ~= httpResponse.statusCode else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return await MainActor.run { ProviderQuotaData(isForbidden: true) }
            }
            throw QuotaFetchError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let quotaResponse = try decoder.decode(GLMQuotaResponse.self, from: data)

        guard quotaResponse.success != false,
              quotaResponse.code.map({ $0 == 200 }) ?? true,
              let responseData = quotaResponse.data else {
            throw QuotaFetchError.apiErrorMessage(quotaResponse.msg ?? "Z.ai quota unavailable")
        }

        let planName = await subscriptionName
        return Self.mapQuotaData(responseData, planName: planName)
    }

    private func fetch(apiKey: String, url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuotaFetchError.invalidResponse
        }
        return (data, httpResponse)
    }

    private func fetchSubscriptionName(apiKey: String, rootURL: String) async -> String? {
        guard let url = URL(string: rootURL + "/api/biz/subscription/list"),
              let (data, response) = try? await fetch(apiKey: apiKey, url: url),
              200...299 ~= response.statusCode else {
            return nil
        }
        guard let value = (try? JSONDecoder().decode(GLMSubscriptionResponse.self, from: data))?
            .data?.first?.productName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    nonisolated static func apiRoot(from baseURL: String) -> String? {
        guard let components = URLComponents(string: baseURL),
              let scheme = components.scheme,
              let host = components.host else { return nil }
        var root = scheme + "://" + host
        if let port = components.port { root += ":\(port)" }
        return root
    }

    nonisolated static func mapQuotaData(_ data: GLMQuotaData, planName: String?) -> ProviderQuotaData {
        var models: [ModelQuota] = []

        for limit in data.limits {
            let resetTime = limit.nextResetTime.map {
                ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0 / 1000))
            } ?? ""
            let kind = limit.type ?? limit.name

            if (kind == "TOKENS_LIMIT" || kind == "CREDIT_LIMIT"),
               let percentage = limit.percentage,
               let unit = limit.unit,
               let number = limit.number,
               let windowName = tokenWindowName(unit: unit, number: number) {
                models.append(ModelQuota(
                    name: windowName,
                    percentage: max(0, min(100, 100 - percentage)),
                    resetTime: resetTime
                ))
            } else if kind == "TIME_LIMIT",
                      let used = limit.currentValue,
                      let quotaLimit = limit.usage,
                      used >= 0,
                      quotaLimit >= 0 {
                let remainingPercent = quotaLimit > 0 ? max(0, min(100, (quotaLimit - used) / quotaLimit * 100)) : 0
                models.append(ModelQuota(
                    name: "zai-web-searches",
                    percentage: remainingPercent,
                    resetTime: resetTime,
                    presentation: .progress(
                        used: used,
                        limit: quotaLimit,
                        unit: .searches
                    ),
                    used: Int(used),
                    limit: Int(quotaLimit)
                ))
            }
        }

        return ProviderQuotaData(models: models, lastUpdated: Date(), planType: planName)
    }

    private nonisolated static func tokenWindowName(unit: Double, number: Double) -> String? {
        guard number > 0 else { return nil }
        switch unit {
        case 3:
            return number < 24 ? "zai-session" : "zai-daily"
        case 4:
            if number <= 1 { return "zai-daily" }
            return number < 28 ? "zai-weekly" : "zai-monthly"
        case 5:
            return "zai-monthly"
        case 6:
            return number < 4 ? "zai-weekly" : "zai-monthly"
        default: return nil
        }
    }

    /// 配额身份仅由配置和密钥条目的稳定 UUID 组成，不包含密钥内容。
    /// 同名配置、配置改名和多个密钥并发返回都不会再覆盖其他账号的快照。
    nonisolated static func quotaAccountKey(providerID: UUID, apiKeyID: UUID) -> String {
        "glm:\(providerID.uuidString.lowercased()):\(apiKeyID.uuidString.lowercased())"
    }

    /// 获取所有启用配置中的独立账号额度，显示名称与内部账号身份分离。
    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        // Get providers from CustomProviderService
        let providers = await getGlmProviders()

        var results: [String: ProviderQuotaData] = [:]

        await withTaskGroup(of: (String, ProviderQuotaData?).self) { group in
            for provider in providers {
                for (index, apiKeyEntry) in provider.apiKeys.enumerated() {
                    group.addTask {
                        do {
                            var quota = try await self.fetchQuota(
                                apiKey: apiKeyEntry.apiKey,
                                baseURL: provider.baseURL
                            )
                            // 序号仅用于界面辨认；实际查找始终使用 UUID，密钥重排不会串号。
                            quota.accountDisplayName = provider.apiKeys.count > 1
                                ? "\(provider.name) · \(index + 1)"
                                : provider.name
                            return (Self.quotaAccountKey(
                                providerID: provider.id,
                                apiKeyID: apiKeyEntry.id
                            ), quota)
                        } catch {
                            return ("", nil)
                        }
                    }
                }
            }

            for await (key, quota) in group {
                if !key.isEmpty, let quota = quota {
                    results[key] = quota
                }
            }
        }

        return results
    }

    /// Get GLM providers from CustomProviderService
    private func getGlmProviders() async -> [CustomProvider] {
        // Access CustomProviderService on main actor
        await MainActor.run {
            CustomProviderService.shared.providers
                .filter { $0.type == .glmCompatibility && $0.isEnabled }
        }
    }
}
