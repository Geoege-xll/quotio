import XCTest
@testable import QuotioPlus

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

    func testGrokCPARetainsHTTPFailureAndKeepsQuotaFromTheOtherSuccessfulEndpoint() async throws {
        let file = try JSONDecoder().decode(AuthFile.self,
            from: data(#"{"name":"grok.json","provider":"grok","user_id":"fixture-user","auth_index":"grok-fixture"}"#))
        let denied = APICallResponse(statusCode: 403, header: nil, body: nil)
        let deniedFetcher = CPAQuotaFetcher(call: { _ in denied }, download: { _ in
            XCTFail("目录已包含 Grok 用户 ID")
            throw QuotaFetchError.invalidResponse
        })
        do {
            _ = try await deniedFetcher.fetch(file: file)
            XCTFail("两个接口的拒绝不能作为新额度发布")
        } catch QuotaFetchError.httpError(403) { }

        let partial = CPAQuotaFetcher(call: { request in
            request.url.hasSuffix("format=credits") ? denied
                : APICallResponse(statusCode: 200, header: nil, body: #"{"monthlyLimit":10000,"used":2000}"#)
        }, download: { _ in throw QuotaFetchError.invalidResponse })
        let quota = try await partial.fetch(file: file)
        XCTAssertEqual(quota.models.first(where: { $0.name == "grok-monthly-included" })?.percentage, 80)
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

    private var kiroCPACatalogRow: String {
        #"{"name":"kiro-exact.json","provider":"kiro","email":"fixture@example.invalid","user_id":"kiro-user","auth_index":"kiro-account-index"}"#
    }

    private var kiroCPAProfile: String { "arn:aws:codewhisperer:eu-central-1:000000000000:profile/FIXTURE-PROFILE" }

    private func kiroCPAFixture(credential: String, usageResponse: LifecycleHTTPState.Response) throws
        -> (file: AuthFile, fetcher: CPAQuotaFetcher, management: LifecycleHTTPState, usage: LifecycleHTTPState) {
        let row = kiroCPACatalogRow
        let file = try JSONDecoder().decode(AuthFile.self, from: data(row))
        let managementHost = "kiro-cpa-\(UUID().uuidString.lowercased()).invalid"
        let awsHost = "q.eu-central-1.amazonaws.com"
        let management = LifecycleHTTPState { request, _ in
            switch request.url?.path {
            case "/v8/management/credentials": return .reply(#"{"files":[\#(row)]}"#)
            case "/v8/management/credentials/download": return .reply(credential)
            default: return .fail(.badURL)
            }
        }
        let usage = LifecycleHTTPState { request, _ in
            request.url?.path == "/getUsageLimits" ? usageResponse : .fail(.badURL)
        }
        LifecycleHTTPProtocol.register(management, host: managementHost)
        LifecycleHTTPProtocol.register(usage, host: awsHost)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        let baseURL = ManagementAPIClient.managementURL(for: "http://\(managementHost)")
        let managementClient = ManagementAPIClient(baseURL: baseURL, authKey: "fixture-management", configuration: configuration)
        let session = URLSession(configuration: configuration)
        addTeardownBlock {
            await managementClient.invalidate()
            session.invalidateAndCancel()
            LifecycleHTTPProtocol.remove(host: managementHost)
            LifecycleHTTPProtocol.remove(host: awsHost)
        }
        return (file, CPAQuotaFetcher(client: managementClient, kiro: KiroQuotaFetcher(session: session)), management, usage)
    }

    func testKiroCPASupplementUsesExactlyOneCurrentProfileAndDoesNotUseOIDCRegion() async throws {
        let profile = kiroCPAProfile
        let f = try kiroCPAFixture(
            credential: #"{"type":"kiro","provider":"Google","access_token":"fixture-access","refresh_token":"unused-fixture","expires_at":"2099-01-01T00:00:00Z","profile_arn":"\#(profile)","region":"us-east-1","email":"fixture@example.invalid"}"#,
            usageResponse: .reply(#"{"userInfo":{"email":"fixture@example.invalid","userId":"kiro-user"},"usageBreakdownList":[{"currentUsage":20,"usageLimit":100}]}"#))

        let quota = try await f.fetcher.fetchSupplemental(file: f.file)

        XCTAssertEqual(quota.models.first?.percentage, 80)
        XCTAssertEqual(f.management.requests.map(\.url.path), ["/v8/management/credentials/download", "/v8/management/credentials"])
        let download = try XCTUnwrap(f.management.requests.first?.url)
        XCTAssertEqual(URLComponents(url: download, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "name", value: f.file.name)])
        XCTAssertEqual(f.usage.requestCount, 1)
        let request = try XCTUnwrap(f.usage.requests.first)
        XCTAssertEqual(request.url.host, "q.eu-central-1.amazonaws.com")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.authorization, "Bearer fixture-access")
        XCTAssertEqual(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "profileArn" }?.value, profile)
    }

    func testKiroCPASupplementRejectsExpiredCredentialAndUnverifiedProfileBeforeAWS() async throws {
        for (expiry, profile) in [("2000-01-01T00:00:00Z", kiroCPAProfile),
                                  ("2099-01-01T00:00:00Z", "arn:aws:codewhisperer:example.invalid:000000000000:profile/fake")] {
            let f = try kiroCPAFixture(
                credential: #"{"type":"kiro","access_token":"fixture-access","expires_at":"\#(expiry)","profile_arn":"\#(profile)"}"#,
                usageResponse: .fail(.badURL))
            do {
                _ = try await f.fetcher.fetchSupplemental(file: f.file)
                XCTFail("过期凭据或未知 profile 区域禁止出站")
            } catch QuotaFetchError.invalidResponse { }
            XCTAssertEqual(f.usage.requestCount, 0)
        }
    }

    func testKiroCPASupplementRejectsAnotherAWSUserAndDoesNotRetryRejectedToken() async throws {
        let profile = kiroCPAProfile
        let credential = #"{"type":"kiro","access_token":"fixture-access","refresh_token":"unused-fixture","expires_at":"2099-01-01T00:00:00Z","profile_arn":"\#(profile)"}"#
        let responses: [(LifecycleHTTPState.Response, Int?)] = [
            (.reply(#"{"userInfo":{"email":"fixture@example.invalid","userId":"different-user"},"usageBreakdownList":[{"currentUsage":20,"usageLimit":100}]}"#), nil),
            (.replyStatus("{}", 401), 401),
            (.replyStatus("{}", 429), 429),
        ]
        for (response, expectedStatus) in responses {
            let f = try kiroCPAFixture(credential: credential, usageResponse: response)
            do {
                _ = try await f.fetcher.fetchSupplemental(file: f.file)
                XCTFail("AWS 账号不符、鉴权或限流时，保留上次额度")
            } catch QuotaFetchError.invalidResponse {
                XCTAssertNil(expectedStatus)
            } catch QuotaFetchError.httpError(let actual) {
                XCTAssertEqual(actual, expectedStatus)
            }
            XCTAssertEqual(f.usage.requestCount, 1)
        }
    }

    func testKiroCPASupplementPreservesTimeoutAndRecognizesRequestCancellation() async throws {
        let profile = kiroCPAProfile
        let credential = #"{"type":"kiro","access_token":"fixture-access","expires_at":"2099-01-01T00:00:00Z","profile_arn":"\#(profile)"}"#
        for code in [URLError.Code.timedOut, .cancelled] {
            let f = try kiroCPAFixture(credential: credential, usageResponse: .fail(code))
            do {
                _ = try await f.fetcher.fetchSupplemental(file: f.file)
                XCTFail("Kiro 超时或取消不能作为新额度发布")
            } catch is CancellationError {
                XCTAssertEqual(code, .cancelled)
            } catch let error as URLError {
                XCTAssertEqual(code, .timedOut)
                XCTAssertEqual(error.code, .timedOut)
            }
            XCTAssertEqual(f.usage.requestCount, 1)
        }
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
