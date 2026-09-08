import XCTest
@testable import Quotio

/// 回归样例只使用构造的公开字段，不读取真实账号、令牌或线上额度。
final class AntigravityQuotaTests: XCTestCase {
    private func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func summary(_ groups: [[String: Any]]) throws -> [ModelQuota] {
        try XCTUnwrap(AntigravityQuotaParser.summaryModels(from: data(["groups": groups])))
    }

    func testNewModelVersionsAndThirdPartyModelsKeepIndependentQuota() throws {
        let input: [String: Any] = ["models": [
            "gemini-3.1-pro": ["quotaInfo": ["remainingFraction": 0.2]],
            "gemini-3.5-flash": ["quotaInfo": ["remainingFraction": 0.8]],
            "gpt-oss-120b": ["quotaInfo": ["remainingFraction": 0.4]],
            "future-model": ["quotaInfo": ["remainingFraction": 0.6]],
        ]]
        let models = try AntigravityQuotaParser.models(from: data(input))
        let rows = AntigravityDisplayGroup.make(from: models)
        XCTAssertEqual(rows.map(\.name), ["gemini-3.1-pro", "gpt-oss-120b", "future-model", "gemini-3.5-flash"])
        XCTAssertEqual(rows.map(\.percentage), [20, 40, 60, 80])
        XCTAssertEqual(AntigravityDisplayGroup.lowestRemaining(in: models), 20)
        XCTAssertNil(MenuBarQuotaPair.resolve(for: .antigravity, from: models))
    }

    func testMissingNullBooleanAndNonfiniteQuotaStayUnknownWhileZeroIsExhausted() throws {
        let input: [String: Any] = ["models": [
            "missing": ["quotaInfo": [:]],
            "null": ["quotaInfo": ["remainingFraction": NSNull()]],
            "boolean": ["quotaInfo": ["remainingFraction": true]],
            "infinity": ["quotaInfo": ["remainingFraction": "Infinity"]],
            "nan": ["quotaInfo": ["remainingFraction": "NaN"]],
            "zero": ["quotaInfo": ["remainingFraction": 0]],
            "above": ["quotaInfo": ["remainingFraction": 1.2]],
        ]]
        let models = try AntigravityQuotaParser.models(from: data(input))
        for model in models where !["zero", "above"].contains(model.name) {
            XCTAssertEqual(model.percentage, -1, model.name)
            XCTAssertEqual(model.formattedPercentage, "—")
        }
        XCTAssertEqual(models.first { $0.name == "zero" }?.percentage, 0)
        XCTAssertEqual(models.first { $0.name == "above" }?.percentage, 100)
        XCTAssertEqual(AntigravityDisplayGroup.make(from: models).first?.name, "zero")
    }

    func testSameLabelBucketsAndDifferentGeminiGroupsAreNotDropped() throws {
        let models = try summary([
            ["groupId": "pro", "displayName": "Gemini Pro", "buckets": [
                ["bucketId": "a", "displayName": "Session", "remainingFraction": 0.8],
                ["bucketId": "b", "displayName": "Session", "remainingFraction": 0.2],
            ]],
            ["groupId": "flash", "displayName": "Gemini Flash", "buckets": [
                ["bucketId": "c", "displayName": "Session", "remainingFraction": 0.6],
                ["bucketId": "d", "displayName": "Weekly", "remainingFraction": 0.3],
            ]],
        ])
        XCTAssertEqual(models.count, 4)
        XCTAssertEqual(Set(AntigravityDisplayGroup.make(from: models).map(\.id)).count, 4)
        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .antigravity, from: models))
        XCTAssertEqual(pair.top.remainingPercentage, 20)
        XCTAssertEqual(pair.bottom.remainingPercentage, 30)
    }

    func testDuplicateBucketUsesLowestQuotaWithItsOwnResetTimeRegardlessOfOrder() throws {
        let buckets: [[String: Any]] = [
            ["id": "shared", "name": "Weekly", "remainingFraction": 0.8, "resetTime": "2026-09-06T00:00:00Z"],
            ["id": "shared", "name": "Weekly", "remainingFraction": 0.2, "resetTime": "2026-09-10T00:00:00Z"],
        ]
        for order in [buckets, Array(buckets.reversed())] {
            let models = try summary([["name": "Gemini", "buckets": order]])
            XCTAssertEqual(models.count, 1)
            let row = try XCTUnwrap(AntigravityDisplayGroup.make(from: models).first)
            XCTAssertEqual(row.percentage, 20)
            XCTAssertEqual(row.resetTime, "2026-09-10T00:00:00Z")
        }
    }

    func testPeriodIsNotInferredFromModelNumbersOrOtherHourlyWindows() throws {
        for label in ["model-5", "24-hour", "15-hour", "1.5-hour", "2-week", "365-day", "Gemini 3.5", "unknown"] {
            let models = try summary([["name": "Gemini", "buckets": [
                ["id": label, "remainingFraction": 0.4],
            ]]])
            XCTAssertNil(models[0].antigravityWindow, label)
            XCTAssertNil(MenuBarQuotaPair.resolve(for: .antigravity, from: models), label)
        }
        for (label, window) in [("5-hour", AntigravityQuotaWindow.session), ("weekly", .weekly), ("7d", .weekly), ("18000s", .session)] {
            let models = try summary([["name": "Gemini", "buckets": [
                ["id": "quota", "window": label, "remainingFraction": 0.4],
            ]]])
            XCTAssertEqual(models[0].antigravityWindow, window)
        }
    }

    func testDisabledBucketsAndUnknownOnlySummaryDoNotSuppressFallback() throws {
        let input: [String: Any] = ["groups": [["name": "Gemini", "buckets": [
            ["id": "weekly", "disabled": true, "remainingFraction": 0.7],
            ["id": "session"],
        ]]]]
        XCTAssertNil(AntigravityQuotaParser.summaryModels(from: try data(input)))
        XCTAssertNil(AntigravityQuotaParser.summaryModels(from: Data("{}".utf8)))
        XCTAssertThrowsError(try AntigravityQuotaParser.models(from: Data("{}".utf8)))
        XCTAssertThrowsError(try AntigravityQuotaParser.models(from: Data(#"{"models":{}}"#.utf8)))
    }

    func testWindowOnlyBucketsArePreservedAlongsideNamedBuckets() throws {
        let models = try summary([["name": "Gemini", "buckets": [
            ["window": "session", "remainingFraction": 0.2],
            ["id": "weekly", "remainingFraction": 0.8],
        ]]])
        XCTAssertEqual(models.count, 2)
        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .antigravity, from: models))
        XCTAssertEqual(pair.top.remainingPercentage, 20)
        XCTAssertEqual(pair.bottom.remainingPercentage, 80)
    }

    func testNestedSummaryAndFractionRepresentationPreserveUnknownRows() throws {
        let group: [String: Any] = ["name": "Third party", "buckets": [
            ["id": "weekly", "remaining": ["case": "remainingFraction", "value": "0.25"]],
            ["id": "session", "remainingFraction": NSNull()],
        ]]
        for wrapper in ["response", "summary"] {
            let input: [String: Any] = [wrapper: ["groups": [group]]]
            let models = try XCTUnwrap(AntigravityQuotaParser.summaryModels(from: data(input)))
            XCTAssertEqual(models.count, 2)
            XCTAssertEqual(AntigravityDisplayGroup.make(from: models).map(\.percentage), [25, -1])
        }
    }

    func testOfficialBucketShapeUsesNeutralLabelsAndKeepsFiveHourAndWeeklySeparate() throws {
        // 字段结构经过只读接口核对；数值使用固定构造数据，不包含真实账号信息。
        let models = try summary([["displayName": "Gemini Models", "buckets": [
            ["bucketId": "gemini-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly", "remainingFraction": 0.76],
            ["bucketId": "gemini-5h", "displayName": "Five Hour Limit Remaining", "window": "5h", "remainingFraction": 1],
        ]]])
        XCTAssertEqual(models.count, 2)
        XCTAssertTrue(models.allSatisfy { !$0.displayName.contains("Remaining") })
        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .antigravity, from: models))
        XCTAssertEqual(pair.top.remainingPercentage, 100)
        XCTAssertEqual(pair.bottom.remainingPercentage, 76)
        XCTAssertEqual(AntigravityDisplayGroup.lowestRemaining(in: models), 76)
    }

    func testNewMetadataRoundTripsAndOldCacheStillDecodes() throws {
        let model = ModelQuota(name: "bucket", percentage: 30, resetTime: "reset", sourceDisplayName: "Gemini · Weekly", antigravityWindow: .weekly)
        let decoded = try JSONDecoder().decode(ModelQuota.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(decoded.displayName, "Gemini · Weekly")
        XCTAssertEqual(decoded.antigravityWindow, .weekly)
        let legacy = try JSONDecoder().decode(ModelQuota.self, from: Data(#"{"name":"antigravity-gemini-weekly","percentage":40,"resetTime":""}"#.utf8))
        XCTAssertEqual(AntigravityDisplayGroup.window(for: legacy), .weekly)
    }

    func testFetcherPrefersWeeklySummaryOverFullModelQuota() async throws {
        let session = mockSession()
        defer { session.invalidateAndCancel() }
        let quota = try await AntigravityQuotaFetcher(session: session).fetchQuota(accessToken: "synthetic-summary")
        XCTAssertEqual(quota.models.count, 1)
        XCTAssertEqual(quota.models[0].percentage, 76)
        XCTAssertEqual(quota.models[0].antigravityWindow, .weekly)
    }

    func testFetcherDoesNotSubstituteFullModelQuotaWhenSummaryIsUnavailable() async throws {
        let session = mockSession()
        defer { session.invalidateAndCancel() }
        // 模型目录即使返回 100%，也不能证明真实的周／会话额度。汇总失败必须可观察。
        do {
            _ = try await AntigravityQuotaFetcher(session: session).fetchQuota(accessToken: "synthetic-fallback")
            XCTFail("汇总不可用时不得伪造满额")
        } catch { XCTAssertTrue(error is QuotaFetchError) }
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AntigravityQuotaTestProtocol.self]
        return URLSession(configuration: config)
    }

    @MainActor
    func testDisplayModesConvertRemainingExactlyOnce() {
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: 25), 75)
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: 25), 25)
        XCTAssertEqual(AntigravityDisplayGroup.lowestRemaining(in: [ModelQuota(name: "unknown", percentage: -1, resetTime: "")]), -1)
    }
}

/// 固定模拟服务响应，不依赖可变的全局 handler，允许测试并行且禁止外部请求。
nonisolated private final class AntigravityQuotaTestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: String
        if path.hasSuffix(":loadCodeAssist") {
            body = #"{"cloudaicompanionProject":"synthetic-project"}"#
        } else if path.hasSuffix(":retrieveUserQuotaSummary") {
            body = request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-summary"
                ? #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"weekly","window":"weekly","remainingFraction":0.76}]}]}"#
                : #"{"groups":[]}"#
        } else if path.hasSuffix(":fetchAvailableModels") {
            body = #"{"models":{"gemini-3.1-pro":{"quotaInfo":{"remainingFraction":1}}}}"#
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
