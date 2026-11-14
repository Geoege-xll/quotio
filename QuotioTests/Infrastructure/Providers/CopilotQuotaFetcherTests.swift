import XCTest
@testable import QuotioPlus

final class CopilotQuotaFetcherTests: XCTestCase {
    // Issue #404: a single auth file (github-copilot-marcosvrs.json with
    // username "marcosvrs") must resolve to exactly one quota entry, with every
    // legacy key collapsing onto the canonical account key.
    func testSingleAuthFileCollapsesLegacyKeysIntoOneEntry() {
        let staleDate = Date(timeIntervalSince1970: 1_000)
        let freshDate = Date(timeIntervalSince1970: 2_000)
        let identity = CopilotQuotaFetcher.accountIdentity(
            filename: "github-copilot-marcosvrs.json",
            username: "marcosvrs"
        )

        let reconciled = CopilotQuotaFetcher.reconcileLegacyAliases(
            in: [
                "github-copilot-marcosvrs.json": ProviderQuotaData(models: [], lastUpdated: staleDate),
                "github-copilot-marcosvrs": ProviderQuotaData(models: [], lastUpdated: staleDate),
                "marcosvrs": ProviderQuotaData(models: [], lastUpdated: freshDate),
            ],
            accounts: [identity]
        )

        XCTAssertEqual(Set(reconciled.keys), ["marcosvrs"])
        XCTAssertEqual(reconciled["marcosvrs"]?.lastUpdated, freshDate)
    }

    func testAccountIdentityPrefersUsernameOverFilenameSuffix() {
        let identity = CopilotQuotaFetcher.accountIdentity(
            filename: "github-copilot-work.json",
            username: "marcosvrs"
        )

        XCTAssertEqual(identity.canonicalKey, "marcosvrs")
        XCTAssertEqual(
            Set(identity.aliases),
            ["github-copilot-work.json", "github-copilot-work", "work"]
        )
    }

    func testAccountIdentityFallsBackToFilenameSuffixWithoutUsername() {
        let identity = CopilotQuotaFetcher.accountIdentity(
            filename: "github-copilot-marcosvrs.json",
            username: nil
        )

        XCTAssertEqual(identity.canonicalKey, "marcosvrs")
    }

    func testLegacyFilenameKeyMigratesWhenUsernameDiffersFromSuffix() {
        let staleDate = Date(timeIntervalSince1970: 1_000)
        let reconciled = CopilotQuotaFetcher.reconcileLegacyAliases(
            in: [
                "github-copilot-work.json": ProviderQuotaData(models: [], lastUpdated: staleDate),
            ],
            accounts: [
                CopilotQuotaFetcher.accountIdentity(
                    filename: "github-copilot-work.json",
                    username: "marcosvrs"
                ),
            ]
        )

        XCTAssertEqual(Set(reconciled.keys), ["marcosvrs"])
        XCTAssertEqual(reconciled["marcosvrs"]?.lastUpdated, staleDate)
    }

    func testReconciliationPreservesNewerCanonicalQuota() {
        let staleDate = Date(timeIntervalSince1970: 1_000)
        let freshDate = Date(timeIntervalSince1970: 2_000)
        let reconciled = CopilotQuotaFetcher.reconcileLegacyAliases(
            in: [
                "marcosvrs": ProviderQuotaData(models: [], lastUpdated: freshDate),
                "github-copilot-marcosvrs.json": ProviderQuotaData(models: [], lastUpdated: staleDate),
            ],
            accounts: [
                CopilotQuotaFetcher.accountIdentity(
                    filename: "github-copilot-marcosvrs.json",
                    username: "marcosvrs"
                ),
            ]
        )

        XCTAssertEqual(Set(reconciled.keys), ["marcosvrs"])
        XCTAssertEqual(reconciled["marcosvrs"]?.lastUpdated, freshDate)
    }

    func testReconciliationPromotesNewerLegacyQuota() {
        let staleDate = Date(timeIntervalSince1970: 1_000)
        let freshDate = Date(timeIntervalSince1970: 2_000)
        let reconciled = CopilotQuotaFetcher.reconcileLegacyAliases(
            in: [
                "marcosvrs": ProviderQuotaData(models: [], lastUpdated: staleDate),
                "github-copilot-marcosvrs.json": ProviderQuotaData(models: [], lastUpdated: freshDate),
            ],
            accounts: [
                CopilotQuotaFetcher.accountIdentity(
                    filename: "github-copilot-marcosvrs.json",
                    username: "marcosvrs"
                ),
            ]
        )

        XCTAssertEqual(Set(reconciled.keys), ["marcosvrs"])
        XCTAssertEqual(reconciled["marcosvrs"]?.lastUpdated, freshDate)
    }

    func testAliasMatchingAnotherAccountCanonicalKeyIsPreserved() {
        let date = Date(timeIntervalSince1970: 1_000)
        let quotas = [
            "marcosvrs": ProviderQuotaData(models: [], lastUpdated: date),
            "someone-else": ProviderQuotaData(models: [], lastUpdated: date),
        ]

        let reconciled = CopilotQuotaFetcher.reconcileLegacyAliases(
            in: quotas,
            accounts: [
                // File whose suffix collides with another account's username.
                CopilotQuotaFetcher.accountIdentity(
                    filename: "github-copilot-marcosvrs.json",
                    username: "someone-else"
                ),
                CopilotQuotaFetcher.accountIdentity(
                    filename: "github-copilot-other.json",
                    username: "marcosvrs"
                ),
            ]
        )

        XCTAssertEqual(Set(reconciled.keys), ["marcosvrs", "someone-else"])
    }

    func testAmbiguousAliasIsNotCollapsed() {
        let date = Date(timeIntervalSince1970: 1_000)
        let reconciled = CopilotQuotaFetcher.reconcileLegacyAliases(
            in: [
                "shared-alias": ProviderQuotaData(models: [], lastUpdated: date),
            ],
            accounts: [
                CopilotQuotaAccountIdentity(canonicalKey: "first", aliases: ["shared-alias"]),
                CopilotQuotaAccountIdentity(canonicalKey: "second", aliases: ["shared-alias"]),
            ]
        )

        XCTAssertEqual(Set(reconciled.keys), ["shared-alias"])
    }

    func testDirectAuthFileMenuBarKeyIsCanonicalForUsernameField() {
        // ~/.cli-proxy-api/github-copilot-marcosvrs.json stores the GitHub
        // handle in "username"; DirectAuthFileService maps it to `login`.
        let file = DirectAuthFile(
            id: "/tmp/github-copilot-marcosvrs.json",
            provider: .copilot,
            email: nil,
            login: "marcosvrs",
            expired: nil,
            accountType: nil,
            filePath: "/tmp/github-copilot-marcosvrs.json",
            source: .cliProxyApi,
            filename: "github-copilot-marcosvrs.json"
        )

        XCTAssertEqual(file.menuBarAccountKey, "marcosvrs")
    }

    func testDirectAuthFileMenuBarKeyFallsBackToFilenameSuffix() {
        let file = DirectAuthFile(
            id: "/tmp/github-copilot-marcosvrs.json",
            provider: .copilot,
            email: nil,
            login: nil,
            expired: nil,
            accountType: nil,
            filePath: "/tmp/github-copilot-marcosvrs.json",
            source: .cliProxyApi,
            filename: "github-copilot-marcosvrs.json"
        )

        XCTAssertEqual(file.menuBarAccountKey, "marcosvrs")
    }

    // MARK: - Canonical Field Precedence (shared rule)

    // The parser and the fetcher must resolve the same file to the same field.
    // CopilotQuotaFetcher keys quota results by JSON `username`, so `username`
    // wins over `login` everywhere.
    func testCanonicalIdentityFieldPrefersUsernameOverLogin() {
        XCTAssertEqual(
            CopilotQuotaFetcher.canonicalIdentityField(username: "marcosvrs", login: "marcos-legacy"),
            "marcosvrs"
        )
        XCTAssertEqual(
            CopilotQuotaFetcher.canonicalIdentityField(username: "   ", login: "marcos-legacy"),
            "marcos-legacy"
        )
        XCTAssertNil(CopilotQuotaFetcher.canonicalIdentityField(username: nil, login: nil))
    }

    func testParsedAuthFileAndFetcherAgreeWhenLoginAndUsernameDiffer() async throws {
        let directory = try Self.makeTemporaryAuthDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try Self.writeCopilotAuthFile(
            named: "github-copilot-work.json",
            in: directory,
            fields: ["username": "marcosvrs", "login": "marcos-legacy"]
        )

        let service = DirectAuthFileService(
            authDirectory: URL(fileURLWithPath: directory, isDirectory: true)
        )
        let scanned = await service.scanAllAuthFiles()
        let parsed = try XCTUnwrap(scanned.first)
        let identity = CopilotQuotaFetcher.accountIdentity(
            filename: "github-copilot-work.json",
            username: "marcosvrs",
            login: "marcos-legacy"
        )

        // One file, one key on both sides.
        XCTAssertEqual(parsed.menuBarAccountKey, "marcosvrs")
        XCTAssertEqual(identity.canonicalKey, "marcosvrs")
        XCTAssertEqual(parsed.menuBarAccountKey, identity.canonicalKey)
        // The field that used to win stays available for selection migration.
        XCTAssertEqual(parsed.legacyIdentityKeys, ["marcos-legacy"])
    }

    // MARK: - Provider-Scoped Monitor Refresh

    // Refreshing ONLY Copilot goes through MonitorRefreshCoordinator.refresh,
    // which merges `previous` into the fetcher output. Reconciling the fetcher
    // output alone is not enough — the merged dictionary is what gets stored, so
    // the stale filename key would survive and #404 would come back for anyone
    // who uses the per-provider refresh button.
    func testScopedMonitorRefreshCollapsesStaleKeyFromCoordinatorMerge() async throws {
        let directory = try Self.makeTemporaryAuthDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try Self.writeCopilotAuthFile(
            named: "github-copilot-marcosvrs.json",
            in: directory,
            fields: ["username": "marcosvrs"]
        )

        let staleDate = Date(timeIntervalSince1970: 1_000)
        let freshDate = Date(timeIntervalSince1970: 2_000)
        // Snapshot written by an older release, keyed by the full filename.
        let previous = [
            "github-copilot-marcosvrs.json": ProviderQuotaData(models: [], lastUpdated: staleDate),
        ]
        let fetched = ["marcosvrs": ProviderQuotaData(models: [], lastUpdated: freshDate)]

        // Counterfactual: the coordinator merge on its own keeps BOTH keys.
        let merged = await MonitorRefreshCoordinator().refresh(
            provider: .copilot,
            force: true,
            previous: previous,
            credentialAvailability: .present
        ) {
            fetched
        }
        XCTAssertEqual(Set(merged.keys), ["github-copilot-marcosvrs.json", "marcosvrs"])

        // The production scoped-refresh path reconciles that merged result.
        let scoped = await QuotaViewModel.refreshCopilotThroughCoordinator(
            coordinator: MonitorRefreshCoordinator(),
            fetcher: CopilotQuotaFetcher(),
            previous: previous,
            credentialAvailability: .present,
            authDir: directory
        ) {
            fetched
        }

        XCTAssertEqual(Set(scoped.keys), ["marcosvrs"])
        XCTAssertEqual(scoped["marcosvrs"]?.lastUpdated, freshDate)
    }

    // MARK: - Keychain Account & Token Hardening

    /// 测试钥匙串账号合法性校验：允许合法 ASCII 标识，拒绝空字符串、github.com 主机名、超长字符串及非安全字符
    func testCopilotKeychainAccountValidation() {
        XCTAssertTrue(CopilotQuotaFetcher.isValidCopilotKeychainAccount("monalisa"))
        XCTAssertTrue(CopilotQuotaFetcher.isValidCopilotKeychainAccount("user-name_123"))
        XCTAssertTrue(CopilotQuotaFetcher.isValidCopilotKeychainAccount("A"))

        // 拒绝非法账号
        XCTAssertFalse(CopilotQuotaFetcher.isValidCopilotKeychainAccount(""))
        XCTAssertFalse(CopilotQuotaFetcher.isValidCopilotKeychainAccount("github.com"))
        XCTAssertFalse(CopilotQuotaFetcher.isValidCopilotKeychainAccount("user@github.com"))
        XCTAssertFalse(CopilotQuotaFetcher.isValidCopilotKeychainAccount("user.name"))
        XCTAssertFalse(CopilotQuotaFetcher.isValidCopilotKeychainAccount("user name"))
        XCTAssertFalse(CopilotQuotaFetcher.isValidCopilotKeychainAccount(String(repeating: "a", count: 257)))
    }

    /// 测试钥匙串令牌解码：支持常规令牌与 go-keyring-base64 编码令牌
    func testCopilotKeychainTokenDecoding() {
        // 常规令牌
        let plainData = "gho_1234567890abcdef".data(using: .utf8)!
        XCTAssertEqual(CopilotQuotaFetcher.decodeCopilotKeychainToken(plainData), "gho_1234567890abcdef")

        // 带有空白的令牌
        let paddedData = "  gho_1234567890abcdef \n".data(using: .utf8)!
        XCTAssertEqual(CopilotQuotaFetcher.decodeCopilotKeychainToken(paddedData), "gho_1234567890abcdef")

        // go-keyring-base64 编码令牌
        let rawToken = "gho_secret_token_from_keyring"
        let base64Token = Data(rawToken.utf8).base64EncodedString()
        let prefixedData = "go-keyring-base64:\(base64Token)".data(using: .utf8)!
        XCTAssertEqual(CopilotQuotaFetcher.decodeCopilotKeychainToken(prefixedData), rawToken)

        // 空数据或无效 base64
        XCTAssertNil(CopilotQuotaFetcher.decodeCopilotKeychainToken(Data()))
        XCTAssertNil(CopilotQuotaFetcher.decodeCopilotKeychainToken("   ".data(using: .utf8)!))
        let invalidPrefixed = "go-keyring-base64:!!!invalid-base64!!!".data(using: .utf8)!
        XCTAssertNil(CopilotQuotaFetcher.decodeCopilotKeychainToken(invalidPrefixed))
    }

    // MARK: - Helpers

    private static func makeTemporaryAuthDirectory() throws -> String {
        let directory = NSTemporaryDirectory() + "quotio-copilot-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func writeCopilotAuthFile(
        named filename: String,
        in directory: String,
        fields: [String: String]
    ) throws {
        var json: [String: String] = ["type": "copilot", "access_token": "ghu_test"]
        json.merge(fields) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: URL(fileURLWithPath: (directory as NSString).appendingPathComponent(filename)))
    }
}
