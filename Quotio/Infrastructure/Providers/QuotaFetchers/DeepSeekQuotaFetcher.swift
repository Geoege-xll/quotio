//
//  DeepSeekQuotaFetcher.swift
//  Quotio
//
//  Fetches balance and quota information from DeepSeek API (/user/balance).
//  Uses API key authentication stored in CustomProviderService.
//

import Foundation

// MARK: - API Response Models

nonisolated struct DeepSeekBalanceResponse: Codable, Sendable {
    let isAvailable: Bool?
    let balanceInfos: [DeepSeekBalanceInfo]?
    let error: DeepSeekErrorPayload?

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
        case error
    }
}

nonisolated struct DeepSeekErrorPayload: Codable, Sendable {
    let message: String?
    let type: String?
    let code: String?
}

nonisolated struct DeepSeekBalanceInfo: Codable, Sendable {
    let currency: String?
    let totalBalance: Double?
    let grantedBalance: Double?
    let toppedUpBalance: Double?

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }

    init(
        currency: String? = nil,
        totalBalance: Double? = nil,
        grantedBalance: Double? = nil,
        toppedUpBalance: Double? = nil
    ) {
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currency = try? container.decodeIfPresent(String.self, forKey: .currency)
        totalBalance = Self.decodeDouble(from: container, key: .totalBalance)
        grantedBalance = Self.decodeDouble(from: container, key: .grantedBalance)
        toppedUpBalance = Self.decodeDouble(from: container, key: .toppedUpBalance)
    }

    private static func decodeDouble(from container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let str = try? container.decodeIfPresent(String.self, forKey: key), let value = Double(str) {
            return value
        }
        return nil
    }
}

// MARK: - Quota Fetcher

actor DeepSeekQuotaFetcher {
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

    /// Fetch quota and balance for a single API key
    func fetchQuota(apiKey: String, baseURL: String) async throws -> ProviderQuotaData {
        guard let endpointURL = Self.balanceEndpoint(from: baseURL) else {
            throw QuotaFetchError.invalidURL
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

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
        let balanceResponse = try decoder.decode(DeepSeekBalanceResponse.self, from: data)

        if let error = balanceResponse.error, let message = error.message {
            throw QuotaFetchError.apiErrorMessage(message)
        }

        return Self.mapQuotaData(balanceResponse)
    }

    nonisolated static func balanceEndpoint(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let host = components.host else {
            return URL(string: "https://api.deepseek.com/user/balance")
        }
        var root = scheme + "://" + host
        if let port = components.port { root += ":\(port)" }
        return URL(string: root + "/user/balance")
    }

    nonisolated static func mapQuotaData(_ response: DeepSeekBalanceResponse) -> ProviderQuotaData {
        var models: [ModelQuota] = []
        var currencies = Set<String>()
        // 余额接口返回多个币种桶；每个桶独立展示，不能只取 first，也不能跨币种相加。
        // 指标身份包含币种且顺序固定，响应调换顺序不会把人民币历史或菜单读数绑定到美元。
        for info in (response.balanceInfos ?? []).sorted(by: { ($0.currency ?? "") < ($1.currency ?? "") }) {
            let currency = info.currency?.uppercased() ?? ""
            guard ["CNY", "USD"].contains(currency), currencies.insert(currency).inserted else { continue }
            let unit: QuotaMetricUnit = currency == "USD" ? .usd : .cny
            let suffix = "-" + currency.lowercased()
            if let total = info.totalBalance {
                models.append(ModelQuota(name: "deepseek-balance" + suffix, percentage: -1, resetTime: "",
                    presentation: .amount(value: total, unit: unit, semantics: .balance),
                    sourceDisplayName: "quota.metric.balance".localizedStatic()))
            }
            if let toppedUp = info.toppedUpBalance, toppedUp > 0,
               let granted = info.grantedBalance, granted > 0 {
                models.append(ModelQuota(name: "deepseek-topped-up" + suffix, percentage: -1, resetTime: "",
                    presentation: .amount(value: toppedUp, unit: unit, semantics: .balance),
                    sourceDisplayName: "quota.metric.cashBalance".localizedStatic()))
            }
            if let granted = info.grantedBalance, granted > 0 {
                models.append(ModelQuota(name: "deepseek-granted" + suffix, percentage: -1, resetTime: "",
                    presentation: .amount(value: granted, unit: unit, semantics: .balance),
                    sourceDisplayName: "quota.metric.grantedBalance".localizedStatic()))
            }
        }

        let planType = response.isAvailable == false
            ? "deepseek.status.unavailable".localizedStatic()
            : nil

        return ProviderQuotaData(models: models, lastUpdated: Date(), planType: planType)
    }

    /// Stable identity for DeepSeek custom provider accounts.
    nonisolated static func quotaAccountKey(providerID: UUID, apiKeyID: UUID) -> String {
        "deepseek:\(providerID.uuidString.lowercased()):\(apiKeyID.uuidString.lowercased())"
    }

    /// Fetch all quotas for enabled DeepSeek custom providers.
    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        let providers = await getDeepSeekProviders()
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

    private func getDeepSeekProviders() async -> [CustomProvider] {
        await MainActor.run {
            CustomProviderService.shared.providers
                .filter { $0.type == .deepseekCompatibility && $0.isEnabled }
        }
    }
}
