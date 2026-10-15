import XCTest
@testable import QuotioPlus

/// 只消费离线队列夹具，验证分类证据、历史兼容和脱敏归档；不访问运行中的 CPA。
@MainActor
final class CPAUsageFailureTests: XCTestCase {
    private func record(status: Int? = 500, body: Any? = nil, failed: Bool = true) throws -> UsageRecord {
        var fail: [String: Any] = [:]
        if let status { fail["status_code"] = status }
        if let body { fail["body"] = body }
        let payload: [String: Any] = ["timestamp": "2026-10-15T02:00:00Z", "provider": "claude",
            "model": "fixture", "failed": failed, "request_id": UUID().uuidString, "fail": fail]
        return try JSONDecoder().decode(UsageRecord.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func explanation(_ record: UsageRecord) throws -> CPAUsageFailureExplanation {
        try XCTUnwrap(CPAUsageFailureExplanation.make(for: CPAUsageEvent(record: record)))
    }

    func test429DistinguishesRateLimitFromSubscriptionQuota() throws {
        let rate = try record(status: 429, body: #"{"error":{"type":"rate_limit_error","message":"Too many requests"}}"#)
        let quota = try record(status: 429, body: #"{"error":{"type":"rate_limit_error","code":"usage_limit_reached"}}"#)
        XCTAssertEqual(try explanation(rate).kind, .rateLimited)
        XCTAssertEqual(try explanation(quota).kind, .quotaExhausted)
        XCTAssertEqual(try explanation(quota).evidence, .errorInformation)
        XCTAssertEqual(try explanation(quota).status, 429)
        let explicitRate = try explanation(record(status: 429, body: ["error": ["code": "rate_limit_exceeded",
            "message": "The requests per minute quota has been exceeded"]]))
        XCTAssertEqual(explicitRate.kind, .rateLimited, "通用 quota 文案不能覆盖明确的限流 code")
        XCTAssertEqual(explicitRate.evidence, .errorInformation)
        XCTAssertEqual(explicitRate.status, 429)
    }

    func testGeneric429NeverClaimsThatAccountQuotaIsExhausted() throws {
        let bodies: [Any?] = [nil, "Unexpected error", ["error": ["code": "quota_exceeded"]],
            "Quota has been exceeded for RequestsPerMinute", "Quota exhausted",
            ["error": ["status": "RESOURCE_EXHAUSTED", "message": "Quota has been exceeded for RequestsPerMinute"]]]
        for body in bodies {
            let e = try explanation(record(status: 429, body: body))
            XCTAssertEqual(e.kind, .rateOrQuota)
            XCTAssertEqual(e.evidence, .statusCode, "泛化 quota_exceeded 也可能只是频率额度，不能认定订阅耗尽")
        }
    }

    func test500UsesSpecificErrorInformationInsteadOfGenericServerFailure() throws {
        let cases: [(String, CPAUsageFailureKind)] = [
            ("auth_unavailable: no auth available", .noAvailableAccount),
            ("context deadline exceeded", .timeout),
            ("net/http: TLS handshake timeout", .timeout),
            ("dial tcp: connection refused", .connection),
            (#"{"error":{"type":"overloaded_error"}}"#, .overloaded),
            (#"{"error":{"code":"context_length_exceeded","type":"invalid_request_error"}}"#, .contextTooLong)
        ]
        for (body, expected) in cases {
            let e = try explanation(record(body: body))
            XCTAssertEqual(e.kind, expected)
            XCTAssertEqual(e.evidence, .errorInformation)
            XCTAssertEqual(e.status, 500, "分类不改写 CPA 上报状态")
        }
    }

    func testRecognizesAuthenticationModelAndRequestErrors() throws {
        let cases: [(String, CPAUsageFailureKind)] = [
            ("invalid_api_key", .authentication), ("permission_denied", .permissionDenied),
            ("model_not_found", .modelUnavailable), ("invalid_request_error", .invalidRequest)
        ]
        for (message, kind) in cases {
            let e = try explanation(record(body: ["error": ["message": message]]))
            XCTAssertEqual(e.kind, kind)
        }
    }

    func testOnlyErrorFieldsAreClassifiedNotPromptOrHeaders() throws {
        let body = #"{"prompt":"insufficient_quota","headers":{"Authorization":"invalid_api_key"},"error":{"message":"Unexpected failure"}}"#
        XCTAssertNil(try record(body: body).context?.failureKind)
        XCTAssertEqual(try explanation(record(body: body)).kind, .serverError)
    }

    func testMalformedLargeAndMissingBodiesDoNotDropExecution() throws {
        let bodies: [Any?] = [nil, 123, "{broken JSON", String(repeating: "x", count: 40_000)]
        for body in bodies {
            let event = CPAUsageEvent(record: try record(status: 503, body: body))
            XCTAssertEqual(event.outcome, .failed)
            XCTAssertEqual(CPAUsageFailureExplanation.make(for: event)?.kind, .serviceUnavailable)
            XCTAssertEqual(event.context.statusCode, 503)
        }
        let e = try explanation(record(status: nil))
        XCTAssertEqual(e.kind, .unknown)
        XCTAssertEqual(e.evidence, .unavailable)
    }

    func testSuccessAndCanceledEventsNeverOfferFailureAdvice() throws {
        let success = CPAUsageEvent(record: try record(status: 200, body: "insufficient_quota", failed: false))
        XCTAssertNil(success.context.failureKind)
        XCTAssertNil(CPAUsageFailureExplanation.make(for: success))
        for canceled in [try record(status: 499, body: "insufficient_quota"),
                         try record(body: #"{"error":{"message":"context canceled"}}"#)] {
            let event = CPAUsageEvent(record: canceled)
            XCTAssertEqual(event.outcome, .canceled)
            XCTAssertNil(event.context.failureKind)
            XCTAssertNil(CPAUsageFailureExplanation.make(for: event))
        }
    }

    func testOldSavedContextWithOnlyStatusRemainsReadable() throws {
        let data = Data(#"{"timestamp":"2026-10-15T02:00:00Z","provider":"p","model":"m","failed":true,"context":{"statusCode":429,"canceled":false,"generate":true}}"#.utf8)
        let old = try JSONDecoder().decode(UsageRecord.self, from: data)
        XCTAssertNil(old.context?.failureKind)
        XCTAssertEqual(try explanation(old).kind, .rateOrQuota)
        XCTAssertEqual(try explanation(old).evidence, .statusCode)
        let restored = try JSONDecoder().decode(UsageRecord.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(restored, old)
    }

    func testQueueRoundTripAndSQLiteReopenRetainOnlyFiniteClassification() async throws {
        let secret = "private-fixture-key-not-for-archive"
        let original = try record(status: 429,
            body: ["error": ["code": "insufficient_quota", "message": "Allowance exceeded " + secret],
                   "request": ["prompt": "private-prompt", "api_key": secret]])
        let encoded = try JSONEncoder().encode(original)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("private-prompt"))
        XCTAssertFalse(text.contains("Allowance exceeded"))
        let restored = try JSONDecoder().decode(UsageRecord.self, from: encoded)
        XCTAssertEqual(restored.context?.failureKind, .quotaExhausted)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("usage.sqlite")
        let ledger = UsageLedger(databaseURL: db)
        _ = try await ledger.ingest([restored], collectedAt: restored.timestamp)
        let reopened = UsageLedger(databaseURL: db)
        let page = try await reopened.queryEvents(CPAUsageQuery())
        XCTAssertEqual(page.events.count, 1)
        let e = try XCTUnwrap(page.events.first.flatMap(CPAUsageFailureExplanation.make))
        XCTAssertEqual(e.kind, .quotaExhausted)
        XCTAssertEqual(e.evidence, .errorInformation)
        XCTAssertFalse(e.help.contains(secret))
    }
}
