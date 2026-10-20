//
//  MainstreamQuotaFetcherTests.swift
//  QuotioTests
//

import XCTest
import Yams
@testable import QuotioPlus

@MainActor
final class MainstreamQuotaFetcherTests: XCTestCase {

    // MARK: - DeepSeek Quota Tests

    func testDeepSeekBalanceMappingCNY() throws {
        let json = """
        {
            "is_available": true,
            "balance_infos": [
                {
                    "currency": "CNY",
                    "total_balance": "25.50",
                    "granted_balance": "5.50",
                    "topped_up_balance": "20.00"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: json)
        let quotaData = DeepSeekQuotaFetcher.mapQuotaData(response)

        XCTAssertEqual(quotaData.models.count, 3)

        let balanceModel = try XCTUnwrap(quotaData.models.first { $0.name == "deepseek-balance-cny" })
        XCTAssertTrue(balanceModel.isStandaloneMetric)
        XCTAssertEqual(balanceModel.displayName, "quota.metric.balance".localizedStatic())
        if case .amount(let value, let unit, let semantics) = balanceModel.presentation {
            XCTAssertEqual(value, 25.50)
            XCTAssertEqual(unit, .cny)
            XCTAssertEqual(semantics, .balance)
        } else {
            XCTFail("Expected .amount presentation")
        }

        let toppedUpModel = try XCTUnwrap(quotaData.models.first { $0.name == "deepseek-topped-up-cny" })
        if case .amount(let value, let unit, _) = toppedUpModel.presentation {
            XCTAssertEqual(value, 20.00)
            XCTAssertEqual(unit, .cny)
        } else {
            XCTFail("Expected .amount presentation")
        }

        let grantedModel = try XCTUnwrap(quotaData.models.first { $0.name == "deepseek-granted-cny" })
        if case .amount(let value, let unit, _) = grantedModel.presentation {
            XCTAssertEqual(value, 5.50)
            XCTAssertEqual(unit, .cny)
        } else {
            XCTFail("Expected .amount presentation")
        }
    }

    func testDeepSeekBalanceMappingNumericAndUSD() throws {
        let json = """
        {
            "is_available": true,
            "balance_infos": [
                {
                    "currency": "USD",
                    "total_balance": 15.75,
                    "granted_balance": 0.0,
                    "topped_up_balance": 15.75
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: json)
        let quotaData = DeepSeekQuotaFetcher.mapQuotaData(response)

        // granted is 0, so only total balance should be included
        XCTAssertEqual(quotaData.models.count, 1)

        let balanceModel = try XCTUnwrap(quotaData.models.first { $0.name == "deepseek-balance-usd" })
        if case .amount(let value, let unit, _) = balanceModel.presentation {
            XCTAssertEqual(value, 15.75)
            XCTAssertEqual(unit, .usd)
        } else {
            XCTFail("Expected .amount presentation with USD")
        }
    }

    func testDeepSeekEndpointResolution() {
        let url1 = DeepSeekQuotaFetcher.balanceEndpoint(from: "https://api.deepseek.com")
        XCTAssertEqual(url1?.absoluteString, "https://api.deepseek.com/user/balance")

        let url2 = DeepSeekQuotaFetcher.balanceEndpoint(from: "https://api.deepseek.com/v1")
        XCTAssertEqual(url2?.absoluteString, "https://api.deepseek.com/user/balance")

        let url3 = DeepSeekQuotaFetcher.balanceEndpoint(from: "https://custom.deepseek.proxy:8443/v1/")
        XCTAssertEqual(url3?.absoluteString, "https://custom.deepseek.proxy:8443/user/balance")
    }

    func testDeepSeekAccountKey() {
        let providerID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let keyID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let key = DeepSeekQuotaFetcher.quotaAccountKey(providerID: providerID, apiKeyID: keyID)
        XCTAssertEqual(key, "deepseek:11111111-2222-3333-4444-555555555555:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    // MARK: - Moonshot / Kimi Quota Tests

    func testMoonshotBalanceMappingCNY() throws {
        let json = """
        {
            "code": 0,
            "status": true,
            "message": "success",
            "data": {
                "available_balance": "88.80",
                "voucher_balance": "18.80",
                "cash_balance": "70.00"
            }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(MoonshotBalanceResponse.self, from: json)
        let data = try XCTUnwrap(response.data)
        let quotaData = MoonshotQuotaFetcher.mapQuotaData(data, isGlobal: false)

        XCTAssertEqual(quotaData.models.count, 3)

        let balanceModel = try XCTUnwrap(quotaData.models.first { $0.name == "kimi-balance" })
        XCTAssertTrue(balanceModel.isStandaloneMetric)
        XCTAssertEqual(balanceModel.displayName, "quota.metric.balance".localizedStatic())
        if case .amount(let value, let unit, let semantics) = balanceModel.presentation {
            XCTAssertEqual(value, 88.80)
            XCTAssertEqual(unit, .cny)
            XCTAssertEqual(semantics, .balance)
        } else {
            XCTFail("Expected .amount presentation")
        }

        let cashModel = try XCTUnwrap(quotaData.models.first { $0.name == "kimi-cash" })
        if case .amount(let value, let unit, _) = cashModel.presentation {
            XCTAssertEqual(value, 70.00)
            XCTAssertEqual(unit, .cny)
        } else {
            XCTFail("Expected .amount presentation")
        }

        let voucherModel = try XCTUnwrap(quotaData.models.first { $0.name == "kimi-voucher" })
        if case .amount(let value, let unit, _) = voucherModel.presentation {
            XCTAssertEqual(value, 18.80)
            XCTAssertEqual(unit, .cny)
        } else {
            XCTFail("Expected .amount presentation")
        }
    }

    func testMoonshotBalanceMappingGlobalUSD() throws {
        let data = MoonshotBalanceData(availableBalance: 50.0, voucherBalance: 0, cashBalance: 50.0)
        let quotaData = MoonshotQuotaFetcher.mapQuotaData(data, isGlobal: true)

        XCTAssertEqual(quotaData.models.count, 1)
        let balanceModel = try XCTUnwrap(quotaData.models.first { $0.name == "kimi-balance" })
        if case .amount(let value, let unit, _) = balanceModel.presentation {
            XCTAssertEqual(value, 50.0)
            XCTAssertEqual(unit, .usd)
        } else {
            XCTFail("Expected .amount presentation with USD")
        }
    }

    func testMoonshotEndpointResolution() {
        let url1 = MoonshotQuotaFetcher.balanceEndpoint(from: "https://api.moonshot.cn/v1")
        XCTAssertEqual(url1?.absoluteString, "https://api.moonshot.cn/v1/users/me/balance")

        let url2 = MoonshotQuotaFetcher.balanceEndpoint(from: "https://api.moonshot.cn")
        XCTAssertEqual(url2?.absoluteString, "https://api.moonshot.cn/v1/users/me/balance")

        let url3 = MoonshotQuotaFetcher.balanceEndpoint(from: "https://api.moonshot.ai/v1/")
        XCTAssertEqual(url3?.absoluteString, "https://api.moonshot.ai/v1/users/me/balance")
    }

    func testMoonshotAccountKey() {
        let providerID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let keyID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let key = MoonshotQuotaFetcher.quotaAccountKey(providerID: providerID, apiKeyID: keyID)
        XCTAssertEqual(key, "moonshot:22222222-3333-4444-5555-666666666666:bbbbbbbb-cccc-dddd-eeee-ffffffffffff")
    }

    // MARK: - QuotaMetricUnit CNY Formatting

    func testQuotaMetricUnitCNYFormatting() {
        let unit = QuotaMetricUnit.cny
        let formatted = unit.format(12.5)
        XCTAssertTrue(formatted.contains("12.50") || formatted.contains("12.5"), "Formatted string should contain 12.50: \(formatted)")
        XCTAssertTrue(formatted.contains("¥") || formatted.contains("CN¥"), "Formatted string should contain CNY symbol: \(formatted)")
    }

    // MARK: - Legacy Owned Providers & Keys Resolution

    func testLegacyOwnedMainstreamProvidersResolution() throws {
        let deepseekID = UUID()
        let deepseekProvider = CustomProvider(
            id: deepseekID,
            name: "DeepSeek Primary",
            type: .deepseekCompatibility,
            apiKeys: [CustomAPIKeyEntry(apiKey: "sk-deepseek-test")]
        )

        let moonshotID = UUID()
        let moonshotProvider = CustomProvider(
            id: moonshotID,
            name: "Kimi Fast",
            type: .moonshotCompatibility,
            apiKeys: [CustomAPIKeyEntry(apiKey: "sk-moonshot-test")]
        )

        let minimaxID = UUID()
        let minimaxProvider = CustomProvider(
            id: minimaxID,
            name: "MiniMax Global",
            type: .minimaxCompatibility,
            apiKeys: [CustomAPIKeyEntry(apiKey: "sk-minimax-test")]
        )

        let legacyYAML = """
        # Custom Providers (managed by Quotio)
        openai-compatibility:
          - name: DeepSeek Primary
            api-key-entries:
              - api-key: sk-deepseek-test
          - name: Kimi Fast
            api-key-entries:
              - api-key: sk-moonshot-test
          - name: MiniMax Global
            api-key-entries:
              - api-key: sk-minimax-test
        """

        let ownedKeys = CustomProviderService.shared.legacyOwnedKeys(in: legacyYAML)
        let openAIKeys = ownedKeys["openai-compatibility"] ?? []
        XCTAssertTrue(openAIKeys.contains("sk-deepseek-test"))
        XCTAssertTrue(openAIKeys.contains("sk-moonshot-test"))
        XCTAssertTrue(openAIKeys.contains("sk-minimax-test"))

        let managed = [deepseekProvider, moonshotProvider, minimaxProvider]
        let ownedIDs = CustomProviderService.shared.legacyOwnedProviderIDs(in: legacyYAML, managedProviders: managed)

        XCTAssertTrue(ownedIDs.contains(deepseekID), "DeepSeek provider ID should be identified as legacy owned")
        XCTAssertTrue(ownedIDs.contains(moonshotID), "Moonshot provider ID should be identified as legacy owned")
        XCTAssertTrue(ownedIDs.contains(minimaxID), "MiniMax provider ID should be identified as legacy owned")
    }
    func testDeepSeekMultipleCurrenciesKeepStableIdentitiesWhenOrderChanges() throws {
        let infos = [DeepSeekBalanceInfo(currency: "CNY", totalBalance: 0),
                     DeepSeekBalanceInfo(currency: "USD", totalBalance: 12.5)]
        let first = DeepSeekQuotaFetcher.mapQuotaData(.init(isAvailable: true, balanceInfos: infos, error: nil))
        let reversed = DeepSeekQuotaFetcher.mapQuotaData(.init(isAvailable: true, balanceInfos: Array(infos.reversed()), error: nil))
        XCTAssertEqual(first.models.map(\.name), ["deepseek-balance-cny", "deepseek-balance-usd"])
        XCTAssertEqual(first.models.map(\.name), reversed.models.map(\.name))
        for model in first.models {
            guard case .amount(let value, let unit, _) = model.presentation else { return XCTFail("必须保留金额指标") }
            XCTAssertEqual(value, model.name.hasSuffix("usd") ? 12.5 : 0)
            XCTAssertEqual(unit, model.name.hasSuffix("usd") ? .usd : .cny)
        }
    }

}
