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
        addTeardownBlock {
            session.invalidateAndCancel()
            for name in hosts { LifecycleHTTPProtocol.remove(host: name) }
            try? FileManager.default.removeItem(at: directory)
        }
        return Fixture(directory: directory, host: host, session: session, vault: vault, http: http)
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
            accountKey: file.menuBarAccountKey), authFiles: [], quotas: [.copilot: ["same-user": ProviderQuotaData(models: [])]])
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
        let fetcher = CopilotQuotaFetcher(session: f.session, vault: f.vault, nativePaths: [path.path],
            authDirectory: f.directory.appendingPathComponent("empty").path)
        let quotas = await fetcher.fetchAllCopilotQuotas(authDir: f.directory.appendingPathComponent("empty").path)
        XCTAssertNotNil(quotas[f.host.accountKey("same-user")])
        XCTAssertNil(quotas[credential.host.accountKey("GitHub Copilot")])
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
        let aliases = MenuBarAccountCatalog.aliases(authFiles: [merged])
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

    private func cpaClient(catalog: String, credential: String) -> (ManagementAPIClient, LifecycleHTTPState) {
        let host = "copilot-cpa-\(UUID().uuidString.lowercased()).invalid"
        let http = LifecycleHTTPState { request, _ in
            switch request.url?.path {
            case "/v8/management/credentials": return .reply(catalog)
            case "/v8/management/credentials/download": return .reply(credential)
            default: return .fail(.badURL)
            }
        }
        LifecycleHTTPProtocol.register(http, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        let baseURL = ManagementAPIClient.managementURL(for: "http://\(host)")
        let client = ManagementAPIClient(baseURL: baseURL, authKey: "fixture-management", configuration: configuration)
        addTeardownBlock {
            await client.invalidate()
            LifecycleHTTPProtocol.remove(host: host)
        }
        return (client, http)
    }

    func testCPASupplementDownloadsOnlyTheSelectedFileAndUsesItsVerifiedHost() async throws {
        let f = try fixture()
        let runtime = #"{"name":"explicit+account.json","provider":"github-copilot","account":"same-user","auth_index":"copilot-a","runtime_only":true}"#
        let disk = #"{"name":"explicit+account.json","provider":"copilot","source":"file","github_host":"\#(f.host.value)"}"#
        let sibling = #"{"name":"sibling.json","provider":"copilot","account":"same-user","auth_index":"copilot-b"}"#
        let copies = try JSONDecoder().decode([AuthFile].self, from: Data("[\(runtime),\(disk)]".utf8))
        let file = try XCTUnwrap(AuthFileIdentity.deduplicated(copies).first)
        let (client, management) = cpaClient(catalog: #"{"files":[\#(runtime),\#(disk),\#(sibling)]}"#,
            credential: #"{"type":"copilot","access_token":"fixture-exact","username":"SAME-USER","github_host":"\#(f.host.value)"}"#)

        let quota = try await CPAQuotaFetcher(client: client, copilot: f.fetcher).fetchSupplemental(file: file)

        XCTAssertEqual(quota.models.first?.percentage, 75)
        XCTAssertEqual(management.requests.map(\.url.path), ["/v8/management/credentials/download", "/v8/management/credentials"])
        let download = try XCTUnwrap(management.requests.first?.url)
        XCTAssertEqual(URLComponents(url: download, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "name", value: file.name)])
        XCTAssertTrue(management.requests.allSatisfy { $0.authorization == "Bearer fixture-management" })
        XCTAssertEqual(f.http.requests.map(\.url.path), ["/user", "/copilot_internal/user"])
        XCTAssertTrue(f.http.requests.allSatisfy { $0.url.host == "api." + f.host.value && $0.authorization == "Bearer fixture-exact" })
    }

    func testCPASupplementRejectsConflictingDirectoryIndexOrCredentialIdentityBeforeGitHub() async throws {
        let f = try fixture()
        let catalogRow = #"{"name":"selected.json","provider":"copilot","account":"same-user","auth_index":"current","github_host":"\#(f.host.value)"}"#
        let file = try JSONDecoder().decode(AuthFile.self, from: Data(catalogRow.utf8))
        let known = #""type":"copilot","access_token":"fixture-exact","username":"same-user","github_host":"\#(f.host.value)""#
        let goodCatalog = #"{"files":[\#(catalogRow)]}"#
        let conflicts = [
            (goodCatalog, #"{\#(known),"auth_index":"other"}"#),
            (goodCatalog, #"{\#(known),"name":"another.json"}"#),
            (goodCatalog, #"{\#(known),"provider":"kiro"}"#),
            (goodCatalog, #"{\#(known),"login":"another-user"}"#),
            (goodCatalog, #"{\#(known),"metadata":{"host":"github.com"}}"#),
            (#"{"files":[\#(catalogRow),{"name":"selected.json","provider":"copilot","auth_index":"other"}]}"#, "{\(known)}"),
        ]
        for (catalog, credential) in conflicts {
            let (client, _) = cpaClient(catalog: catalog, credential: credential)
            do {
                _ = try await CPAQuotaFetcher(client: client, copilot: f.fetcher).fetchSupplemental(file: file)
                XCTFail("文件名、索引、提供商、登录或主机冲突必须拒绝")
            } catch QuotaFetchError.invalidResponse { }
            catch { XCTFail("应按凭据冲突拒绝，实际为 \(error)") }
        }
        XCTAssertEqual(f.http.requestCount, 0)
    }

    func testCPASupplementRejectsWrongVerifiedLoginAndDoesNotReadEntitlement() async throws {
        let f = try fixture { request, _ in
            request.url?.path == "/user" ? .reply(#"{"login":"actual-other-user","id":2}"#) : nil
        }
        let row = #"{"name":"fixture.json","provider":"copilot","account":"same-user","auth_index":"copilot-a"}"#
        let file = try JSONDecoder().decode(AuthFile.self, from: Data(row.utf8))
        let (client, _) = cpaClient(catalog: #"{"files":[\#(row)]}"#,
            credential: #"{"type":"copilot","access_token":"fixture-exact","login":"same-user"}"#)
        do {
            _ = try await CPAQuotaFetcher(client: client, copilot: f.fetcher).fetchSupplemental(file: file)
            XCTFail("有效但属于另一 GitHub 用户的 token 不能读取额度")
        } catch QuotaFetchError.invalidResponse { }
        XCTAssertEqual(f.http.requests.map(\.url.path), ["/user"])
    }

    private actor CPASession {
        private var generation = 0

        func advance() { generation += 1 }
        func isCurrent(_ expected: Int) -> Bool { generation == expected }
    }

    func testCPASupplementDoesNotRequestEntitlementAfterSessionChangesDuringUserLookup() async throws {
        let profileGate = LifecycleHTTPResponseGate()
        let profileStarted = expectation(description: "GitHub 用户验证已发出，等待离线返回")
        let f = try fixture { request, _ in
            guard request.url?.path == "/user" else { return nil }
            profileStarted.fulfill()
            return .deferred(profileGate)
        }
        let row = #"{"name":"fixture.json","provider":"copilot","account":"same-user","auth_index":"copilot-a"}"#
        let file = try JSONDecoder().decode(AuthFile.self, from: Data(row.utf8))
        let (client, _) = cpaClient(catalog: #"{"files":[\#(row)]}"#,
            credential: #"{"type":"copilot","access_token":"fixture-exact","login":"same-user"}"#)
        let session = CPASession()
        let fetcher = CPAQuotaFetcher(client: client, copilot: f.fetcher, isCurrent: { await session.isCurrent(0) })
        let refresh = Task { try await fetcher.fetchSupplemental(file: file) }

        await fulfillment(of: [profileStarted], timeout: 3)
        // 只换会话，刻意保留原手动任务，确认会话检查本身能阻断下一次出站。
        await session.advance()
        profileGate.release(.reply(#"{"login":"same-user","id":123}"#))

        do {
            _ = try await refresh.value
            XCTFail("旧会话的用户请求返回后应终止本轮补查")
        } catch is CancellationError { }
        XCTAssertEqual(f.http.requests.map(\.url.path), ["/user"])
    }

    func testCPASupplementPreservesHTTPStatusFromGitHubUserAndEntitlement() async throws {
        let row = #"{"name":"fixture.json","provider":"copilot","account":"same-user","auth_index":"copilot-a"}"#
        let file = try JSONDecoder().decode(AuthFile.self, from: Data(row.utf8))
        let (client, _) = cpaClient(catalog: #"{"files":[\#(row)]}"#,
            credential: #"{"type":"copilot","access_token":"fixture-exact","login":"same-user"}"#)
        for (path, status) in [("/user", 401), ("/user", 403), ("/user", 429), ("/copilot_internal/user", 403)] {
            let f = try fixture { request, _ in
                request.url?.path == path ? .replyStatus(#"{"message":"sensitive-fixture"}"#, status) : nil
            }
            do {
                _ = try await CPAQuotaFetcher(client: client, copilot: f.fetcher).fetchSupplemental(file: file)
                XCTFail("GitHub 返回的 HTTP 状态应进入 CPA 错误处理")
            } catch QuotaFetchError.httpError(let actual) {
                XCTAssertEqual(actual, status)
            }
            // 首次身份请求被拒绝时不能发额度请求；额度端报错前则应完成用户验证。
            let paths = path == "/user" ? ["/user"] : ["/user", path]
            XCTAssertEqual(f.http.requests.map(\.url.path), paths)
        }
    }

    func testCPASupplementPreservesTimeoutAndRecognizesCancellationDuringGitHubUserLookup() async throws {
        let row = #"{"name":"fixture.json","provider":"copilot","account":"same-user","auth_index":"copilot-a"}"#
        let file = try JSONDecoder().decode(AuthFile.self, from: Data(row.utf8))
        let (client, _) = cpaClient(catalog: #"{"files":[\#(row)]}"#,
            credential: #"{"type":"copilot","access_token":"fixture-exact","login":"same-user"}"#)
        for code in [URLError.Code.timedOut, .cancelled] {
            let f = try fixture { request, _ in request.url?.path == "/user" ? .fail(code) : nil }
            do {
                _ = try await CPAQuotaFetcher(client: client, copilot: f.fetcher).fetchSupplemental(file: file)
                XCTFail("GitHub 用户验证的传输失败不能成为新额度")
            } catch is CancellationError {
                XCTAssertEqual(code, .cancelled)
            } catch let error as URLError {
                XCTAssertEqual(code, .timedOut)
                XCTAssertEqual(error.code, .timedOut)
            }
            XCTAssertEqual(f.http.requests.map(\.url.path), ["/user"])
        }
    }

    func testCPASupplementRejectsHTTP200WithOnlyUnknownQuota() async throws {
        let f = try fixture { request, _ in
            request.url?.path == "/copilot_internal/user"
                ? .reply(#"{"quota_snapshots":{"premium_interactions":{"remaining":25}}}"#) : nil
        }
        let row = #"{"name":"fixture.json","provider":"copilot","account":"same-user","auth_index":"copilot-a"}"#
        let file = try JSONDecoder().decode(AuthFile.self, from: Data(row.utf8))
        let (client, _) = cpaClient(catalog: #"{"files":[\#(row)]}"#,
            credential: #"{"type":"copilot","access_token":"fixture-exact","username":"same-user"}"#)
        do {
            _ = try await CPAQuotaFetcher(client: client, copilot: f.fetcher).fetchSupplemental(file: file)
            XCTFail("全未知的额度不可刷新已知快照")
        } catch QuotaFetchError.invalidResponse { }
        XCTAssertEqual(f.http.requests.map(\.url.path), ["/user", "/copilot_internal/user"])
    }
}
