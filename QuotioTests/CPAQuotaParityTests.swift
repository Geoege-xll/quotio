import XCTest
@testable import Quotio

/// 按 EasyCLIProxyAPI 的公开响应形状构造离线样例，不依赖任何真实账号或在线请求。
final class CPAQuotaParityTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testAntigravitySnakeCaseUnnamedBucketsAndWrappedFractions() throws {
        let input = data(#"{"groups":[{"display_name":"Gemini","buckets":[{"window":"5h","remaining_fraction":{"val":0.35}},{"display_name":"Weekly Limit Remaining","remaining_fraction":"24%"},{"remainingFraction":0.1}]}]}"#)
        let models = try XCTUnwrap(AntigravityQuotaParser.summaryModels(from: input))
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models.map(\.percentage).sorted(), [10, 24, 35])
        XCTAssertEqual(models.first { $0.antigravityWindow == .weekly }?.percentage, 24)
        XCTAssertEqual(models.first { $0.antigravityWindow == .session }?.percentage, 35)
    }

    func testCodexKeepsFractionalPercentAndDoesNotMarkRateLimitAsForbidden() throws {
        let quota = try CodexUsageMapper.map(data: data(#"{"rate_limit":{"limit_reached":true,"primary_window":{"used_percent":0.63},"secondary_window":{"used_percent":100}}}"#))
        XCTAssertEqual(quota.models[0].percentage, 99.37, accuracy: 0.0001)
        XCTAssertEqual(quota.models[1].percentage, 0)
        XCTAssertFalse(quota.isForbidden)
    }

    func testCodexMonthReviewAndBothAdditionalWindowsArePreserved() throws {
        let quota = try CodexUsageMapper.map(data: data(#"{"rateLimit":{"primaryWindow":{"usedPercent":10,"limitWindowSeconds":18000},"secondaryWindow":{"usedPercent":20,"limitWindowSeconds":2592000}},"codeReviewRateLimit":{"primaryWindow":{"usedPercent":30}},"additionalRateLimits":[{"limitName":"Extra model","meteredFeature":"extra","rateLimit":{"primaryWindow":{"usedPercent":40},"secondaryWindow":{"usedPercent":50}}}]}"#))
        XCTAssertEqual(quota.models.count, 5)
        XCTAssertTrue(quota.models.contains { $0.name == "codex-monthly" && $0.percentage == 80 })
        XCTAssertTrue(quota.models.contains { $0.name == "codex-code-review-session" && $0.percentage == 70 })
        XCTAssertEqual(quota.models.filter { $0.name.hasPrefix("codex-extra") }.map(\.percentage), [60, 50])
    }

    func testCodexUnknownIsNotZeroAndRelativeResetSupportsReachedLimit() throws {
        let quota = try CodexUsageMapper.map(data: data(#"{"rate_limit":{"allowed":false,"primary_window":{"used_percent":true},"secondary_window":{"reset_after_seconds":3600}}}"#))
        XCTAssertEqual(quota.models.map(\.percentage), [-1, 0])
        XCTAssertFalse(quota.models[1].resetTime.isEmpty)
        XCTAssertThrowsError(try CodexUsageMapper.map(data: data("{}")))
    }

    func testClaudeModernFableAndAdditionalWeeklyScopes() throws {
        let quota = try ClaudeQuotaMapper.map(data: data(#"{"five_hour":{"utilization":0.44},"seven_day_oauth_apps":{"utilization":30},"seven_day_cowork":{"utilization":40},"iguana_necktie":{"utilization":99},"limits":[{"kind":"weekly_scoped","percent":10,"scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":64,"is_active":true,"scope":{"model":{"display_name":"Fable 5"}}}]}"#))
        XCTAssertEqual(quota.models.count, 4)
        XCTAssertEqual(quota.models[0].percentage, 99.56, accuracy: 0.0001)
        XCTAssertEqual(quota.models.filter { $0.name == "seven-day-fable" }.map(\.percentage), [36])
    }

    func testClaudeExtraFallsBackToActualAmountsAndRejectsInvalidCounters() throws {
        let quota = try ClaudeQuotaMapper.map(data: data(#"{"five_hour":{"utilization":true},"seven_day":{"utilization":"NaN"},"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250}}"#))
        XCTAssertEqual(quota.models.map(\.percentage), [-1, -1, 75])
        guard case .progress(let used, let limit, let unit) = quota.models[2].presentation else {
            return XCTFail("额外消费需要明确货币单位")
        }
        XCTAssertEqual(used, 12.5); XCTAssertEqual(limit, 50); XCTAssertEqual(unit, .usd)
    }

    func testMetadataUsesNestedAccountAndProjectFields() {
        let metadata = CPAQuotaMetadata(data: data(#"{"attributes":{"gemini_virtual_project":"project-a","id_token":{"https://api.openai.com/auth":{"chatgpt_account_id":"team-a","chatgpt_plan_type":"team"}}}}"#))
        XCTAssertEqual(metadata.projectID, "project-a")
        XCTAssertEqual(metadata.accountID, "team-a")
        XCTAssertEqual(metadata.plan, "team")
    }

    func testCPAUsesExactAuthIndexProjectAndEndpointFallbackWithoutModelDirectory() async throws {
        let log = RequestLog()
        let fetcher = CPAQuotaFetcher(call: { request in
            await log.append(request)
            XCTAssertEqual(request.authIndex, "auth-a")
            XCTAssertEqual(request.header?["Authorization"], "Bearer $TOKEN$")
            // 套餐查询是独立的辅助请求，不应套用额度汇总的项目参数断言。
            if request.url.hasSuffix(":loadCodeAssist") {
                return APICallResponse(statusCode: 200, header: nil, body: #"{"cloudaicompanionProject":"project-a","currentTier":{"id":"free-tier"}}"#)
            }
            XCTAssertTrue(request.data?.contains("project-a") == true)
            XCTAssertTrue(request.url.hasSuffix(":retrieveUserQuotaSummary"))
            let body = request.url.contains("sandbox")
                ? #"{"groups":[{"display_name":"Gemini","buckets":[{"remaining_fraction":0.25}]}]}"# : #"{"groups":[]}"#
            return APICallResponse(statusCode: 200, header: nil, body: body)
        }, download: { name in
            XCTAssertEqual(name, "custom-account.json")
            return Data(#"{"project_id":"project-a"}"#.utf8)
        })
        let file = try JSONDecoder().decode(AuthFile.self, from: data(#"{"id":"a","name":"custom-account.json","provider":"antigravity","status":"ready","disabled":false,"unavailable":false,"auth_index":"auth-a"}"#))
        let quota = try await fetcher.fetch(file: file)
        XCTAssertEqual(quota.models[0].percentage, 25)
        XCTAssertEqual(quota.subscriptionInfo?.cloudaicompanionProject, "project-a")
        let requests = await log.requests
        // 并发套餐请求没有固定完成顺序，只对顺序回退的额度请求验证主机顺序。
        let summaries = requests.filter { $0.url.hasSuffix(":retrieveUserQuotaSummary") }
        XCTAssertEqual(summaries.count, 2)
        XCTAssertTrue(summaries[0].url.hasPrefix("https://daily-cloudcode-pa.googleapis.com/"))
        XCTAssertEqual(requests.filter { $0.url.hasSuffix(":loadCodeAssist") }.count, 1)
        XCTAssertFalse(requests.contains { $0.url.contains("fetchAvailableModels") })
    }

    func testCPAClaudeDoesNotDownloadCredentialsOrUseLocalQuotaCache() async throws {
        let log = RequestLog()
        let fetcher = CPAQuotaFetcher(call: { request in
            await log.append(request)
            XCTAssertEqual(request.header?["anthropic-beta"], "oauth-2025-04-20")
            return APICallResponse(statusCode: 200, header: nil, body: #"{"five_hour":{"utilization":45}}"#)
        }, download: { _ in
            XCTFail("Claude 配额请求不需要下载令牌")
            throw QuotaFetchError.invalidResponse
        })
        let file = try JSONDecoder().decode(AuthFile.self, from: data(#"{"id":"a","name":"claude.json","provider":"claude","status":"ready","disabled":false,"unavailable":false,"auth_index":"auth-a"}"#))
        for _ in 0..<2 {
            let quota = try await fetcher.fetch(file: file)
            XCTAssertEqual(quota.models[0].percentage, 55)
        }
        let requests = await log.requests
        // 每次刷新同时读取 usage 和 profile；分别计数，确保没有用本地缓存代替第二次查询。
        XCTAssertEqual(requests.filter { $0.url.hasSuffix("/usage") }.count, 2)
        XCTAssertEqual(requests.filter { $0.url.hasSuffix("/profile") }.count, 2)
    }

    /// 同邮箱不能代表同一凭据；列表中的非秘密路由字段必须在后台解码后保留。
    func testAuthFileKeepsRuntimeMetadataAndSeparatesSameEmailCredentials() throws {
        let first = try JSONDecoder().decode(AuthFile.self, from: data(#"{"name":"first.json","provider":"antigravity","email":"same@example.com","auth_index":12,"runtime_only":true,"metadata":{"project_id":"project-a","id_token":{"https://api.openai.com/auth":{"chatgpt_account_id":"team-a","chatgpt_plan_type":"team"}}}}"#))
        let second = try JSONDecoder().decode(AuthFile.self, from: data(#"{"name":"second.json","provider":"antigravity","email":"same@example.com","authIndex":13}"#))
        XCTAssertEqual(first.authIndex, "12")
        XCTAssertEqual(first.quotaProjectID, "project-a")
        XCTAssertEqual(first.quotaAccountID, "team-a")
        XCTAssertEqual(first.quotaPlan, "team")
        XCTAssertNotEqual(first.quotaLookupKey, second.quotaLookupKey)
        XCTAssertEqual(first.quotaDisplayName, second.quotaDisplayName)
        let encoded = try JSONEncoder().encode(first)
        let restored = try JSONDecoder().decode(AuthFile.self, from: encoded)
        XCTAssertEqual(restored.quotaMetadata, first.quotaMetadata)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("id_token"))
    }

    /// 不可下载的运行时账号仍应通过列表账号 ID 查询，并保留重置券数量及到期明细。
    func testCodexRuntimeMetadataSkipsDownloadAndPreservesResetInventory() async throws {
        let log = RequestLog()
        let fetcher = CPAQuotaFetcher(call: { request in
            await log.append(request)
            XCTAssertEqual(request.authIndex, "17")
            XCTAssertEqual(request.header?["Chatgpt-Account-Id"], "team-a")
            XCTAssertEqual(request.header?["Authorization"], "Bearer $TOKEN$")
            if request.url.hasSuffix("/usage") {
                return APICallResponse(statusCode: 200, header: nil, body: #"{"rate_limit":{"primary_window":{"used_percent":20}}}"#)
            }
            if request.url.hasSuffix("/rate-limit-reset-credits") {
                XCTAssertEqual(request.header?["OpenAI-Beta"], "codex-1")
                return APICallResponse(statusCode: 200, header: nil, body: #"{"available_count":1,"credits":[{"id":"credit-a","reset_type":"weekly","status":"available","granted_at":"2026-01-01T00:00:00Z","expires_at":"2099-01-01T00:00:00Z"}]}"#)
            }
            return APICallResponse(statusCode: 503, header: nil, body: "{}")
        }, download: { _ in
            XCTFail("列表已有账号路由信息，不应下载运行时凭据")
            throw QuotaFetchError.invalidResponse
        })
        let file = try JSONDecoder().decode(AuthFile.self, from: data(#"{"name":"runtime.json","provider":"codex","auth_index":17,"runtime_only":true,"metadata":{"account_id":"team-a"}}"#))
        let quota = try await fetcher.fetch(file: file)
        XCTAssertEqual(quota.models.first?.percentage, 80)
        XCTAssertEqual(quota.analytics?.rows.first { $0.id == "codex-rate-limit-resets" }?.value, "1 available")
        XCTAssertEqual(quota.analytics?.rows.count, 2)
        let requests = await log.requests
        XCTAssertEqual(requests.count, 3)
    }

    /// 辅助读取失败不能抹掉主额度，下载失败也不是无条件阻断 CPA 查询的理由。
    func testCodexAuxiliaryAndDownloadFailuresPreserveUsage() async throws {
        let fetcher = CPAQuotaFetcher(call: { request in
            if request.url.hasSuffix("/usage") {
                return APICallResponse(statusCode: 200, header: nil, body: #"{"rate_limit":{"primary_window":{"used_percent":31}}}"#)
            }
            return APICallResponse(statusCode: 503, header: nil, body: "{}")
        }, download: { _ in throw QuotaFetchError.httpError(403) })
        let file = try JSONDecoder().decode(AuthFile.self, from: data(#"{"name":"runtime.json","provider":"codex","auth_index":"a"}"#))
        let quota = try await fetcher.fetch(file: file)
        XCTAssertEqual(quota.models.first?.percentage, 69)
        XCTAssertNil(quota.analytics)
    }

    /// 没有可下载凭据时，可从同一认证索引的订阅响应发现项目；空 paidTier 不应遮蔽 currentTier。
    func testAntigravityDiscoversProjectWhenCredentialDownloadIsUnavailable() async throws {
        let fetcher = CPAQuotaFetcher(call: { request in
            XCTAssertEqual(request.authIndex, "ag-runtime")
            if request.url.hasSuffix(":loadCodeAssist") {
                return APICallResponse(statusCode: 200, header: nil, body: #"{"cloudaicompanionProject":{"id":"discovered"},"paidTier":{},"currentTier":{"id":"free-tier"}}"#)
            }
            XCTAssertTrue(request.data?.contains("discovered") == true)
            return APICallResponse(statusCode: 200, header: nil, body: #"{"groups":[{"buckets":[{"remainingFraction":0.4}]}]}"#)
        }, download: { _ in throw QuotaFetchError.httpError(403) })
        let file = try JSONDecoder().decode(AuthFile.self, from: data(#"{"name":"runtime.json","provider":"antigravity","auth_index":"ag-runtime"}"#))
        let quota = try await fetcher.fetch(file: file)
        XCTAssertEqual(quota.models.first?.percentage, 40)
        XCTAssertEqual(quota.subscriptionInfo?.cloudaicompanionProject, "discovered")
        XCTAssertEqual(quota.planType, "Free")
    }

    /// 同周期窗口和无名额度都必须保留，不能用周期名称替代额度池身份。
    func testCodexUnnamedAndSameDurationWindowsRemainDistinct() throws {
        let quota = try CodexUsageMapper.map(data: data(#"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":604800},"secondary_window":{"used_percent":20,"limit_window_seconds":604800}},"additional_rate_limits":[{"rate_limit":{"primary_window":{"used_percent":30},"secondary_window":{"used_percent":40}}},{"metered_feature":"codex-spark","rate_limit":{"primary_window":{"used_percent":50,"limit_window_seconds":18000},"secondary_window":{"used_percent":60,"limit_window_seconds":18000}}}]}"#))
        XCTAssertEqual(quota.models.count, 6)
        XCTAssertEqual(Set(quota.models.map(\.name)).count, 6)
        XCTAssertEqual(quota.models.map(\.percentage).sorted(), [40, 50, 60, 70, 80, 90])
    }
}

private actor RequestLog {
    var requests: [APICallRequest] = []
    func append(_ request: APICallRequest) { requests.append(request) }
}
