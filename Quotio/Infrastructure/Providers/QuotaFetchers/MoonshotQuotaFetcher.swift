//
//  MoonshotQuotaFetcher.swift
//  Quotio
//
//  Fetches balance and quota information from Moonshot / Kimi API (/v1/users/me/balance).
//  Uses API key authentication stored in CustomProviderService.
//

import Foundation

// MARK: - API Response Models

nonisolated struct MoonshotBalanceResponse: Codable, Sendable {
    let code: Int?
    let status: Bool?
    let message: String?
    let data: MoonshotBalanceData?
    let error: MoonshotErrorPayload?

    enum CodingKeys: String, CodingKey {
        case code, status, message, data, error
    }
}

nonisolated struct MoonshotErrorPayload: Codable, Sendable {
    let message: String?
    let type: String?
    let code: String?
}

nonisolated struct MoonshotBalanceData: Codable, Sendable {
    let availableBalance: Double?
    let voucherBalance: Double?
    let cashBalance: Double?

    enum CodingKeys: String, CodingKey {
        case availableBalance = "available_balance"
        case voucherBalance = "voucher_balance"
        case cashBalance = "cash_balance"
    }

    init(
        availableBalance: Double? = nil,
        voucherBalance: Double? = nil,
        cashBalance: Double? = nil
    ) {
        self.availableBalance = availableBalance
        self.voucherBalance = voucherBalance
        self.cashBalance = cashBalance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableBalance = Self.decodeDouble(from: container, key: .availableBalance)
        voucherBalance = Self.decodeDouble(from: container, key: .voucherBalance)
        cashBalance = Self.decodeDouble(from: container, key: .cashBalance)
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

actor MoonshotQuotaFetcher {
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
        let balanceResponse = try decoder.decode(MoonshotBalanceResponse.self, from: data)

        if let error = balanceResponse.error, let message = error.message {
            throw QuotaFetchError.apiErrorMessage(message)
        }

        guard let balanceData = balanceResponse.data else {
            throw QuotaFetchError.apiErrorMessage(balanceResponse.message ?? "Kimi quota unavailable")
        }

        let isGlobal = baseURL.lowercased().contains("moonshot.ai")
        return Self.mapQuotaData(balanceData, isGlobal: isGlobal)
    }

    nonisolated static func balanceEndpoint(from baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return URL(string: "https://api.moonshot.cn/v1/users/me/balance")
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix("/v1") {
            return URL(string: trimmed + "/users/me/balance")
        } else {
            return URL(string: trimmed + "/v1/users/me/balance")
        }
    }

    nonisolated static func mapQuotaData(_ data: MoonshotBalanceData, isGlobal: Bool = false) -> ProviderQuotaData {
        let unit: QuotaMetricUnit = isGlobal ? .usd : .cny
        var models: [ModelQuota] = []

        if let available = data.availableBalance {
            models.append(ModelQuota(
                name: "kimi-balance",
                percentage: -1,
                resetTime: "",
                presentation: .amount(value: available, unit: unit, semantics: .balance),
                sourceDisplayName: "quota.metric.balance".localizedStatic()
            ))
        }

        if let cash = data.cashBalance, cash > 0,
           let voucher = data.voucherBalance, voucher > 0 {
            models.append(ModelQuota(
                name: "kimi-cash",
                percentage: -1,
                resetTime: "",
                presentation: .amount(value: cash, unit: unit, semantics: .balance),
                sourceDisplayName: "quota.metric.cashBalance".localizedStatic()
            ))
        }

        if let voucher = data.voucherBalance, voucher > 0 {
            models.append(ModelQuota(
                name: "kimi-voucher",
                percentage: -1,
                resetTime: "",
                presentation: .amount(value: voucher, unit: unit, semantics: .balance),
                sourceDisplayName: "quota.metric.voucherBalance".localizedStatic()
            ))
        }

        return ProviderQuotaData(models: models, lastUpdated: Date(), planType: nil)
    }

    /// Stable identity for Moonshot (Kimi) custom provider accounts.
    nonisolated static func quotaAccountKey(providerID: UUID, apiKeyID: UUID) -> String {
        "moonshot:\(providerID.uuidString.lowercased()):\(apiKeyID.uuidString.lowercased())"
    }

    /// Fetch all quotas for enabled Moonshot custom providers.
    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        let providers = await getMoonshotProviders()
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

    private func getMoonshotProviders() async -> [CustomProvider] {
        await MainActor.run {
            CustomProviderService.shared.providers
                .filter { $0.type == .moonshotCompatibility && $0.isEnabled }
        }
    }
}
