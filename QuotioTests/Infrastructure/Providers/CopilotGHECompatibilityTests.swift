import Foundation
import XCTest
@testable import QuotioPlus

/// 全部请求由注入 URLProtocol 截获，凭据落入临时元数据与内存保险库，不连接真实企业或钥匙串。
@MainActor
final class CopilotGHECompatibilityTests: XCTestCase {
    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        func read(_ key: String) -> Data? { lock.withLock { values[key] } }
        func save(_ data: Data, _ key: String) -> Bool { lock.withLock { values[key] = data; return true } }
        func remove(_ key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
        var backend: MonitorCredentialVault.Backend {
            .init(read: { self.read($0) }, save: { self.save($0, $1) },
                  compareAndSwap: { data, key, _ in self.save(data, key) }, delete: { self.remove($0) })
        }
    }
    private struct Fixture {
        let directory: URL
        let host: GitHubHost
        let session: URLSession
        let vault: MonitorCredentialVault
        let coordinator: MonitorOAuthCoordinator
        let http: LifecycleHTTPState
        var fetcher: CopilotQuotaFetcher {
            CopilotQuotaFetcher(session: session, vault: vault, nativePaths: [], authDirectory: directory.path)
        }
    }

    private func fixture(_ override: (@Sendable (URLRequest, Int) -> LifecycleHTTPState.Response?)? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ghe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = try XCTUnwrap(GitHubHost("test-" + UUID().uuidString.lowercased() + ".ghe.com"))
        let memory = Memory()
        let vault = MonitorCredentialVault(metadata: MonitorMetadataStore(url: directory.appendingPathComponent("accounts.json")), backend: memory.backend)
        let http = LifecycleHTTPState { request, index in
            if let result = override?(request, index) { return result }
            let enterprise = request.url!.host!.hasSuffix(".ghe.com")
            switch request.url!.path {
            case "/login/device/code":
                let domain = request.url!.host!
                return .reply("{\"device_code\":\"fixture-device\",\"user_code\":\"ABCD-EFGH\",\"verification_uri\":\"https://\(domain)/login/device\",\"interval\":0,\"expires_in\":900}")
            case "/login/oauth/access_token": return .reply(#"{"access_token":"fixture-github-token"}"#)
            case "/user": return .reply(#"{"login":"same-user","id":123}"#)
            case "/copilot_internal/user":
                return .reply("{\"copilot_plan\":\"business\",\"quota_snapshots\":{\"premium_interactions\":{\"percent_remaining\":\(enterprise ? 75 : 55)}}}")
            case "/copilot_internal/v2/token": return .reply(#"{"token":"fixture-api-token"}"#)
            case "/models": return .reply("{\"data\":[{\"id\":\"\(enterprise ? "enterprise-model" : "public-model")\",\"model_picker_enabled\":true}]}")
            default: return .fail(.badURL)
            }
        }
        let hosts = [host.value, "api." + host.value, "copilot-api." + host.value,
                     "github.com", "api.github.com", "api.githubcopilot.com"]
        for name in hosts { LifecycleHTTPProtocol.register(http, host: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        let coordinator = MonitorOAuthCoordinator(session: session, claudeVault: vault,
            openClaudeURL: { _ in true }, waitForGitHubPoll: { _ in try Task.checkCancellation() })
        addTeardownBlock {
            await coordinator.cancel()
            session.invalidateAndCancel()
            for name in hosts { LifecycleHTTPProtocol.remove(host: name) }
            try? FileManager.default.removeItem(at: directory)
        }
        return Fixture(directory: directory, host: host, session: session, vault: vault, coordinator: coordinator, http: http)
    }

    private func authFile(_ fixture: Fixture, name: String, host: Any? = nil) throws -> URL {
        let url = fixture.directory.appendingPathComponent(name)
        var object: [String: Any] = ["type": "copilot", "access_token": "same-fixture-token", "username": "same-user"]
        object["host"] = host
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    func testHostValidationAndDefaultCompatibility() throws {
        XCTAssertEqual(GitHubHost(" GitHub.com/ "), .githubCom)
        XCTAssertEqual(GitHubHost("https://Octo-Corp1.GHE.com/")?.value, "octo-corp1.ghe.com")
        for raw in ["", "ghe.com", "a.b.ghe.com", "-a.ghe.com", "a-.ghe.com", "a_ghe.com", "a.ghe.com:443",
                    "http://a.ghe.com", "a.ghe.com/path", "user@a.ghe.com", "a.ghe.com?x=1", "a.ghe.com#x",
                    "a.ghe.com.evil.invalid", "оcto.ghe.com", String(repeating: "a", count: 64) + ".ghe.com"] {
            XCTAssertNil(GitHubHost(raw), raw)
        }
        XCTAssertEqual(GitHubHost.saved(nil), .githubCom)
        XCTAssertNil(GitHubHost.saved(""))
        XCTAssertNil(GitHubHost.saved("a.ghe.com", alternate: "b.ghe.com"))
        XCTAssertEqual(GitHubHost.githubCom.accountKey("same-user"), "same-user")
    }

    func testInvalidDirectHostCannotResolvePersonalQuotaByEmail() {
        let file = DirectAuthFile(id: "invalid", provider: .copilot, email: "same-user", login: "same-user",
            expired: nil, accountType: nil, filePath: "/fixture/invalid.json", source: .cliProxyApi,
            filename: "invalid.json", githubHost: "invalid-host")
        XCTAssertNotEqual(file.menuBarAccountKey, "same-user")
        let result = MenuBarAccountCatalog.resolve(MenuBarQuotaItem(provider: AIProvider.copilot.rawValue,
            accountKey: file.menuBarAccountKey), mode: .localProxy, proxyRunning: false, authFiles: [],
            directFiles: [file], quotas: [.copilot: ["same-user": ProviderQuotaData(models: [])]])
        XCTAssertNil(result, "无效企业凭据不能借用个人账号快照")
    }

    func testCPAHostAliasesRejectNullInvalidTypesAndNestedConflicts() throws {
        let bad: [[String: Any]] = [
            ["github_host": NSNull(), "host": "github.com"],
            ["github_host": "", "host": "github.com"],
            ["github_host": 7, "host": "github.com"],
            ["github_host": "first.ghe.com", "githubHost": "second.ghe.com"],
            ["host": "github.com", "metadata": ["host": "first.ghe.com"]],
            ["host": "first.ghe.com", "metadata": ["github_host": NSNull()]]
        ]
        for fields in bad {
            var object: [String: Any] = ["name": "github-copilot-same-user.json", "provider": "copilot", "account": "same-user"]
            object.merge(fields) { _, new in new }
            let file = try JSONDecoder().decode(AuthFile.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(file.quotaMetadata.githubHost, "invalid-host")
            XCTAssertNotEqual(file.quotaLookupKey, "same-user")
        }
        let valid = try JSONDecoder().decode(AuthFile.self, from: Data(#"{"name":"copilot.json","provider":"copilot","account":"same-user","github_host":"FIRST.GHE.COM","metadata":{"host":"first.ghe.com"}}"#.utf8))
        XCTAssertEqual(valid.quotaLookupKey, "same-user@first.ghe.com")
    }

    func testNativeGHUsersKeepsAllAccountsAndHostScopedDeduplication() async throws {
        let f = try fixture()
        let path = f.directory.appendingPathComponent("hosts.yml")
        try """
        github.com:
          user: alice
          oauth_token: public-alice
          users:
            alice:
              oauth_token: public-alice
            bob:
              oauth_token: public-bob
        \(f.host.value):
          users:
            alice:
              oauth_token: enterprise-alice
            bob:
              oauth_token: enterprise-bob
        unsupported.example:
          users:
            alice:
              oauth_token: must-not-read
        """.write(to: path, atomically: true, encoding: .utf8)
        let values = CopilotQuotaFetcher.nativeCredentials(paths: [path.path])
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(Set(values.map { $0.host.accountKey($0.username ?? "") }),
            ["alice", "bob", "alice@" + f.host.value, "bob@" + f.host.value])
        XCTAssertFalse(values.contains { $0.token == "must-not-read" })
    }

    func testEnterprisePlaceholderIsReplacedOnlyBySameHostResolvedLogin() async throws {
        let f = try fixture()
        let path = f.directory.appendingPathComponent("apps.json")
        try JSONSerialization.data(withJSONObject: [f.host.value: ["oauth_token": "fixture-token"]]).write(to: path)
        let credential = try XCTUnwrap(CopilotQuotaFetcher.nativeCredentials(paths: [path.path]).first)
        let placeholder = MonitorAccount.make(provider: .copilot,
            accountKey: credential.host.accountKey("GitHub Copilot"), source: .nativeCredential)
        let fetcher = CopilotQuotaFetcher(session: f.session, vault: f.vault, nativePaths: [path.path],
            authDirectory: f.directory.appendingPathComponent("empty").path)
        let quotas = await fetcher.fetchAllCopilotQuotas(authDir: f.directory.appendingPathComponent("empty").path)
        XCTAssertNotNil(quotas[f.host.accountKey("same-user")])
        let real = MonitorAccount.make(provider: .copilot, accountKey: f.host.accountKey("same-user"), source: .nativeCredential)
        let other = MonitorAccount.make(provider: .copilot, accountKey: "same-user@other.ghe.com", source: .nativeCredential)
        XCTAssertEqual(MonitorRefreshCoordinator.removingHiddenPlaceholders([placeholder, other]).count, 2)
        XCTAssertEqual(MonitorRefreshCoordinator.removingHiddenPlaceholders([placeholder, real]), [real])
        XCTAssertTrue(MonitorRefreshCoordinator.isPlaceholder(provider: .copilot, accountKey: placeholder.accountKey))
    }

    func testEnterpriseDeviceFlowPersistsHostAndSeparatesSameNamedPublicAccount() async throws {
        let f = try fixture()
        let enterprise = try await f.coordinator.login(provider: .copilot, githubHost: f.host)
        let personal = try await f.coordinator.login(provider: .copilot)
        XCTAssertEqual(enterprise.accountKey, "same-user@" + f.host.value)
        XCTAssertEqual(personal.accountKey, "same-user")
        XCTAssertNotEqual(enterprise.id, personal.id)
        let storedValue = await f.vault.credential(for: enterprise.id)
        let publicValue = await f.vault.credential(for: personal.id)
        let stored = try XCTUnwrap(storedValue)
        let oldStyle = try XCTUnwrap(publicValue)
        XCTAssertEqual(stored.extra["github_host"], f.host.value)
        XCTAssertTrue(oldStyle.extra.isEmpty)
        let quotas = await f.fetcher.fetchAllCopilotQuotas(authDir: f.directory.path, includeMonitorCredentials: true)
        XCTAssertEqual(quotas[enterprise.accountKey]?.models.first?.percentage, 75)
        XCTAssertEqual(quotas[personal.accountKey]?.models.first?.percentage, 55)
        XCTAssertTrue(f.http.requests.contains { $0.url.host == "api." + f.host.value && $0.url.path == "/copilot_internal/user" })
        XCTAssertTrue(f.http.requests.filter { $0.url.path == "/login/oauth/access_token" }.allSatisfy {
            String(data: $0.body ?? Data(), encoding: .utf8)?.contains("device_code=fixture-device") == true
        })
    }

    func testDeviceVerificationPageCannotSwitchToAnotherHost() async throws {
        let f = try fixture { request, _ in
            request.url?.path == "/login/device/code"
                ? .reply(#"{"device_code":"fixture","user_code":"ABCD","verification_uri":"https://github.com/login/device","expires_in":900}"#) : nil
        }
        do { _ = try await f.coordinator.login(provider: .copilot, githubHost: f.host); XCTFail("必须拒绝其他主机验证页") }
        catch { XCTAssertTrue(error is MonitorOAuthError) }
        XCTAssertEqual(f.http.requestCount, 1)
        let accounts = await f.vault.accounts()
        XCTAssertTrue(accounts.isEmpty)
    }

    func testHostFollowsAuthFileModelExchangeAndCache() async throws {
        let f = try fixture()
        let enterprise = try authFile(f, name: "github-copilot-enterprise.json", host: f.host.value)
        let personal = try authFile(f, name: "github-copilot-personal.json")
        let fetcher = f.fetcher
        let first = await fetcher.fetchAvailableModels(authFilePath: enterprise.path)
        let second = await fetcher.fetchAvailableModels(authFilePath: personal.path)
        _ = await fetcher.fetchAvailableModels(authFilePath: enterprise.path)
        XCTAssertEqual(first.map(\.id), ["enterprise-model"])
        XCTAssertEqual(second.map(\.id), ["public-model"])
        XCTAssertEqual(f.http.requests.filter { $0.url.path == "/models" }.count, 2)
        XCTAssertTrue(f.http.requests.contains { $0.url.host == "api." + f.host.value && $0.url.path == "/copilot_internal/v2/token" })
        let files = await DirectAuthFileService(authDirectory: f.directory).scanAllAuthFiles()
        XCTAssertEqual(files.first { $0.filename == enterprise.lastPathComponent }?.menuBarAccountKey, f.host.accountKey("same-user"))
        let data = try JSONSerialization.data(withJSONObject: ["name": enterprise.lastPathComponent, "provider": "copilot", "account": "same-user", "host": f.host.value])
        let api = try JSONDecoder().decode(AuthFile.self, from: data)
        XCTAssertEqual(api.quotaLookupKey, f.host.accountKey("same-user"))
    }

    func testInvalidSavedHostNeverFallsBackToPublicEndpoint() async throws {
        let f = try fixture()
        for (index, host) in ["evil.invalid" as Any, 123, "", NSNull()].enumerated() {
            let file = try authFile(f, name: "github-copilot-invalid-\(index).json", host: host)
            let quota = await f.fetcher.fetchQuota(authFilePath: file.path)
            let models = await f.fetcher.fetchAvailableModels(authFilePath: file.path)
            XCTAssertNil(quota); XCTAssertTrue(models.isEmpty)
        }
        XCTAssertEqual(f.http.requestCount, 0)
    }

    func testNativeJSONAndYAMLKeepHostAndOriginalUnicodePath() async throws {
        let f = try fixture()
        let json = f.directory.path + "/cafe\u{301}-hosts.json"
        let yaml = f.directory.path + "/cafe\u{301}-hosts.yml"
        try JSONSerialization.data(withJSONObject: ["\(f.host.value):app": ["oauth_token": "enterprise-token", "user": "same-user"],
                                                   "github.com:app": ["oauth_token": "public-token", "user": "same-user"],
                                                   "unsupported.example:app": ["oauth_token": "never-send"]]).write(to: URL(fileURLWithPath: json))
        try "\(f.host.value):\n  oauth_token: enterprise-token\n  user: same-user\nunsupported.example:\n  oauth_token: never-send\nlocalhost:\n  oauth_token: never-send-local\ncorp-github:\n  oauth_token: never-send-corp\ntokens:\n  oauth_token: never-send-wrapper\n".write(toFile: yaml, atomically: true, encoding: .utf8)
        let credentials = CopilotQuotaFetcher.nativeCredentials(paths: [json, yaml])
        XCTAssertEqual(credentials.count, 2)
        XCTAssertEqual(Set(credentials.map(\.host)), [f.host, .githubCom])
        XCTAssertFalse(credentials.contains { $0.token == "never-send" })
        XCTAssertEqual(Array(credentials[0].path.utf8), Array(json.utf8))
        let quotas = await CopilotQuotaFetcher(session: f.session, vault: f.vault, nativePaths: [json, yaml])
            .fetchAllCopilotQuotas(authDir: f.directory.path)
        XCTAssertEqual(Set(quotas.keys), ["same-user", f.host.accountKey("same-user")])
        let wrapped = f.directory.appendingPathComponent("wrapped.json")
        try JSONSerialization.data(withJSONObject: ["accounts": [["host": f.host.value, "oauth_token": "wrapped-token"]]])
            .write(to: wrapped)
        let leaves = CopilotQuotaFetcher.nativeCredentials(paths: [wrapped.path])
        XCTAssertEqual(leaves.count, 1)
        XCTAssertEqual(leaves.first?.host, f.host)
    }

    func testRedirectDoesNotForwardCredentialToAnotherHost() async throws {
        let outside = LifecycleHTTPState { _, _ in .fail(.badURL) }
        LifecycleHTTPProtocol.register(outside, host: "outside.invalid")
        defer { LifecycleHTTPProtocol.remove(host: "outside.invalid") }
        let f = try fixture { request, _ in
            request.url?.path == "/copilot_internal/user" ? .redirect("https://outside.invalid/collect") : nil
        }
        let file = try authFile(f, name: "github-copilot-enterprise.json", host: f.host.value)
        let quota = await f.fetcher.fetchQuota(authFilePath: file.path)
        XCTAssertNil(quota)
        XCTAssertEqual(f.http.requestCount, 1)
        XCTAssertFalse(f.http.requests.contains { $0.url.host == "outside.invalid" })
        XCTAssertEqual(outside.requestCount, 0)
    }

    func testRuntimeMergeKeepsHostAndLegacyAliasesNeverClaimPersonalQuota() async throws {
        let f = try fixture()
        let diskData = try JSONSerialization.data(withJSONObject: ["name": "github-copilot-same-user.json", "provider": "copilot",
            "account": "same-user", "host": f.host.value, "source": "file"])
        let runtime = try JSONDecoder().decode(AuthFile.self, from: Data(#"{"name":"github-copilot-same-user.json","provider":"copilot","account":"same-user","auth_index":"7"}"#.utf8))
        let disk = try JSONDecoder().decode(AuthFile.self, from: diskData)
        let merged = try XCTUnwrap(AuthFileIdentity.deduplicated([runtime, disk]).first)
        XCTAssertEqual(merged.quotaMetadata.githubHost, f.host.value)
        XCTAssertEqual(merged.quotaLookupKey, f.host.accountKey("same-user"))
        var direct = DirectAuthFile(id: "fixture", provider: .copilot, email: "old-personal", login: "same-user",
            expired: nil, accountType: nil, filePath: "/fixture/github-copilot-same-user.json", source: .cliProxyApi,
            filename: "github-copilot-same-user.json", legacyIdentityKeys: ["old-personal"], githubHost: f.host.value)
        direct.githubHost = f.host.value
        for running in [false, true] {
            let aliases = AuthFileIdentity.quotaAliases(mode: .localProxy, proxyRunning: running,
                authFiles: [runtime, disk], directFiles: [direct])
            XCTAssertNil(aliases[.copilot]?["same-user"])
            XCTAssertNil(aliases[.copilot]?["old-personal"])
        }
        let monitor = MonitorAccount.make(provider: .copilot, accountKey: direct.menuBarAccountKey, source: .nativeCredential)
        let aliases = MenuBarAccountCatalog.aliases(mode: .monitor, proxyRunning: false, authFiles: [], directFiles: [direct], monitorAccounts: [monitor])
        XCTAssertNil(aliases[.copilot]?["old-personal"])
        XCTAssertNil(aliases[.copilot]?["same-user"])
    }

    func testInvalidFileCannotHideValidNativePersonalCredential() async throws {
        let f = try fixture()
        _ = try authFile(f, name: "github-copilot-invalid.json", host: "unsupported.example")
        let native = f.directory.appendingPathComponent("hosts.json")
        try Data(#"{"github.com":{"user":"same-user","oauth_token":"public-token"}}"#.utf8).write(to: native)
        let fetcher = CopilotQuotaFetcher(session: f.session, vault: f.vault, nativePaths: [native.path], authDirectory: f.directory.path)
        let quota = await fetcher.fetchQuota(accountKey: "same-user")
        XCTAssertEqual(quota?.models.first?.percentage, 55)
        XCTAssertEqual(f.http.requests.first?.url.host, "api.github.com")
    }

    func testCancelledEnterpriseResponseCannotOverwriteNewPublicLogin() async throws {
        let gate = LifecycleHTTPResponseGate(), arrived = expectation(description: "旧企业 token 请求已挂起")
        let f = try fixture { request, _ in
            if request.url?.host?.hasSuffix(".ghe.com") == true, request.url?.path == "/login/oauth/access_token" {
                arrived.fulfill(); return .deferred(gate)
            }
            return nil
        }
        let old = Task { try await f.coordinator.login(provider: .copilot, githubHost: f.host) }
        await fulfillment(of: [arrived], timeout: 3)
        let cutoff = f.coordinator.advanceClaudeSession()
        await f.coordinator.cancel(throughClaudeRevision: cutoff)
        let current = try await f.coordinator.login(provider: .copilot)
        gate.release(.reply(#"{"access_token":"late-enterprise-token"}"#))
        do { _ = try await old.value; XCTFail("旧企业授权应失效") } catch { }
        let accounts = await f.vault.accounts()
        XCTAssertEqual(accounts.map(\.id), [current.id])
        let value = await f.vault.credential(for: current.id)
        let credential = try XCTUnwrap(value)
        XCTAssertEqual(credential.accessToken, "fixture-github-token")
        XCTAssertTrue(credential.extra.isEmpty)
    }
}
