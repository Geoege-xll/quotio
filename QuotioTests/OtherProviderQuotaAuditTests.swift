import XCTest
@testable import Quotio

/// 全部使用固定服务端响应，不读取本机凭据、不访问真实账号，用于保护不同提供方的额度语义。
@MainActor
final class OtherProviderQuotaAuditTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testGrokSnakeCaseAndProductUsageDoNotRequireResetTime() throws {
        let quota = try XCTUnwrap(GrokQuotaMapper.mapBilling(data(#"{"config":{"credit_usage_percent":"40","product_usage":[{"product":"grok-code","usage_percent":75}]}}"#), plan: nil))
        XCTAssertEqual(quota.models.first(where: { $0.name == "grok-weekly" })?.percentage, 60)
        XCTAssertEqual(quota.models.first(where: { $0.name == "grok-product-grok-code" })?.percentage, 25)
        XCTAssertEqual(quota.models.first?.resetTime, "")
    }

    func testGrokMissingWeeklyPercentageStaysUnknown() throws {
        let quota = try XCTUnwrap(GrokQuotaMapper.mapBilling(data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2030-01-01T00:00:00Z"}}}"#), plan: nil))
        XCTAssertEqual(quota.models.first?.percentage, -1)
    }

    func testGrokCombinesWeeklyMonthlyAndOnDemandBilling() throws {
        let weekly = data(#"{"config":{"creditUsagePercent":25}}"#)
        let monthly = data(#"{"monthly_limit":10000,"used":12000,"on_demand_cap":5000,"billing_period_end":"2030-01-01T00:00:00Z"}"#)
        let quota = try XCTUnwrap(GrokQuotaMapper.mapBillingResponses(weekly: weekly, monthly: monthly, plan: nil))
        XCTAssertEqual(quota.models.first(where: { $0.name == "grok-weekly" })?.percentage, 75)
        XCTAssertEqual(quota.models.first(where: { $0.name == "grok-monthly-included" })?.percentage, 0)
        let extra = try XCTUnwrap(quota.models.first(where: { $0.name == "grok-extra-usage" }))
        XCTAssertEqual(extra.percentage, 60)
        XCTAssertEqual(extra.presentation, .progress(used: 20, limit: 50, unit: .usd))
    }

    func testGrokKeepsMonthlyDataWhenWeeklyEndpointFails() throws {
        let quota = try XCTUnwrap(GrokQuotaMapper.mapBillingResponses(weekly: nil, monthly: data(#"{"monthlyLimit":10000,"used":2000}"#), plan: nil))
        XCTAssertEqual(quota.models.first?.percentage, 80)
    }

    func testGrokMalformedNumericValuesDoNotBecomeQuota() throws {
        XCTAssertNil(GrokQuotaMapper.mapBilling(data(#"{"credit_usage_percent":true}"#), plan: nil))
        XCTAssertNil(GrokQuotaMapper.mapBilling(data(#"{"credit_usage_percent":"NaN"}"#), plan: nil))
    }

    private func openRouter(_ json: String) throws -> ProviderQuotaData {
        try XCTUnwrap(OpenRouterQuotaMapper.map(
            credits: OpenRouterEndpointResult(data: nil, statusCode: 503),
            key: OpenRouterEndpointResult(data: data(json), statusCode: 200)
        ))
    }

    func testOpenRouterPrefersRemainingOverLifetimeUsage() throws {
        let quota = try openRouter(#"{"data":{"limit":100,"limit_remaining":80,"limit_reset":"monthly","usage":250,"usage_monthly":20}}"#)
        let model = try XCTUnwrap(quota.models.first(where: { $0.name == "openrouter-key-limit" }))
        XCTAssertEqual(model.percentage, 80)
        XCTAssertEqual(model.presentation, .progress(used: 20, limit: 100, unit: .usd))
    }

    func testOpenRouterFallbackUsesMatchingCycleAndBYOK() throws {
        let quota = try openRouter(#"{"data":{"limit":100,"limit_reset":"monthly","usage":250,"usage_monthly":20,"include_byok_in_limit":true,"byok_usage_monthly":10}}"#)
        XCTAssertEqual(quota.models.first(where: { $0.name == "openrouter-key-limit" })?.percentage, 70)
    }

    func testOpenRouterMissingCurrentCycleUsageStaysUnknown() throws {
        let quota = try openRouter(#"{"data":{"limit":100,"limit_reset":"monthly","usage":250}}"#)
        XCTAssertEqual(quota.models.first(where: { $0.name == "openrouter-key-limit" })?.percentage, -1)
    }

    private var cursorAuth: CursorAuthData {
        CursorAuthData(accessToken: nil, refreshToken: nil, email: "fixture@example.com", membershipType: nil, subscriptionStatus: nil, signUpType: nil)
    }

    func testCursorDerivesRemainingFromUsedWhenRemainingIsMissing() throws {
        let info = try XCTUnwrap(CursorQuotaFetcher.parseUsageSummaryResponse(data(#"{"individualUsage":{"plan":{"enabled":true,"used":20,"limit":100}}}"#), authData: cursorAuth))
        XCTAssertEqual(info.planUsage?.remainingPercentage, 80)
        XCTAssertNil(info.planUsage?.remaining)
    }

    func testCursorUsesPercentageWithoutAssumingMissingLimitIsUnlimited() throws {
        let info = try XCTUnwrap(CursorQuotaFetcher.parseUsageSummaryResponse(data(#"{"individualUsage":{"plan":{"enabled":true,"totalPercentUsed":70}}}"#), authData: cursorAuth))
        XCTAssertEqual(info.planUsage?.remainingPercentage, 30)
        XCTAssertNil(info.planUsage?.limit)
    }

    func testCursorMissingUsageAndOnDemandLimitRemainUnknown() throws {
        let info = try XCTUnwrap(CursorQuotaFetcher.parseUsageSummaryResponse(data(#"{"individualUsage":{"plan":{"enabled":true},"onDemand":{"enabled":true,"used":10}}}"#), authData: cursorAuth))
        XCTAssertEqual(info.planUsage?.remainingPercentage, -1)
        XCTAssertEqual(info.onDemandUsage?.remainingPercentage, -1)
    }

    func testCursorAcceptsResetDateWithoutFractionalSeconds() throws {
        let info = try XCTUnwrap(CursorQuotaFetcher.parseUsageSummaryResponse(data(#"{"billingCycleEnd":"2030-01-01T00:00:00Z"}"#), authData: cursorAuth))
        XCTAssertNotNil(info.billingCycleEnd)
    }

    func testKiroEmptyResponseDoesNotClaimFullQuota() async throws {
        let response = try JSONDecoder().decode(KiroUsageResponse.self, from: data(#"{}"#))
        let quota = await KiroQuotaFetcher().convertToQuotaData(response, planType: "Standard", tokenExpiresAt: nil)
        XCTAssertEqual(quota.models.first?.percentage, -1)
    }

    func testKiroMissingUsageDoesNotClaimFullQuota() async throws {
        let response = try JSONDecoder().decode(KiroUsageResponse.self, from: data(#"{"usageBreakdownList":[{"usageLimit":100}]}"#))
        let quota = await KiroQuotaFetcher().convertToQuotaData(response, planType: "Standard", tokenExpiresAt: nil)
        XCTAssertEqual(quota.models.first?.percentage, -1)
    }

    func testKiroPreservesZeroUsageAndPerBucketReset() async throws {
        let response = try JSONDecoder().decode(KiroUsageResponse.self, from: data(#"{"usageBreakdownList":[{"currentUsage":0,"usageLimit":100,"nextDateReset":1893456000}]}"#))
        let quota = await KiroQuotaFetcher().convertToQuotaData(response, planType: "Standard", tokenExpiresAt: nil)
        XCTAssertEqual(quota.models.first?.percentage, 100)
        XCTAssertEqual(quota.models.first?.resetTime, "2030-01-01T00:00:00Z")
    }

    private var traeAuth: TraeAuthData {
        TraeAuthData(accessToken: nil, refreshToken: nil, email: "fixture@example.com", userId: nil, apiHost: nil, username: nil)
    }

    func testTraeDoesNotResurrectInactiveEntitlement() async {
        let info = await TraeQuotaFetcher().parseQuotaResponse(data(#"{"user_entitlement_pack_list":[{"status":0,"entitlement_base_info":{"quota":{"premium_model_fast_request_limit":100}},"usage":{"premium_model_fast_amount":20}}]}"#), authData: traeAuth)
        XCTAssertNil(info)
    }

    func testTraePreservesMissingUsageInsteadOfInventingZero() async throws {
        let result = await TraeQuotaFetcher().parseQuotaResponse(data(#"{"user_entitlement_pack_list":[{"status":1,"entitlement_base_info":{"quota":{"premium_model_fast_request_limit":100}}}]}"#), authData: traeAuth)
        let info = try XCTUnwrap(result)
        XCTAssertEqual(info.premiumFastLimit, 100)
        XCTAssertNil(info.premiumFastUsed)
    }

    func testWarpFiltersExpiredGrantsAndAcceptsBothISOFormats() async throws {
        let response = try JSONDecoder().decode(WarpQuotaResponse.self, from: data(#"{"data":{"user":{"user":{"requestLimitInfo":{"requestLimit":100,"requestsUsedSinceLastRefresh":20},"bonusGrants":[{"expiration":"2029-12-31T00:00:00Z","requestCreditsGranted":100,"requestCreditsRemaining":100},{"expiration":"2030-01-02T00:00:00.000Z","requestCreditsGranted":100,"requestCreditsRemaining":50}]}}}}"#))
        let quota = try await WarpQuotaFetcher().mapQuotaResponse(response, now: Date(timeIntervalSince1970: 1_893_456_000))
        XCTAssertEqual(quota.models.count, 2)
        XCTAssertEqual(quota.models.last?.percentage, 50)
        XCTAssertEqual(quota.models.last?.resetTime, "2030-01-02T00:00:00Z")
    }

    func testWarpIncompleteLimitDoesNotClaimQuotaExhaustion() async throws {
        let response = try JSONDecoder().decode(WarpQuotaResponse.self, from: data(#"{"data":{"user":{"user":{"requestLimitInfo":{"requestLimit":100}}}}}"#))
        let quota = try await WarpQuotaFetcher().mapQuotaResponse(response)
        XCTAssertEqual(quota.models.first?.percentage, -1)
    }

    func testCopilotIncompleteSnapshotFallsBackPerCategory() throws {
        let entitlement = try JSONDecoder().decode(CopilotEntitlement.self, from: data(#"{"quota_snapshots":{"chat":{}},"limited_user_quotas":{"chat":40,"completions":1000},"monthly_quotas":{"chat":50,"completions":2000}}"#))
        let quota = CopilotQuotaFetcher.mapEntitlement(entitlement)
        XCTAssertEqual(quota.models.first(where: { $0.name == "copilot-chat" })?.percentage, 80)
        XCTAssertEqual(quota.models.first(where: { $0.name == "copilot-completions" })?.percentage, 50)
    }

    func testCopilotMissingEntitlementDoesNotAssumeFreePlanLimit() throws {
        let entitlement = try JSONDecoder().decode(CopilotEntitlement.self, from: data(#"{"quota_snapshots":{"premium_interactions":{"remaining":25}}}"#))
        XCTAssertEqual(CopilotQuotaFetcher.mapEntitlement(entitlement).models.first?.percentage, -1)
    }

    func testClineMalformedResetDoesNotDiscardValidWindows() async throws {
        let quota = try await ClinePassQuotaFetcher().parseQuota(data(#"{"success":true,"data":{"limits":[{"type":"five_hour","percentUsed":25,"resetsAt":"invalid"},{"type":"weekly","percentUsed":40,"resetsAt":"2030-01-01T00:00:00Z"}]}}"#))
        XCTAssertEqual(quota.models.map(\.percentage), [75, 60])
        XCTAssertEqual(quota.models.first?.resetTime, "")
    }

    func testFactoryUsesRelativeResetWhenAbsoluteEndIsMissing() throws {
        let response = try JSONDecoder().decode(FactoryDroidQuotaResponse.self, from: data(#"{"limits":{"standard":{"fiveHour":{"usedPercent":25,"secondsRemaining":3600}}}}"#))
        let quota = FactoryDroidQuotaMapper.map(response, now: Date(timeIntervalSince1970: 1_893_456_000))
        XCTAssertEqual(quota.models.first?.percentage, 75)
        XCTAssertEqual(quota.models.first?.resetTime, "2030-01-01T01:00:00Z")
    }
}
