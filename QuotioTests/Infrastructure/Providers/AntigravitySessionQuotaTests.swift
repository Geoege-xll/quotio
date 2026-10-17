import XCTest
@testable import QuotioPlus

/// 按同账号、同项目的新旧协议对照结果构造离线夹具，不读取真实凭据或线上服务。
/// 保留原测试类入口；校准拼接已退出生产，回归改为验证完整周期契约和两种传输的一致性。
final class AntigravitySessionQuotaTests: XCTestCase {
    func testHubSummaryKeepsBothPeriodsAndTheirOwnResetTimes() async throws {
        let reader = AntigravityQuotaReader { url, payload in
            XCTAssertEqual(url, "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
            XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(payload.utf8)), ["project": "fixture-project"])
            return SessionQuotaFixture.summary(weekly: 0.95, session: 0.84)
        }
        let models = try await reader.fetch(projectID: "fixture-project")
        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .antigravity, from: models))
        XCTAssertEqual(models.count, 4)
        XCTAssertEqual(pair.top.remainingPercentage, 84)
        XCTAssertEqual(pair.bottom.remainingPercentage, 95)
        XCTAssertEqual(models.first { $0.percentage == 84 }?.resetTime, "2099-01-01T03:00:00Z")
        XCTAssertEqual(models.first { $0.percentage == 95 }?.resetTime, "2099-01-07T00:00:00Z")
        XCTAssertFalse(models.contains { $0.displayName.contains("Remaining") })
    }

    func testTwoCredentialsKeepSeparateWeeklyAndSessionQuotaDespiteSameEmail() async throws {
        let log = SessionQuotaCallLog()
        let fetcher = CPAQuotaFetcher(call: { request in
            await log.append(request.url)
            XCTAssertEqual(request.header?["Authorization"], "Bearer $TOKEN$")
            XCTAssertEqual(request.header?["User-Agent"], "antigravity/hub/2.23.0 darwin/arm64")
            let first = request.authIndex == "fixture-a"
            XCTAssertTrue(first || request.authIndex == "fixture-b")
            if request.url.hasSuffix(":loadCodeAssist") {
                // 存量列表项目可以与新发现项目不同；保留用户项目，不能拿辅助订阅覆盖本轮身份。
                return APICallResponse(statusCode: 200, header: nil, body: #"{"cloudaicompanionProject":"different-discovered-project","currentTier":{"id":"g1-pro-tier"}}"#)
            }
            XCTAssertEqual(request.url, "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
            let payload = try JSONDecoder().decode([String: String].self, from: Data(try XCTUnwrap(request.data).utf8))
            XCTAssertEqual(payload["project"], first ? "project-a" : "project-b")
            let body = SessionQuotaFixture.summary(weekly: first ? 0.95 : 0.91, session: first ? 0.84 : 0.76)
            return APICallResponse(statusCode: 200, header: nil, body: String(decoding: body, as: UTF8.self))
        }, download: { _ in
            XCTFail("已有项目时不得下载凭据或回退本机其他账号")
            throw QuotaFetchError.invalidResponse
        })
        let fileA = try fixtureAuth(index: "fixture-a", project: "project-a")
        let fileB = try fixtureAuth(index: "fixture-b", project: "project-b")
        XCTAssertNotEqual(fileA.quotaLookupKey, fileB.quotaLookupKey)
        async let first = fetcher.fetch(file: fileA)
        async let second = fetcher.fetch(file: fileB)
        let (a, b) = try await (first, second)
        let pairA = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .antigravity, from: a.models))
        let pairB = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .antigravity, from: b.models))
        XCTAssertEqual(pairA.top.remainingPercentage, 84)
        XCTAssertEqual(pairA.bottom.remainingPercentage, 95)
        XCTAssertEqual(pairB.top.remainingPercentage, 76)
        XCTAssertEqual(pairB.bottom.remainingPercentage, 91)
        let urls = await log.urls
        XCTAssertEqual(urls.filter { $0.hasSuffix(":retrieveUserQuotaSummary") }.count, 2)
        XCTAssertFalse(urls.contains { $0.hasSuffix(":fetchAvailableModels") })
    }

    func testCPARepeatedRefreshReplacesBothPeriodsAndTheirResetTimesTogether() async throws {
        let log = SessionQuotaCallLog()
        let fetcher = CPAQuotaFetcher(call: { request in
            let read = await log.append(request.url)
            XCTAssertEqual(request.authIndex, "fixture-auth")
            if request.url.hasSuffix(":loadCodeAssist") {
                return APICallResponse(statusCode: 200, header: nil, body: #"{"currentTier":{"id":"g1-pro-tier"}}"#)
            }
            let first = read == 1
            let body = SessionQuotaFixture.summary(weekly: first ? 0.95 : 0.91, session: first ? 0.84 : 0.76, next: !first)
            return APICallResponse(statusCode: 200, header: nil, body: String(decoding: body, as: UTF8.self))
        }, download: { _ in throw QuotaFetchError.invalidResponse })
        let file = try fixtureAuth()
        let first = try await fetcher.fetch(file: file)
        let second = try await fetcher.fetch(file: file)
        XCTAssertEqual(first.models.first { $0.percentage == 95 }?.resetTime, "2099-01-07T00:00:00Z")
        XCTAssertEqual(second.models.first { $0.percentage == 91 }?.resetTime, "2099-01-08T00:00:00Z")
        XCTAssertEqual(second.models.first { $0.percentage == 76 }?.resetTime, "2099-01-01T04:00:00Z")
        XCTAssertEqual(Set(first.models.map(\.id)), Set(second.models.map(\.id)))
    }

    func testLocalFetcherUsesSameHubSummaryContractWithoutModelSupplement() async throws {
        let session = mockSession()
        defer { session.invalidateAndCancel() }
        let quota = try await AntigravityQuotaFetcher(session: session).fetchQuota(accessToken: "fixture-daily", projectId: "fixture-project")
        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(for: .antigravity, from: quota.models))
        XCTAssertEqual(pair.top.remainingPercentage, 84)
        XCTAssertEqual(pair.bottom.remainingPercentage, 95)
        XCTAssertEqual(quota.models.count, 4)
    }

    func testLocalFallbackStaysInAntigravityExecutionEnvironment() async throws {
        let session = mockSession()
        defer { session.invalidateAndCancel() }
        let quota = try await AntigravityQuotaFetcher(session: session).fetchQuota(accessToken: "fixture-fallback", projectId: "fixture-project")
        XCTAssertEqual(quota.models.first { $0.percentage == 95 }?.resetTime, "2099-01-07T00:00:00Z")
    }

    func testUnavailableDailyEndpointsNeverReadProductionPlaceholderOrModelDirectory() async throws {
        let log = SessionQuotaCallLog()
        let reader = AntigravityQuotaReader { url, _ in
            await log.append(url)
            throw QuotaFetchError.httpError(503)
        }
        do {
            _ = try await reader.fetch(projectID: "fixture-project")
            XCTFail("无法读取真实额度时必须失败，不能用其他环境的 100% 剩余伪造成功")
        } catch QuotaFetchError.httpError(503) {} catch { XCTFail("应保留真实读取错误：\(error)") }
        let urls = await log.urls
        XCTAssertEqual(urls, [
            "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
            "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary"
        ])
    }

    func testCPAFailureCannotPublishFalseFullQuota() async throws {
        let fetcher = CPAQuotaFetcher(call: { request in
            if request.url.hasSuffix(":loadCodeAssist") {
                return APICallResponse(statusCode: 200, header: nil, body: #"{"currentTier":{"id":"g1-pro-tier"}}"#)
            }
            XCTAssertTrue(request.url.contains("daily-cloudcode-pa"))
            XCTAssertTrue(request.url.hasSuffix(":retrieveUserQuotaSummary"))
            return APICallResponse(statusCode: 503, header: nil, body: "{}")
        }, download: { _ in throw QuotaFetchError.invalidResponse })
        do {
            _ = try await fetcher.fetch(file: fixtureAuth())
            XCTFail("应交由原刷新宿主保留旧值并标记失败")
        } catch QuotaFetchError.httpError(503) {} catch { XCTFail("应保留真实读取错误：\(error)") }
    }

    func testUnknownSummaryRetriesAndExplicitZeroRemainsExhausted() async throws {
        let log = SessionQuotaCallLog()
        let reader = AntigravityQuotaReader { url, _ in
            let read = await log.append(url)
            if read == 1 { return Data(#"{"groups":[{"buckets":[{"window":"weekly","remainingFraction":null}]}]}"#.utf8) }
            return SessionQuotaFixture.summary(weekly: 0, session: 0.84)
        }
        let models = try await reader.fetch(projectID: "fixture-project")
        XCTAssertEqual(models.first { $0.sourceDisplayName?.hasPrefix("Gemini") == true && $0.antigravityWindow == .weekly }?.percentage, 0)
        let urls = await log.urls
        XCTAssertEqual(urls.count, 2)
    }

    func testIndependentOrPartialBucketsAreNotRebuiltFromModelFamilies() async throws {
        let fixture = Data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"weekly","window":"weekly","remainingFraction":0.31}]},{"displayName":"Independent","buckets":[{"bucketId":"a","window":"5h","remainingFraction":0.4},{"bucketId":"b","window":"5h","remainingFraction":0.8}]}]}"#.utf8)
        let reader = AntigravityQuotaReader { _, _ in fixture }
        let models = try await reader.fetch(projectID: "fixture-project")
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models.filter { $0.antigravityWindow == .session }.map(\.percentage).sorted(), [40, 80])
        XCTAssertEqual(models.filter { $0.antigravityWindow == .weekly }.map(\.percentage), [31])
        XCTAssertFalse(models.contains { $0.sourceDisplayName?.hasPrefix("Gemini") == true && $0.antigravityWindow == .session })
    }

    func testCancellationStopsFallback() async throws {
        let log = SessionQuotaCallLog()
        let reader = AntigravityQuotaReader { url, _ in
            await log.append(url)
            throw CancellationError()
        }
        do {
            _ = try await reader.fetch(projectID: "fixture-project")
            XCTFail("取消不得触发另一个端点或返回成功")
        } catch { XCTAssertTrue(error is CancellationError) }
        let urls = await log.urls
        XCTAssertEqual(urls.count, 1)
    }

    func testLateResponseAfterCancellationCannotBecomeSuccessfulSnapshot() async throws {
        let gate = SessionQuotaResponseGate()
        let reader = AntigravityQuotaReader { _, _ in
            await gate.suspendResponse()
            return SessionQuotaFixture.summary(weekly: 0.95, session: 0.84)
        }
        let task = Task { try await reader.fetch(projectID: "fixture-project") }
        await gate.waitForRequest()
        task.cancel()
        // 模拟未传播取消的传输层，主动放回旧响应；Reader 必须在解析提交前拒绝它。
        await gate.resumeResponse()
        do {
            _ = try await task.value
            XCTFail("迟到响应不能成为成功快照")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testEmptyProjectDoesNotStartNetworkRequest() async throws {
        let reader = AntigravityQuotaReader { _, _ in
            XCTFail("没有明确项目时不得查询其他账号或默认项目")
            return Data()
        }
        do {
            _ = try await reader.fetch(projectID: " \n ")
            XCTFail("空项目应失败")
        } catch { XCTAssertTrue(error is QuotaFetchError) }
    }

    func testLocalForbiddenPreservesExistingAccountStatus() async throws {
        let session = mockSession()
        defer { session.invalidateAndCancel() }
        let quota = try await AntigravityQuotaFetcher(session: session).fetchQuota(accessToken: "fixture-forbidden", projectId: "fixture-project")
        XCTAssertTrue(quota.isForbidden)
        XCTAssertTrue(quota.models.isEmpty)
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionQuotaProtocol.self]
        return URLSession(configuration: config)
    }

    private func fixtureAuth(index: String = "fixture-auth", project: String = "fixture-project") throws -> AuthFile {
        let object = ["name": index + ".json", "provider": "antigravity", "auth_index": index,
                      "email": "same@example.com", "metadata": ["project_id": project]] as [String: Any]
        return try JSONDecoder().decode(AuthFile.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

nonisolated private enum SessionQuotaFixture {
    /// 两周期故意使用不同数值及重置时间，能发现互换周期、跨响应拼接及连续刷新保留旧值。
    static func summary(weekly: Double, session: Double, next: Bool = false) -> Data {
        let weeklyReset = next ? "2099-01-08T00:00:00Z" : "2099-01-07T00:00:00Z"
        let sessionReset = next ? "2099-01-01T04:00:00Z" : "2099-01-01T03:00:00Z"
        return Data("""
        {"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":\(weekly),"resetTime":"\(weeklyReset)"},
          {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":\(session),"resetTime":"\(sessionReset)"}
        ]},{"displayName":"Claude and GPT models","buckets":[
          {"bucketId":"3p-weekly","window":"weekly","remainingFraction":1},
          {"bucketId":"3p-5h","window":"5h","remainingFraction":1}
        ]}]}
        """.utf8)
    }
}

private actor SessionQuotaCallLog {
    private(set) var urls: [String] = []
    @discardableResult
    func append(_ url: String) -> Int {
        urls.append(url)
        return urls.filter { $0.hasSuffix(":retrieveUserQuotaSummary") }.count
    }
}

/// 门闩仅属于单个测试；用 continuation 建立确切取消顺序，不使用 sleep 或可变全局 handler。
private actor SessionQuotaResponseGate {
    private var response: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func suspendResponse() async {
        await withCheckedContinuation { continuation in
            response = continuation
            observer?.resume()
            observer = nil
        }
    }
    func waitForRequest() async {
        guard response == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resumeResponse() {
        response?.resume()
        response = nil
    }
}

/// 校验本地传输的 Hub 身份及禁缓存契约；所有请求均离线拦截，生产主机或模型补查立即失败。
nonisolated private final class SessionQuotaProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "antigravity/hub/2.23.0 darwin/arm64")
        XCTAssertTrue(request.url?.host?.contains("daily-cloudcode-pa") == true)
        XCTAssertTrue(request.url?.path.hasSuffix(":retrieveUserQuotaSummary") == true)
        let auth = request.value(forHTTPHeaderField: "Authorization")
        let status = auth == "Bearer fixture-forbidden" ? 403 :
            (auth == "Bearer fixture-fallback" && request.url?.host == "daily-cloudcode-pa.googleapis.com" ? 503 : 200)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: SessionQuotaFixture.summary(weekly: 0.95, session: 0.84))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
