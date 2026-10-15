import XCTest
@testable import QuotioPlus

@MainActor
final class CustomProviderHeaderTests: XCTestCase {

    // MARK: - Helpers

    private func makeProvider(
        type: CustomProviderType,
        baseURL: String = "https://llm.internal/v1",
        apiKeys: [CustomAPIKeyEntry] = [CustomAPIKeyEntry(apiKey: "sk-test-1")],
        headers: [CustomHeader]
    ) -> CustomProvider {
        CustomProvider(
            name: "Private LLM",
            type: type,
            baseURL: baseURL,
            apiKeys: apiKeys,
            headers: headers
        )
    }

    private let sampleHeaders = [
        CustomHeader(key: "X-API-Key", value: "secret-token"),
        CustomHeader(key: "X-Tenant-ID", value: "team-a")
    ]

    // MARK: - Type gating

    func testSupportedTypesForCustomHeaders() {
        XCTAssertTrue(CustomProviderType.openaiCompatibility.supportsCustomHeaders)
        XCTAssertTrue(CustomProviderType.claudeCompatibility.supportsCustomHeaders)
        XCTAssertTrue(CustomProviderType.geminiCompatibility.supportsCustomHeaders)
        XCTAssertTrue(CustomProviderType.codexCompatibility.supportsCustomHeaders)
        XCTAssertFalse(CustomProviderType.glmCompatibility.supportsCustomHeaders)
        XCTAssertFalse(CustomProviderType.clinePass.supportsCustomHeaders)
    }

    // MARK: - Request-building path (the path the reviewer reproduced against CFNetwork)

    func testConnectionTestRequestSendsNormalizedHeaderName() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(key: " X-Tenant-ID ", value: " team-a ")]
        )

        var request = URLRequest(url: URL(string: "https://llm.internal/v1/models")!)
        request.applyCustomHeaders(provider.effectiveHeaders)

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tenant-ID"), "team-a")

        let sentNames = request.allHTTPHeaderFields?.keys.sorted() ?? []
        XCTAssertEqual(sentNames.count, 1)
        for name in sentNames {
            XCTAssertEqual(name, name.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertTrue(CustomHeader.isValidName(name), "request carried a non-token header name: \(name.debugDescription)")
        }
    }

    func testRequestHeadersMatchCanonicalProviderHeaders() {
        let rawFormHeaders = [
            CustomHeader(key: " X-API-Key ", value: "\tsecret-token "),
            CustomHeader(key: "X-Model-Version", value: "2024-12")
        ]

        // Fetch Models canonicalizes the raw form input; save persists the same call.
        let fetchModelsHeaders = CustomHeader.canonicalized(rawFormHeaders)
        XCTAssertTrue(CustomHeader.validationErrors(in: fetchModelsHeaders).isEmpty)

        var fetchRequest = URLRequest(url: URL(string: "https://llm.internal/v1/models")!)
        fetchRequest.applyCustomHeaders(fetchModelsHeaders)

        let provider = makeProvider(type: .openaiCompatibility, headers: fetchModelsHeaders)
        var testRequest = URLRequest(url: URL(string: "https://llm.internal/v1/models")!)
        testRequest.applyCustomHeaders(provider.effectiveHeaders)

        XCTAssertEqual(fetchRequest.value(forHTTPHeaderField: "X-API-Key"), "secret-token")
        XCTAssertEqual(testRequest.value(forHTTPHeaderField: "X-API-Key"), "secret-token")

        // 保存与测试请求使用同一组规范化请求头；v8 的实际 PATCH 另由 CPA8ProviderPatchTests 验证。
        for entry in provider.effectiveHeaders {
            XCTAssertEqual(fetchRequest.value(forHTTPHeaderField: entry.key), entry.value)
            XCTAssertEqual(testRequest.value(forHTTPHeaderField: entry.key), entry.value)
        }
    }

    func testEffectiveHeadersAreEmptyForUnsupportedProviderTypes() {
        for type in [CustomProviderType.glmCompatibility, .clinePass] {
            let provider = makeProvider(type: type, baseURL: "", headers: sampleHeaders)
            XCTAssertTrue(provider.effectiveHeaders.isEmpty, "\(type) must not send custom headers")
        }
    }

    func testEffectiveHeadersDropEntriesThatValidationWouldReject() {
        // Simulates a provider persisted before this validation existed.
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [
                CustomHeader(key: "Bad Name", value: "v"),
                CustomHeader(key: "X-Bad-Value", value: "a\r\nX-Injected: 1"),
                CustomHeader(key: "X-Good", value: "ok")
            ]
        )

        XCTAssertEqual(provider.effectiveHeaders.map(\.key), ["X-Good"])

        var request = URLRequest(url: URL(string: "https://llm.internal/v1/models")!)
        request.applyCustomHeaders(provider.effectiveHeaders)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Injected"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Bad-Value"))
    }

    // MARK: - Normalization

    func testCanonicalizedTrimsOptionalWhitespaceAndDropsUnnamedEntries() {
        let canonical = CustomHeader.canonicalized([
            CustomHeader(key: " X-Tenant-ID\t", value: "\t team-a "),
            CustomHeader(key: "   ", value: "ignored"),
            CustomHeader(key: "", value: "ignored")
        ])

        XCTAssertEqual(canonical.map { [$0.key, $0.value] }, [["X-Tenant-ID", "team-a"]])
    }

    func testCanonicalizedDoesNotStripNewlinesFromValues() {
        // Stripping would silently change a secret; validation must reject instead.
        let canonical = CustomHeader.canonicalized([CustomHeader(key: "X-Secret", value: " line1\nline2 ")])
        XCTAssertEqual(canonical.first?.value, "line1\nline2")
        XCTAssertFalse(CustomHeader.validationErrors(in: canonical).isEmpty)
    }

    func testHeaderNamesAreNormalizedBeforePersistenceValidation() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(key: " X-Tenant-ID ", value: " team-a ")]
        )
        XCTAssertTrue(provider.validate().isEmpty)
        XCTAssertEqual(provider.effectiveHeaders.map { [$0.key, $0.value] }, [["X-Tenant-ID", "team-a"]])
    }

    func testNormalizationMakesWhitespacePaddedDuplicatesDetectable() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [
                CustomHeader(key: "X-API-Key", value: "a"),
                CustomHeader(key: "  X-API-Key  ", value: "b")
            ]
        )
        XCTAssertFalse(provider.validate().isEmpty)
    }

    // MARK: - Header value validation

    func testIsValidValueAcceptsWireSafeValues() {
        XCTAssertTrue(CustomHeader.isValidValue(""))
        XCTAssertTrue(CustomHeader.isValidValue("secret-token"))
        XCTAssertTrue(CustomHeader.isValidValue("a: b, c=d; e"))
        XCTAssertTrue(CustomHeader.isValidValue("col-a\tcol-b"))
    }

    func testIsValidValueRejectsControlCharactersAndNonASCII() {
        XCTAssertFalse(CustomHeader.isValidValue("line1\nline2"))
        XCTAssertFalse(CustomHeader.isValidValue("line1\rline2"))
        XCTAssertFalse(CustomHeader.isValidValue("a\r\nX-Injected: 1"))
        XCTAssertFalse(CustomHeader.isValidValue("null\u{00}byte"))
        XCTAssertFalse(CustomHeader.isValidValue("delete\u{7F}"))
        XCTAssertFalse(CustomHeader.isValidValue("token\u{A0}"))
        XCTAssertFalse(CustomHeader.isValidValue("bí-mật"))
    }

    func testValidateRejectsHeaderValueWithLineBreak() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(key: "X-Secret", value: "line1\nline2")]
        )
        XCTAssertFalse(provider.validate().isEmpty)
    }

    func testValidateRejectsCRLFHeaderInjectionAttempt() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(key: "X-Tenant-ID", value: "team-a\r\nAuthorization: Bearer stolen")]
        )
        XCTAssertFalse(provider.validate().isEmpty)
    }

    // MARK: - Header name validation

    func testIsValidNameAcceptsRFC7230Tokens() {
        XCTAssertTrue(CustomHeader.isValidName("X-API-Key"))
        XCTAssertTrue(CustomHeader.isValidName("X-Model-Version"))
        XCTAssertTrue(CustomHeader.isValidName("x_custom.header~1"))
    }

    func testIsValidNameRejectsInvalidCharacters() {
        XCTAssertFalse(CustomHeader.isValidName(""))
        XCTAssertFalse(CustomHeader.isValidName("X API Key"))
        XCTAssertFalse(CustomHeader.isValidName("X-API-Key:"))
        XCTAssertFalse(CustomHeader.isValidName("Ключ"))
    }

    func testValidateRejectsInvalidHeaderName() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [CustomHeader(key: "Bad Name", value: "v")]
        )
        XCTAssertFalse(provider.validate().isEmpty)
    }

    func testValidateRejectsDuplicateHeaderNamesCaseInsensitively() {
        let provider = makeProvider(
            type: .openaiCompatibility,
            headers: [
                CustomHeader(key: "X-API-Key", value: "a"),
                CustomHeader(key: "x-api-key", value: "b")
            ]
        )
        XCTAssertFalse(provider.validate().isEmpty)
    }

    func testValidateAcceptsWellFormedHeaders() {
        let provider = makeProvider(type: .openaiCompatibility, headers: sampleHeaders)
        XCTAssertTrue(provider.validate().isEmpty)
    }

    // MARK: - Codable round-trip

    func testHeadersSurviveCodableRoundTrip() throws {
        let provider = makeProvider(type: .claudeCompatibility, headers: sampleHeaders)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(CustomProvider.self, from: encoder.encode(provider))
        XCTAssertEqual(decoded.headers, provider.headers)
    }

}

