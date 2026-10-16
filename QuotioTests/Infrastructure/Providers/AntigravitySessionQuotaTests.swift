import XCTest
@testable import QuotioPlus

/// 针对真实接口差异构造脱敏样例：production 汇总的会话桶为滚动满额，daily quotaInfo 已消耗。
/// 全部网络由只读闭包或 URLProtocol 替代，不接触真实凭据、不调用生成接口或修改用户配置。
final class AntigravitySessionQuotaTests: XCTestCase {
    private func decoded(_ text: String) -> Data { Data(text.utf8) }

    func testLiveSessionCorrectsPlaceholderWithoutChangingWeeklyQuotaOrBucketIdentity() throws {
        let baseline = try XCTUnwrap(AntigravityQuotaParser.summaryModels(from: decoded(SessionQuotaFixture.summary)))
        let models = try XCTUnwrap(AntigravityQuotaParser.calibratedModels(
            summaryData: decoded(SessionQuotaFixture.summary), liveModelData: decoded(SessionQuotaFixture.live)
        ))
        XCTAssertEqual(Set(models.map(\.id)), Set(baseline.map(\.id)))
        XCTAssertEqual(models.count, 4)
        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .antigravity, from: models))
        XCTAssertEqual(pair.top.remainingPercentage, 62)
        XCTAssertEqual(models.first { $0.antigravityWindow == .session && $0.percentage == pair.top.remainingPercentage }?.resetTime, "2099-01-01T03:00:00Z")
        XCTAssertEqual(pair.bottom.remainingPercentage, 41)
        XCTAssertEqual(models.first { $0.antigravityWindow == .weekly && $0.percentage == pair.bottom.remainingPercentage }?.resetTime, "2099-01-07T00:00:00Z")
        XCTAssertEqual(models.first { $0.sourceDisplayName?.hasPrefix("Claude") == true && $0.antigravityWindow == .session }?.percentage, 80)
    }

    func testDifferentNativeReadingsAndUnknownModelsAreKeptIndependently() throws {
        let live = #"{"models":{"gemini-pro":{"displayName":"Gemini Pro","quotaInfo":{"remainingFraction":0.2,"resetTime":"2099-01-01T02:00:00Z"}},"gemini-flash":{"quotaInfo":{"remainingFraction":0.8,"resetTime":"2099-01-01T04:00:00Z"}},"gemini-unknown":{"quotaInfo":{}},"gemini-disabled":{"disabled":true,"quotaInfo":{"remainingFraction":0}},"chat_internal":{"quotaInfo":{"remainingFraction":0}}}}"#
        let models = try XCTUnwrap(AntigravityQuotaParser.calibratedModels(
            summaryData: decoded(SessionQuotaFixture.summary), liveModelData: decoded(live)
        ))
        XCTAssertEqual(models.first { $0.name == "gemini-pro" }?.percentage, 20)
        XCTAssertEqual(models.first { $0.name == "gemini-flash" }?.percentage, 80)
        XCTAssertEqual(models.first { $0.name == "gemini-unknown" }?.percentage, -1)
        XCTAssertFalse(models.contains { ["gemini-disabled", "chat_internal"].contains($0.name) })
        XCTAssertEqual(models.filter { $0.sourceDisplayName?.hasPrefix("Gemini") == true && $0.antigravityWindow == .weekly }.count, 1)
        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .antigravity, from: models))
        XCTAssertEqual(pair.top.remainingPercentage, 20)
        XCTAssertEqual(models.first { $0.name == "gemini-pro" }?.resetTime, "2099-01-01T02:00:00Z")
        XCTAssertEqual(pair.bottom.remainingPercentage, 41)
    }

    func testUnavailableOrInvalidLiveDataShowsUnknownSessionAndKeepsActualWeeklyData() throws {
        for live in [nil, decoded("{}"), decoded(#"{"models":{"gemini-test":{"quotaInfo":{"remainingFraction":true}}}}"#)] {
            let models = try XCTUnwrap(AntigravityQuotaParser.calibratedModels(
                summaryData: decoded(SessionQuotaFixture.summary), liveModelData: live
            ))
            XCTAssertEqual(models.filter { $0.antigravityWindow == .session }.map(\.percentage), [-1, -1])
            XCTAssertTrue(models.filter { $0.antigravityWindow == .session }.allSatisfy { $0.resetTime.isEmpty })
            XCTAssertEqual(models.filter { $0.antigravityWindow == .weekly }.map(\.percentage).sorted(), [41, 90])
        }
    }

    func testExplicitZeroRemainsExhaustedAndLiveModelsCannotInventWeeklyQuota() throws {
        let live = decoded(#"{"models":{"gemini-test":{"quotaInfo":{"remainingFraction":0,"resetTime":"2099-01-01T02:00:00Z"}}}}"#)
        let models = try XCTUnwrap(AntigravityQuotaParser.calibratedModels(summaryData: decoded(SessionQuotaFixture.summary), liveModelData: live))
        XCTAssertEqual(models.first { $0.sourceDisplayName?.hasPrefix("Gemini") == true && $0.antigravityWindow == .session }?.percentage, 0)
        XCTAssertNil(AntigravityQuotaParser.calibratedModels(summaryData: decoded(#"{"groups":[]}"#), liveModelData: live))
        XCTAssertNil(AntigravityQuotaParser.calibratedModels(summaryData: decoded("{}"), liveModelData: live))
    }

    func testOmittedZeroRequiresAnExplicitValidResetAndDoesNotConvertMalformedValues() throws {
        // 兼容 Magpie 记录的零值省略行为；这些是构造夹具，不声称本次账号恰好耗尽。
        let live = #"{"models":{"gemini-exhausted":{"quotaInfo":{"resetTime":"2099-01-01T02:00:00Z"}},"gemini-empty":{"quotaInfo":{}},"gemini-bad-reset":{"quotaInfo":{"resetTime":"bad"}},"gemini-null":{"quotaInfo":{"remainingFraction":null,"resetTime":"2099-01-01T02:00:00Z"}},"gemini-boolean":{"quotaInfo":{"remainingFraction":false,"resetTime":"2099-01-01T02:00:00Z"}},"gemini-nan":{"quotaInfo":{"remainingFraction":"NaN","resetTime":"2099-01-01T02:00:00Z"}}}}"#
        let models = try AntigravityQuotaParser.models(from: decoded(live))
        XCTAssertEqual(models.first { $0.name == "gemini-exhausted" }?.percentage, 0)
        XCTAssertTrue(models.filter { $0.name != "gemini-exhausted" }.allSatisfy { $0.percentage == -1 })
    }

    func testIndependentAndUnknownSummaryGroupsAreNotReassignedToOneNativePool() throws {
        let summary = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"a","window":"5h","remainingFraction":0.3},{"bucketId":"b","window":"5h","remainingFraction":0.9}]},{"displayName":"Gemini Pro","buckets":[{"bucketId":"c","window":"5h","remainingFraction":0.5}]}]}"#
        let models = try XCTUnwrap(AntigravityQuotaParser.calibratedModels(
            summaryData: decoded(summary), liveModelData: decoded(SessionQuotaFixture.live)
        ))
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models.map(\.percentage).sorted(), [30, 50, 90])
    }

    func testLocalFetcherUsesNativeSessionQuotaAndMatchingReset() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionQuotaProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let quota = try await AntigravityQuotaFetcher(session: session).fetchQuota(accessToken: "synthetic-live", projectId: "fixture-project")
        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .antigravity, from: quota.models))
        XCTAssertEqual(pair.top.remainingPercentage, 62)
        XCTAssertEqual(quota.models.first { $0.antigravityWindow == .session && $0.percentage == pair.top.remainingPercentage }?.resetTime, "2099-01-01T03:00:00Z")
        XCTAssertEqual(pair.bottom.remainingPercentage, 41)
    }

    func testLocalSupplementFailureRetainsWeeklyAndDoesNotReportFullSession() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionQuotaProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let quota = try await AntigravityQuotaFetcher(session: session).fetchQuota(accessToken: "synthetic-unavailable", projectId: "fixture-project")
        XCTAssertEqual(quota.models.filter { $0.antigravityWindow == .session }.map(\.percentage), [-1, -1])
        XCTAssertEqual(quota.models.filter { $0.antigravityWindow == .weekly }.map(\.percentage).sorted(), [41, 90])
    }

    func testCPARepeatedRefreshUsesSameCredentialAndPublishesNewSessionAndResetTogether() async throws {
        let log = SessionQuotaCallLog()
        let fetcher = CPAQuotaFetcher(call: { request in
            let modelRead = await log.append(request)
            XCTAssertEqual(request.authIndex, "fixture-auth")
            XCTAssertEqual(request.header?["Authorization"], "Bearer $TOKEN$")
            if request.url.hasSuffix(":loadCodeAssist") {
                return APICallResponse(statusCode: 200, header: nil, body: #"{"cloudaicompanionProject":"fixture-project"}"#)
            }
            XCTAssertTrue(request.data?.contains("fixture-project") == true)
            if request.url.hasSuffix(":retrieveUserQuotaSummary") {
                XCTAssertEqual(request.url, "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
                return APICallResponse(statusCode: 200, header: nil, body: SessionQuotaFixture.summary)
            }
            XCTAssertEqual(request.url, "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")
            let body = modelRead == 1 ? SessionQuotaFixture.live : #"{"models":{"gemini-next":{"quotaInfo":{"remainingFraction":0.43,"resetTime":"2099-01-01T04:00:00Z"}}}}"#
            return APICallResponse(statusCode: 200, header: nil, body: body)
        }, download: { _ in
            XCTFail("项目元数据已足够，不得下载凭据或读取本机其他账号")
            throw QuotaFetchError.invalidResponse
        })
        let first = try await fetcher.fetch(file: fixtureAuth())
        let second = try await fetcher.fetch(file: fixtureAuth())
        let a = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .antigravity, from: first.models))
        let b = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .antigravity, from: second.models))
        XCTAssertEqual(a.top.remainingPercentage, 62)
        XCTAssertEqual(first.models.first { $0.antigravityWindow == .session && $0.percentage == a.top.remainingPercentage }?.resetTime, "2099-01-01T03:00:00Z")
        XCTAssertEqual(b.top.remainingPercentage, 43)
        XCTAssertEqual(second.models.first { $0.antigravityWindow == .session && $0.percentage == b.top.remainingPercentage }?.resetTime, "2099-01-01T04:00:00Z")
        XCTAssertEqual(b.bottom.remainingPercentage, 41)
    }

    func testCPASupplementFailureDoesNotFallbackToProductionModelPlaceholder() async throws {
        let log = SessionQuotaCallLog()
        let fetcher = CPAQuotaFetcher(call: { request in
            _ = await log.append(request)
            if request.url.hasSuffix(":loadCodeAssist") {
                return APICallResponse(statusCode: 200, header: nil, body: #"{"cloudaicompanionProject":"fixture-project"}"#)
            }
            if request.url.hasSuffix(":retrieveUserQuotaSummary") {
                return APICallResponse(statusCode: 200, header: nil, body: SessionQuotaFixture.summary)
            }
            XCTAssertNotEqual(request.url, "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")
            return APICallResponse(statusCode: 503, header: nil, body: "{}")
        }, download: { _ in throw QuotaFetchError.invalidResponse })
        let quota = try await fetcher.fetch(file: fixtureAuth())
        XCTAssertEqual(quota.models.filter { $0.antigravityWindow == .session }.map(\.percentage), [-1, -1])
        XCTAssertEqual(quota.models.filter { $0.antigravityWindow == .weekly }.map(\.percentage).sorted(), [41, 90])
        let reads = await log.modelReads
        XCTAssertEqual(reads, 2)
    }

    func testUnknownOrAmbiguousSessionGroupsDoNotStartUnnecessaryNativeRequests() async throws {
        let fixtures = [
            #"{"groups":[{"displayName":"Gemini Pro","buckets":[{"window":"5h","remainingFraction":0.3}]}]}"#,
            #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"a","window":"5h","remainingFraction":0.3},{"bucketId":"b","window":"5h","remainingFraction":0.9}]}]}"#,
            #"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.3}]}]}"#
        ]
        for fixture in fixtures {
            let log = SessionQuotaCallLog()
            let fetcher = CPAQuotaFetcher(call: { request in
                _ = await log.append(request)
                if request.url.hasSuffix(":loadCodeAssist") {
                    return APICallResponse(statusCode: 200, header: nil, body: #"{"cloudaicompanionProject":"fixture-project"}"#)
                }
                XCTAssertTrue(request.url.hasSuffix(":retrieveUserQuotaSummary"), "无法校准时不应等待额外目录请求")
                return APICallResponse(statusCode: 200, header: nil, body: fixture)
            }, download: { _ in throw QuotaFetchError.invalidResponse })
            let quota = try await fetcher.fetch(file: fixtureAuth())
            XCTAssertFalse(quota.models.isEmpty)
            let reads = await log.modelReads
            XCTAssertEqual(reads, 0)
        }
    }

    func testCancellationDuringNativeSupplementIsNotConvertedToSuccessfulSummary() async throws {
        let log = SessionQuotaCallLog()
        let fetcher = CPAQuotaFetcher(call: { request in
            _ = await log.append(request)
            if request.url.hasSuffix(":loadCodeAssist") {
                return APICallResponse(statusCode: 200, header: nil, body: #"{"cloudaicompanionProject":"fixture-project"}"#)
            }
            if request.url.hasSuffix(":retrieveUserQuotaSummary") {
                return APICallResponse(statusCode: 200, header: nil, body: SessionQuotaFixture.summary)
            }
            throw CancellationError()
        }, download: { _ in throw QuotaFetchError.invalidResponse })
        do {
            _ = try await fetcher.fetch(file: fixtureAuth())
            XCTFail("取消必须传播，不能让旧会话返回成功快照")
        } catch { XCTAssertTrue(error is CancellationError) }
        let reads = await log.modelReads
        XCTAssertEqual(reads, 1)
    }

    private func fixtureAuth() throws -> AuthFile {
        try JSONDecoder().decode(AuthFile.self, from: decoded(#"{"name":"fixture.json","provider":"antigravity","auth_index":"fixture-auth","metadata":{"project_id":"fixture-project"}}"#))
    }
}

nonisolated private enum SessionQuotaFixture {
    static let summary = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.41,"resetTime":"2099-01-07T00:00:00Z"},{"bucketId":"gemini-5h","window":"5h","remainingFraction":1,"resetTime":"2099-01-01T05:00:00Z"}]},{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.9,"resetTime":"2099-01-07T01:00:00Z"},{"bucketId":"3p-5h","window":"5h","remainingFraction":1,"resetTime":"2099-01-01T05:00:00Z"}]}]}"#
    static let live = #"{"models":{"gemini-flash":{"quotaInfo":{"remainingFraction":0.62,"resetTime":"2099-01-01T03:00:00Z"}},"gemini-pro":{"quotaInfo":{"remainingFraction":0.62,"resetTime":"2099-01-01T03:00:00Z"}},"claude-test":{"quotaInfo":{"remainingFraction":0.8,"resetTime":"2099-01-01T02:00:00Z"}},"gpt-oss-test":{"quotaInfo":{"remainingFraction":0.8,"resetTime":"2099-01-01T02:00:00Z"}}}}"#
}

/// 计数只属于单个测试实例，避免全局可变 handler 让不同账号或用例互相污染。
private actor SessionQuotaCallLog {
    private(set) var modelReads = 0
    func append(_ request: APICallRequest) -> Int {
        if request.url.hasSuffix(":fetchAvailableModels") { modelReads += 1 }
        return modelReads
    }
}

/// 所有请求都被本地拦截；补查失败时两个 daily 端点返回 503，不允许落到真实网络。
nonisolated private final class SessionQuotaProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        let summary = request.url?.path.hasSuffix(":retrieveUserQuotaSummary") == true
        let unavailable = request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-unavailable"
        let status = !summary && unavailable ? 503 : 200
        let body = summary ? SessionQuotaFixture.summary : SessionQuotaFixture.live
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
