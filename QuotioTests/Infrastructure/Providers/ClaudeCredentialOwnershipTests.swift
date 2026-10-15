import XCTest
@testable import QuotioPlus

/// 上游凭据边界回归全部使用临时目录、内存保险库和 URLProtocol，不访问真实账号或钥匙串。
final class ClaudeCredentialOwnershipTests: XCTestCase {
    private var root: URL!
    private var native: URL { root.appendingPathComponent("native") }
    private var owned: URL { root.appendingPathComponent("owned") }
    private var environment: [String: String] { ["CLAUDE_CONFIG_DIR": native.path] }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        ClaudeOwnershipProtocol.reset()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func fixture(email: String = "person@example.com", access: String = "expired", refresh: String = "external") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "email": email, "access_token": access, "refresh_token": refresh,
            "expired": "2020-01-01T00:00:00.123Z", "preserved": "user-setting"
        ])
    }

    private func fetcher(keychain: Data? = nil) -> ClaudeCodeQuotaFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeOwnershipProtocol.self]
        return ClaudeCodeQuotaFetcher(authDir: owned.path, environment: environment, vault: EmptyClaudeVault(),
                                      session: URLSession(configuration: configuration), keychainData: { keychain },
                                      desktopCredential: { nil })
    }

    func testExpiredNativeFileIsReadOnlyAndDoesNotRequestQuotioLogin() async throws {
        let path = native.appendingPathComponent(".credentials.json")
        let original = try fixture()
        try original.write(to: path)
        let quotas = await fetcher().fetchAsProviderQuota(forceRefresh: true)
        XCTAssertTrue(quotas.isEmpty)
        XCTAssertEqual(ClaudeOwnershipProtocol.refreshCount, 0)
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testExpiredKeychainCredentialNeverRefreshes() async throws {
        let quotas = try await fetcher(keychain: fixture()).fetchAsProviderQuota(forceRefresh: true)
        XCTAssertTrue(quotas.isEmpty)
        XCTAssertEqual(ClaudeOwnershipProtocol.refreshCount, 0)
    }

    func testOwnedFileRefreshPersistsOnlyToMatchingFile() async throws {
        let nativePath = native.appendingPathComponent(".credentials.json")
        let external = try fixture()
        try external.write(to: nativePath)
        let path = owned.appendingPathComponent("claude-person.json")
        try fixture(refresh: "independent-owned").write(to: path)
        let quotas = await fetcher().fetchAsProviderQuota(forceRefresh: true)
        XCTAssertEqual(quotas["person@example.com"]?.models.first?.percentage, 75)
        XCTAssertEqual(ClaudeOwnershipProtocol.refreshCount, 1)
        XCTAssertEqual(try Data(contentsOf: nativePath), external)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual(saved["access_token"] as? String, "fresh")
        XCTAssertEqual(saved["refresh_token"] as? String, "rotated")
        XCTAssertEqual(saved["preserved"] as? String, "user-setting")
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testCopiedExternalTokenRemainsReadOnlyAcrossDifferentAccountNames() async throws {
        try fixture().write(to: native.appendingPathComponent(".credentials.json"))
        let copy = owned.appendingPathComponent("claude-copy.json")
        let original = try fixture(email: "copy@example.com")
        try original.write(to: copy)
        let quotas = await fetcher().fetchAsProviderQuota(forceRefresh: true)
        XCTAssertTrue(quotas.isEmpty)
        XCTAssertEqual(ClaudeOwnershipProtocol.refreshCount, 0)
        XCTAssertEqual(try Data(contentsOf: copy), original)
    }

    func testScopedCopiedKeychainTokenRemainsReadOnly() async throws {
        try fixture(email: "copy@example.com").write(to: owned.appendingPathComponent("claude-copy.json"))
        let quota = try await fetcher(keychain: fixture()).fetchQuota(accountKey: "copy@example.com", forceRefresh: true)
        XCTAssertNil(quota)
        XCTAssertEqual(ClaudeOwnershipProtocol.refreshCount, 0)
    }

    func testNativeAuthenticationFailureKeepsLastSuccessfulQuota() async throws {
        let path = native.appendingPathComponent(".credentials.json")
        try fixture(access: "valid").write(to: path)
        let reader = fetcher()
        let first = await reader.fetchAsProviderQuota(forceRefresh: true)
        try fixture().write(to: path)
        let second = await reader.fetchAsProviderQuota(forceRefresh: true)
        XCTAssertEqual(second["person@example.com"]?.lastUpdated, first["person@example.com"]?.lastUpdated)
        XCTAssertEqual(second["person@example.com"]?.models.first?.percentage, 75)
        XCTAssertEqual(ClaudeOwnershipProtocol.refreshCount, 0)
    }

    /// 模拟 usage 挂起时钥匙串出现相同外部令牌，刷新和错误提示都必须遵守最新归属。
    func testOwnershipChangeDuringUnauthorizedResponseKeepsCachedQuota() async throws {
        let path = owned.appendingPathComponent("claude-person.json")
        func currentData(access: String) throws -> Data {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture(access: access)) as? [String: Any])
            json["expired"] = "2030-01-01T00:00:00Z"
            return try JSONSerialization.data(withJSONObject: json)
        }
        try currentData(access: "valid").write(to: path)
        let keychain = ClaudeFixtureDataBox()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeOwnershipProtocol.self]
        let reader = ClaudeCodeQuotaFetcher(authDir: owned.path, environment: environment, vault: EmptyClaudeVault(),
                                            session: URLSession(configuration: configuration), keychainData: { keychain.read() },
                                            desktopCredential: { nil })
        let first = await reader.fetchAsProviderQuota(forceRefresh: true)
        try currentData(access: "expired").write(to: path)
        let external = try fixture()
        ClaudeOwnershipProtocol.setUsageCallback { keychain.write(external) }
        let second = await reader.fetchAsProviderQuota(forceRefresh: true)
        XCTAssertEqual(ClaudeOwnershipProtocol.refreshCount, 0)
        XCTAssertEqual(second["person@example.com"]?.isForbidden, false)
        XCTAssertEqual(second["person@example.com"]?.lastUpdated, first["person@example.com"]?.lastUpdated)
        XCTAssertEqual(second["person@example.com"]?.models.first?.percentage, 75)
    }

    func testSymbolicLinksAndLinkedParentAreRejected() throws {
        let real = owned.appendingPathComponent("claude-real.json")
        try fixture(refresh: "owned").write(to: real)
        let link = owned.appendingPathComponent("claude-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertNil(ClaudeQuotaCredential.load(path: link.path, environment: environment))
        let parentLink = root.appendingPathComponent("parent-link")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: owned)
        XCTAssertNil(ClaudeQuotaCredential.load(path: parentLink.appendingPathComponent(real.lastPathComponent).path, environment: environment))
    }

    func testHardLinkedOwnedFileIsReadOnly() throws {
        let original = native.appendingPathComponent(".credentials.json")
        try fixture().write(to: original)
        let alias = owned.appendingPathComponent("claude-alias.json")
        try FileManager.default.linkItem(at: original, to: alias)
        XCTAssertEqual(ClaudeQuotaCredential.load(path: alias.path, environment: environment)?.allowsRefresh, false)
    }

    func testVerifiedDescriptorRejectsReplacementAtWriteTime() throws {
        let path = owned.appendingPathComponent("claude-original.json")
        try fixture().write(to: path)
        let opened = try XCTUnwrap(SecureClaudeCredentialFile(path: path.path))
        try FileManager.default.removeItem(at: path)
        let replacement = try fixture(email: "replacement@example.com")
        try replacement.write(to: path)
        XCTAssertFalse(opened.replaceAtomically(with: Data("overwrite".utf8)))
        XCTAssertEqual(try Data(contentsOf: path), replacement)
    }

    func testSelectionIsIndependentOfSourceOrderAndKeepsUsableExternalToken() throws {
        let external = try XCTUnwrap(ClaudeQuotaCredential.load(data: fixture(access: "valid"), allowsRefresh: false))
        let expiredExternal = ClaudeQuotaCredential(accountKey: external.accountKey, accessToken: "old", refreshToken: "another", expiresAt: .distantPast, allowsRefresh: false)
        let validExternal = ClaudeQuotaCredential(accountKey: external.accountKey, accessToken: "valid", refreshToken: "external", expiresAt: .distantFuture, allowsRefresh: false)
        let own = try XCTUnwrap(ClaudeQuotaCredential.load(data: fixture(refresh: "independent"), allowsRefresh: true))
        for values in [[external, own], [own, external]] {
            XCTAssertEqual(ClaudeQuotaCredential.uniqueByAccountKey(values).first?.refreshToken, "independent")
        }
        for values in [[expiredExternal, validExternal], [validExternal, expiredExternal]] {
            XCTAssertEqual(ClaudeQuotaCredential.uniqueByAccountKey(values).first?.accessToken, "valid")
        }
        let copied = try XCTUnwrap(ClaudeQuotaCredential.load(data: fixture(email: "alias", refresh: "external"), allowsRefresh: true))
        for values in [[copied, validExternal], [validExternal, copied]] {
            XCTAssertTrue(ClaudeQuotaCredential.uniqueByAccountKey(values).allSatisfy { !$0.allowsRefresh })
        }
    }
}

nonisolated private struct EmptyClaudeVault: MonitorCredentialStore {
    func accounts() async -> [MonitorAccount] { [] }
    func credential(for accountID: String) async -> MonitorOAuthCredential? { nil }
    func reloadLatest(accountID: String) async -> MonitorOAuthCredential? { nil }
    func save(_ credential: MonitorOAuthCredential, metadata account: MonitorAccount) async throws {}
    func delete(accountID: String) async {}
}

/// 本套用例按仓库约定串行执行；锁保护 URLSession 的回调线程与测试线程之间的计数。
nonisolated private final class ClaudeOwnershipProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var refreshRequests = 0
    static var refreshCount: Int { lock.withLock { refreshRequests } }
    nonisolated(unsafe) private static var usageCallback: (@Sendable () -> Void)?
    static func reset() { lock.withLock { refreshRequests = 0; usageCallback = nil } }
    static func setUsageCallback(_ callback: @escaping @Sendable () -> Void) {
        lock.withLock { usageCallback = callback }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isRefresh = request.url?.path == "/v1/oauth/token"
        let authenticated = ["Bearer valid", "Bearer fresh"].contains(request.value(forHTTPHeaderField: "Authorization") ?? "")
        if isRefresh { Self.lock.withLock { Self.refreshRequests += 1 } }
        if !isRefresh {
            let callback = Self.lock.withLock { Self.usageCallback }
            callback?()
        }
        let status = isRefresh || authenticated ? 200 : 401
        let body = isRefresh
            ? #"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#
            : #"{"five_hour":{"utilization":25,"resets_at":"2030-01-01T00:00:00Z"}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// 用锁模拟外部进程在请求挂起期间变更钥匙串内容，测试不会访问系统钥匙串。
nonisolated private final class ClaudeFixtureDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func read() -> Data? { lock.withLock { data } }
    func write(_ value: Data) { lock.withLock { data = value } }
}
