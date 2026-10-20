import Foundation
import XCTest
@testable import QuotioPlus

/// 按官方 v8 路由、原始 JSON 值和副作用验证实际 URLSession 请求，不访问真实账号或外部服务。
/// 共用生命周期夹具，使 API 契约检查同时经过生产的鉴权、取消和重试实现。
final class CPA8ManagementAPIContractTests: XCTestCase {
    private func fixture(_ response: @escaping @Sendable (URLRequest, Int) -> LifecycleHTTPState.Response)
        -> (ManagementAPIClient, LifecycleHTTPState) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState(response: response)
        LifecycleHTTPProtocol.register(state, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LifecycleHTTPProtocol.self]
        let client = ManagementAPIClient(baseURL: ManagementAPIClient.managementURL(for: "https://" + host),
            authKey: "fixture-management", configuration: config)
        addTeardownBlock { await client.invalidate(); LifecycleHTTPProtocol.remove(host: host) }
        return (client, state)
    }

    private func json(_ record: LifecycleHTTPState.Record) throws -> Any {
        try JSONSerialization.jsonObject(with: XCTUnwrap(record.body), options: [.fragmentsAllowed])
    }

    func testManagementRootAndCredentialOperationsUseV8Routes() async throws {
        XCTAssertEqual(ManagementAPIClient.managementURL(for: "http://127.0.0.1:8317/"), "http://127.0.0.1:8317/v8/management")
        let (client, state) = fixture { request, _ in
            if request.url?.path.hasSuffix("/credentials/models") == true { return .reply(#"{"models":[{"id":"fixture"}]}"#) }
            if request.httpMethod == "GET", request.url?.path.hasSuffix("/credentials") == true {
                return .reply(#"{"files":[{"name":"fixture.json","provider":"claude","status":"ready"}]}"#)
            }
            return .reply(#"{"status":"ok"}"#)
        }
        let name = "user+tag@example.com&team=one.json"
        let files = try await client.fetchAuthFiles()
        XCTAssertEqual(files.first?.name, "fixture.json")
        let models = try await client.fetchAuthFileModels(name: name)
        XCTAssertEqual(models.first?.id, "fixture")
        _ = try await client.downloadAuthFile(name: name)
        try await client.uploadAuthFile(name: name, content: Data(#"{"type":"claude"}"#.utf8))
        try await client.setAuthFileDisabled(name: name, disabled: true)
        try await client.deleteAuthFile(name: name)
        try await client.deleteAllAuthFiles()
        XCTAssertEqual(state.requests.map { $0.method + " " + $0.url.path }, [
            "GET /v8/management/credentials", "GET /v8/management/credentials/models",
            "GET /v8/management/credentials/download", "POST /v8/management/credentials",
            "PATCH /v8/management/credentials/status", "DELETE /v8/management/credentials", "DELETE /v8/management/credentials"
        ])
        for record in state.requests { XCTAssertEqual(record.authorization, "Bearer fixture-management") }
        for index in [1, 2, 3, 5] {
            XCTAssertEqual(URLComponents(url: state.requests[index].url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, name)
            XCTAssertTrue(state.requests[index].url.absoluteString.contains("%2B"))
        }
        let status = try XCTUnwrap(try json(state.requests[4]) as? [String: Any])
        XCTAssertEqual(status["name"] as? String, name)
        XCTAssertEqual(status["disabled"] as? Bool, true)
    }

    func testConfigurationReadsDecodeRawV8ScalarValues() async throws {
        let (client, state) = fixture { request, _ in
            switch request.url?.path.components(separatedBy: "/config/").last {
            case "observability/logs/debug", "observability/logs/logging-to-file", "observability/logs/request-log", "observability/usage/usage-statistics-enabled": return .reply("true")
            case "routing/strategy": return .reply(#""fill-first""#)
            case "requests/proxy-url": return .reply(#""socks5://127.0.0.1:1080""#)
            case "routing/retry/request-retry": return .reply("2")
            case "routing/retry/max-retry-interval": return .reply("25")
            case "access/api-keys": return .reply(#"["fixture-client"]"#)
            default: return .replyStatus("unexpected endpoint", 404)
            }
        }
        let debug = try await client.getDebug(), logs = try await client.getLoggingToFile()
        let requests = try await client.getRequestLog(), usage = try await client.getUsageStatisticsEnabled()
        let strategy = try await client.getRoutingStrategy(), proxy = try await client.getProxyURL()
        let retry = try await client.getRequestRetry(), interval = try await client.getMaxRetryInterval()
        let keys = try await client.fetchAPIKeys()
        XCTAssertTrue(debug && logs && requests && usage)
        XCTAssertEqual(strategy, "fill-first"); XCTAssertEqual(proxy, "socks5://127.0.0.1:1080")
        XCTAssertEqual(retry, 2); XCTAssertEqual(interval, 25); XCTAssertEqual(keys, ["fixture-client"])
        XCTAssertEqual(state.requestCount, 9)
    }

    func testNewSettingsAndWeightUseV8ValuesWithoutRewritingCredentials() async throws {
        let (client, state) = fixture { request, _ in
            if request.httpMethod == "GET" { return .reply(#"{"files":[{"id":"fixture.json","name":"fixture.json","weight":0}]}"#) }
            return .reply(#"{"status":"ok","config-version":8}"#)
        }
        let weight = try await client.fetchAuthFileWeight(name: "fixture.json")
        XCTAssertEqual(weight, 0)
        try await client.setAuthFileWeight(name: "fixture.json", weight: -1)
        try await client.setRoutingStrategy("weighted-round-robin")
        try await client.setSessionAffinity(false)
        var draft = CPAAdvancedSettingsDraft()
        draft.maxRetryCredentials = "3"; draft.keepaliveSeconds = "15"; draft.bootstrapRetries = "2"
        try await client.patchV8Config(XCTUnwrap(draft.patch(comparedTo: .init(), scope: .requests)))
        XCTAssertEqual(state.requests.map { $0.url.path }, [
            "/v8/management/credentials", "/v8/management/credentials/fields",
            "/v8/management/config/routing/strategy", "/v8/management/config/routing/session-affinity",
            "/v8/management/config"
        ])
        let body = try XCTUnwrap(try json(state.requests[1]) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["name", "weight"])
        XCTAssertEqual(body["weight"] as? Int, -1)
        XCTAssertEqual(state.requests[1].method, "PATCH")
        XCTAssertEqual(try json(state.requests[2]) as? String, "weighted-round-robin")
        XCTAssertEqual(try json(state.requests[3]) as? Bool, false)
    }

    func testWeightReadCannotUseAnotherCredentialAndFailedSaveIsNotSuccess() async throws {
        let (client, state) = fixture { request, _ in
            request.httpMethod == "GET" ? .reply(#"{"files":[{"name":"another.json","weight":9}]}"#)
                : .reply(#"{"status":"error"}"#)
        }
        do { _ = try await client.fetchAuthFileWeight(name: "fixture+tag&key.json"); XCTFail("不能借用其他账号权重") }
        catch APIError.invalidResponse {}
        let query = URLComponents(url: state.requests[0].url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        XCTAssertEqual(query, "fixture+tag&key.json")
        do { try await client.setAuthFileWeight(name: "fixture.json", weight: 4); XCTFail("失败确认不能标记为成功") }
        catch APIError.invalidResponse {}
        let count = state.requestCount
        do { try await client.setAuthFileWeight(name: "fixture.json", weight: 1_000_001); XCTFail("超出权重上限") }
        catch CPASettingsValidationError.invalidWeight {}
        XCTAssertEqual(state.requestCount, count, "本地校验失败不得发送请求")
    }

    func testConfigurationWritesUseRawValuesAndDeleteInsteadOfNull() async throws {
        let (client, state) = fixture { _, _ in .reply(#"{"status":"ok","config-version":8}"#) }
        try await client.setDebug(true)
        try await client.setLoggingToFile(false)
        try await client.setRequestLog(true)
        try await client.setUsageStatisticsEnabled(true)
        try await client.setRoutingStrategy("fill-first")
        try await client.setProxyURL("socks5://127.0.0.1:1080")
        try await client.setRequestRetry(0)
        try await client.setMaxRetryInterval(12)
        try await client.replaceAPIKeys(["fixture/a&b+c", "second"])
        try await client.deleteProxyURL()
        let paths = state.requests.map { $0.url.path.replacingOccurrences(of: "/v8/management/config/", with: "") }
        XCTAssertEqual(paths, ["observability/logs/debug", "observability/logs/logging-to-file", "observability/logs/request-log",
            "observability/usage/usage-statistics-enabled", "routing/strategy", "requests/proxy-url", "routing/retry/request-retry",
            "routing/retry/max-retry-interval", "access/api-keys", "requests/proxy-url"])
        XCTAssertEqual(try json(state.requests[0]) as? Bool, true)
        XCTAssertEqual(try json(state.requests[1]) as? Bool, false)
        XCTAssertEqual(try json(state.requests[4]) as? String, "fill-first")
        XCTAssertEqual(try json(state.requests[6]) as? Int, 0)
        XCTAssertEqual(try json(state.requests[8]) as? [String], ["fixture/a&b+c", "second"])
        XCTAssertFalse(String(decoding: try XCTUnwrap(state.requests[5].body), as: UTF8.self).contains(#"\/"#))
        XCTAssertEqual(state.requests.last?.method, "DELETE"); XCTAssertNil(state.requests.last?.body)
        XCTAssertTrue(state.requests.dropLast().allSatisfy { $0.method == "PUT" })
    }

    func testClientKeyEditsReplaceOnlyTheAccessList() async throws {
        let (client, state) = fixture { request, _ in
            request.httpMethod == "GET" ? .reply(#"["one/a+b&c","two"]"#) : .reply(#"{"status":"ok","config-version":8}"#)
        }
        try await client.addAPIKey("three")
        try await client.updateAPIKey(old: "one/a+b&c", new: "updated")
        try await client.deleteAPIKey(value: "one/a+b&c")
        try await client.deleteAPIKeyByIndex(1)
        let writes = state.requests.filter { $0.method == "PUT" }
        XCTAssertEqual(try writes.map { try json($0) as? [String] }, [
            ["one/a+b&c", "two", "three"], ["updated", "two"], ["two"], ["one/a+b&c"]
        ])
        XCTAssertTrue(state.requests.allSatisfy { $0.url.path == "/v8/management/config/access/api-keys" })
        do { try await client.deleteAPIKeyByIndex(-1); XCTFail("无效索引不得发出写入") }
        catch APIError.invalidResponse { }
        XCTAssertEqual(state.requests.filter { $0.method == "PUT" }.count, 4)
    }

    func testOAuthProviderAndOpaqueStateQueriesUseUnifiedRoutes() async throws {
        // 成功夹具包含已注册的插件提供商，不能据此宣称 Qwen/iFlow 是 CPA 8 的内置能力。
        let (client, state) = fixture { _, _ in .reply(#"{"status":"ok","url":"https://example.invalid/login","state":"fixture"}"#) }
        for provider in [AIProvider.claude, .codex, .qwen, .iflow, .antigravity] { _ = try await client.getOAuthURL(for: provider) }
        _ = try await client.pollOAuthStatus(state: "state+opaque&next=wrong")
        XCTAssertEqual(state.requests.prefix(5).map { $0.url.path }, Array(repeating: "/v8/management/oauth/auth-url", count: 5))
        XCTAssertEqual(state.requests.prefix(5).map {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        }, ["claude", "codex", "qwen", "iflow", "antigravity"])
        XCTAssertEqual(state.requests.last?.url.path, "/v8/management/oauth/status")
        XCTAssertEqual(URLComponents(url: state.requests.last!.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "state+opaque&next=wrong")
        XCTAssertTrue(state.requests.last!.url.absoluteString.contains("%2B"))
    }

    func testDeviceFlowFieldsAndGrokDevinRoutesUseRealV8JSON() async throws {
        let (client, state) = fixture { _, _ in
            .reply(#"{"status":"ok","url":"https://example.invalid/device","state":"fixture","flow":"device","user_code":"WXYZ-5678","expires_in":1800}"#)
        }
        for provider in [AIProvider.grok, .devin] {
            let response = try await client.getOAuthURL(for: provider)
            XCTAssertEqual(response.flow, "device")
            XCTAssertEqual(response.userCode, "WXYZ-5678")
            XCTAssertEqual(response.expiresIn, 1800)
        }
        let queries = state.requests.map { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
        XCTAssertEqual(queries.map { $0.first { $0.name == "provider" }?.value }, ["xai", "devin"])
        XCTAssertTrue(queries.allSatisfy { $0.contains(URLQueryItem(name: "is_webui", value: "true")) })
        XCTAssertTrue(state.requests.allSatisfy { $0.url.path == "/v8/management/oauth/auth-url" })
        let legacy = try JSONDecoder().decode(OAuthURLResponse.self, from: Data(#"{"status":"ok","url":"https://example.invalid/login","state":"legacy"}"#.utf8))
        XCTAssertNil(legacy.flow)
        XCTAssertNil(legacy.expiresIn)
    }

    func testManualCallbackPostPreservesProviderAndOpaqueParameters() async throws {
        let (client, state) = fixture { _, _ in .reply(#"{"status":"ok"}"#) }
        let redirect = try XCTUnwrap(ManagementAPIClient.resolveCallbackURL(provider: .devin,
            input: "code: A+B/C==", state: "opaque+state", defaultPort: 9000))
        try await client.submitOAuthCallback(provider: .devin, redirectURL: redirect)
        let record = try XCTUnwrap(state.requests.first)
        XCTAssertEqual(record.method, "POST")
        XCTAssertEqual(record.url.path, "/v8/management/oauth/callback")
        let body = try XCTUnwrap(try json(record) as? [String: String])
        XCTAssertEqual(body["provider"], "devin")
        XCTAssertEqual(body["redirect_url"], redirect)
        XCTAssertTrue(redirect.contains("%2B"))
        XCTAssertEqual(state.requestCount, 1)
    }

    func testUnregisteredOAuthPluginHasAnActionableErrorWithoutLegacyFallback() async {
        let (client, state) = fixture { _, _ in .replyStatus(#"{"error":"provider_not_found"}"#, 404) }
        for provider in [AIProvider.qwen, .iflow, .claude] {
            do { _ = try await client.getOAuthURL(for: provider); XCTFail("未注册提供商不能假装授权成功") }
            catch APIError.oauthUnavailable(let missing) { XCTAssertEqual(missing, provider) }
            catch { XCTFail("应保留提供商不可用原因：\(error)") }
        }
        XCTAssertEqual(state.requestCount, 3)
        XCTAssertTrue(AIProvider.qwen.requiresCPA8OAuthPlugin)
        XCTAssertTrue(AIProvider.iflow.requiresCPA8OAuthPlugin)
        XCTAssertFalse(AIProvider.claude.requiresCPA8OAuthPlugin)
    }

    func testOAuthCancellationUsesDeleteWithAnEncodedOpaqueState() async throws {
        let (client, state) = fixture { _, _ in .reply(#"{"status":"ok","cancelled":true}"#) }
        let cancelled = try await client.cancelOAuthSession(state: "fixture+state&next=wrong")
        XCTAssertTrue(cancelled)
        XCTAssertEqual(state.requests.first?.method, "DELETE")
        XCTAssertEqual(state.requests.first?.url.path, "/v8/management/oauth/session")
        XCTAssertEqual(URLComponents(url: state.requests.first!.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "fixture+state&next=wrong")
    }

    func testVertexImportUsesMultipartFileInsteadOfLegacyRawJSON() async throws {
        let (client, state) = fixture { _, _ in .reply(#"{"status":"ok"}"#) }
        let content = Data(#"{"type":"service_account","project_id":"fixture-project"}"#.utf8)
        try await client.uploadVertexServiceAccount(data: content)
        let record = try XCTUnwrap(state.requests.first)
        XCTAssertEqual(record.url.path, "/v8/management/oauth/import")
        XCTAssertEqual(record.url.query, "provider=vertex")
        XCTAssertTrue(record.contentType?.hasPrefix("multipart/form-data; boundary=QuotioVertex-") == true)
        let body = String(decoding: try XCTUnwrap(record.body), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"service-account.json\""))
        XCTAssertTrue(body.contains(String(decoding: content, as: UTF8.self)))
    }

    func testLogsUsageModelsAndUpstreamCallUseOperationGroups() async throws {
        let (client, state) = fixture { request, _ in
            if request.httpMethod == "DELETE" { return .reply(#"{"success":true}"#) }
            if request.url?.path.hasSuffix("/usage/queue") == true { return .reply("[]") }
            if request.url?.path.hasSuffix("/api-call") == true { return .reply(#"{"status_code":200,"header":{},"body":"{}"}"#) }
            if request.url?.path.hasSuffix("/latest-version") == true { return .reply(#"{"latest-version":"v8.0.28"}"#) }
            if request.url?.path.contains("/model-definitions/") == true { return .reply(#"{"channel":"codex","models":[]}"#) }
            return .reply(#"{"lines":[],"next-cursor":"opaque"}"#)
        }
        _ = try await client.fetchLogs(cursor: "cursor+opaque&next=wrong")
        try await client.clearLogs()
        _ = try await client.fetchUsageQueue(count: 999)
        _ = try await client.fetchModelAliasDefinitions(channel: "codex")
        _ = try await client.apiCall(.init(authIndex: "fixture-auth", method: "GET", url: "https://example.invalid/quota", header: ["Authorization": "Bearer $TOKEN$"], data: nil))
        _ = try await client.fetchLatestVersion()
        XCTAssertEqual(state.requests.map { $0.url.path }, ["/v8/management/observability/logs", "/v8/management/observability/logs",
            "/v8/management/observability/usage/queue", "/v8/management/routing/model-definitions/codex",
            "/v8/management/requests/api-call", "/v8/management/server/latest-version"])
        XCTAssertEqual(state.requests[2].url.query, "count=500")
        let query = URLComponents(url: state.requests[0].url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "cursor" })?.value, "cursor+opaque&next=wrong")
        let call = try XCTUnwrap(try json(state.requests[4]) as? [String: Any])
        XCTAssertEqual(call["auth_index"] as? String, "fixture-auth")
        XCTAssertEqual((call["header"] as? [String: String])?["Authorization"], "Bearer $TOKEN$")
    }

    func testCatalogUsesClientCredentialAndKeepsTheV1BusinessProtocol() async throws {
        let (client, state) = fixture { request, _ in
            request.url?.path == "/v1/models" ? .reply(#"{"data":[{"id":"opaque-model"}]}"#) : .reply(#"["fixture-client"]"#)
        }
        let models = try await client.fetchModelAliasCatalog()
        XCTAssertEqual(models, ["opaque-model"])
        XCTAssertEqual(state.requests.map { $0.url.path }, ["/v8/management/config/access/api-keys", "/v1/models"])
        XCTAssertEqual(state.requests.map(\.authorization), ["Bearer fixture-management", "Bearer fixture-client"])
    }

    func testMissingConfigNodeUsesDefaultButUnavailableAPIAndWrongTypeDoNot() async throws {
        let (missing, _) = fixture { _, _ in .replyStatus(#"{"error":"not_found"}"#, 404) }
        let enabled = try await missing.getDebug()
        XCTAssertFalse(enabled)
        let retry = try await missing.getRequestRetry(), interval = try await missing.getMaxRetryInterval()
        XCTAssertEqual(retry, 0); XCTAssertEqual(interval, 0)
        let (unavailable, state) = fixture { _, _ in .replyStatus("404 page not found", 404) }
        do { _ = try await unavailable.getDebug(); XCTFail("接口缺失不能当成默认关闭") }
        catch APIError.httpError(404) { }
        XCTAssertEqual(state.requestCount, 1)
        let (invalid, _) = fixture { _, _ in .reply(#"{"value":true}"#) }
        do { _ = try await invalid.getDebug(); XCTFail("旧包装对象必须拒绝解码") }
        catch is DecodingError { }
    }

    func testExplicitNullNodesUseEffectiveDefaultsWithoutTreatingNullAsDeletion() async throws {
        let (client, state) = fixture { _, _ in .reply("null") }
        let debug = try await client.getDebug(), keys = try await client.fetchAPIKeys()
        let retry = try await client.getRequestRetry(), interval = try await client.getMaxRetryInterval()
        let strategy = try await client.getRoutingStrategy()
        XCTAssertFalse(debug); XCTAssertTrue(keys.isEmpty)
        XCTAssertEqual(retry, 0); XCTAssertEqual(interval, 0); XCTAssertEqual(strategy, "round-robin")
        XCTAssertTrue(state.requests.allSatisfy { $0.method == "GET" }, "读取 null 不能修改或删除已保存节点")
    }

    func testSideEffectRequestsAreNotRetriedAfterTransportFailure() async {
        let (client, state) = fixture { _, _ in .fail(.networkConnectionLost) }
        let operations: [() async throws -> Void] = [
            { try await client.setDebug(true) },
            { _ = try await client.getOAuthURL(for: .claude) },
            { try await client.deleteAuthFile(name: "fixture.json") },
            { _ = try await client.apiCall(.init(authIndex: "fixture", method: "POST", url: "https://example.invalid", header: nil, data: nil)) }
        ]
        for operation in operations {
            do { try await operation(); XCTFail("网络故障应返回调用方") }
            catch { }
        }
        XCTAssertEqual(state.requestCount, 4, "写入、OAuth 会话和上游调用均只能执行一次")
    }

    func testNodeWriteValidationKeepsHTTPStatusAndReason() async {
        let (client, _) = fixture { _, _ in .replyStatus(#"{"error":"invalid_config","message":"routing.strategy: invalid strategy"}"#, 422) }
        do { try await client.setRoutingStrategy("invalid"); XCTFail("非法配置应失败") }
        catch APIError.configRejected(let status, let reason) {
            XCTAssertEqual(status, 422); XCTAssertTrue(reason.contains("routing.strategy"))
        } catch { XCTFail("丢失 v8 校验信息：\(error)") }
    }

    func testConfigurationWritesRequireTheOfficialV8Confirmation() async throws {
        let (valid, state) = fixture { _, _ in .reply(#"{"status":"ok","config-version":8}"#) }
        try await valid.migrateLegacyConfigToV8()
        try await valid.patchV8Config(Data(#"{"routing":{"strategy":"fill-first"}}"#.utf8))
        try await valid.putV8Config(path: ["requests", "payload", "override"], body: Data("[]".utf8))
        try await valid.replaceOAuthModelAliases(Data("{}".utf8))
        try await valid.saveModelAliasYAML("config-version: 8\n")
        XCTAssertEqual(state.requests.map { $0.url.path }, ["/v8/management/config", "/v8/management/config",
            "/v8/management/config/requests/payload/override", "/v8/management/config/oauth/model-alias", "/v8/management/config.yaml"])
        XCTAssertEqual(state.requests.last?.contentType, "application/yaml")
        for response in [#"{"status":"ok","config-version":7}"#, #"{"status":"error","config-version":8}"#, "{}"] {
            let (invalid, attempts) = fixture { _, _ in .reply(response) }
            do { try await invalid.setDebug(true); XCTFail("不完整或非 v8 确认不能当成保存成功") }
            catch { }
            XCTAssertEqual(attempts.requestCount, 1)
        }
    }

    func testClearingAnAlreadyAbsentProxyIsIdempotentButOther404StillFails() async throws {
        let (missing, state) = fixture { _, _ in .replyStatus(#"{"error":"not_found"}"#, 404) }
        try await missing.deleteProxyURL()
        try await missing.deleteProxyURL()
        XCTAssertEqual(state.requestCount, 2)
        let (unavailable, _) = fixture { _, _ in .replyStatus("404 page not found", 404) }
        do { try await unavailable.deleteProxyURL(); XCTFail("管理 API 不可用不能视为清空成功") }
        catch APIError.httpError(404) { }
    }

    func testConcurrentClientKeyEditIsRejectedAndCancellationReleasesTheGuard() async throws {
        let started = expectation(description: "首个密钥修改正在等待读取")
        let (client, state) = fixture { request, count in
            if count == 1 { started.fulfill(); return .hold }
            return request.httpMethod == "GET" ? .reply(#"["one"]"#) : .reply(#"{"status":"ok","config-version":8}"#)
        }
        let pending = Task { try await client.addAPIKey("first") }
        await fulfillment(of: [started], timeout: 3)
        do { try await client.addAPIKey("second"); XCTFail("并发读后写会覆盖第一份列表") }
        catch APIError.operationInProgress { }
        XCTAssertEqual(state.requestCount, 1)
        pending.cancel()
        do { try await pending.value; XCTFail("挂起请求应可取消") } catch is CancellationError { }
        try await client.addAPIKey("after-cancel")
        XCTAssertEqual(try json(XCTUnwrap(state.requests.last)) as? [String], ["one", "after-cancel"])
    }

    func testOldManagementRootsAreRejectedWithoutSendingCredentials() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState { _, _ in .reply("true") }
        LifecycleHTTPProtocol.register(state, host: host)
        defer { LifecycleHTTPProtocol.remove(host: host) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LifecycleHTTPProtocol.self]
        let client = ManagementAPIClient(baseURL: "https://" + host + "/v0/management", authKey: "fixture", configuration: config)
        do { _ = try await client.getDebug(); XCTFail("不得继续使用旧管理根") } catch APIError.invalidURL { }
        do { _ = try await client.fetchUsageQueue(); XCTFail("队列也必须拒绝旧管理根") } catch APIError.invalidURL { }
        XCTAssertEqual(state.requestCount, 0)
        await client.invalidate()
    }

    func testFullConfigUsesV8NestedValuesWithoutLosingFalseOrZero() throws {
        let data = Data(#"{"observability":{"logs":{"debug":false,"logging-to-file":true,"request-log":false}},"requests":{"proxy-url":"direct"},"routing":{"strategy":"fill-first","retry":{"request-retry":0,"max-retry-interval":12}},"debug":true,"request-retry":7}"#.utf8)
        let value = try JSONDecoder().decode(ProxyConfig.self, from: data)
        XCTAssertEqual(value.debug, false); XCTAssertEqual(value.loggingToFile, true); XCTAssertEqual(value.requestLog, false)
        XCTAssertEqual(value.proxyURL, "direct"); XCTAssertEqual(value.routingStrategy, "fill-first")
        XCTAssertEqual(value.requestRetry, 0); XCTAssertEqual(value.maxRetryInterval, 12)
    }

    func testConfigReadAndHealthRejectSuccessfulHTTPWithAnInvalidVersion() async throws {
        let (valid, _) = fixture { _, _ in .reply(#"{"config-version":8,"observability":{"logs":{"debug":false}}}"#) }
        let config = try await valid.fetchConfig()
        XCTAssertEqual(config.debug, false)
        let healthy = await valid.checkProxyResponding()
        XCTAssertTrue(healthy)
        for body in ["{}", #"{"config-version":7}"#, "<html>different service</html>"] {
            let (invalid, _) = fixture { _, _ in .reply(body) }
            do { _ = try await invalid.fetchConfig(); XCTFail("必须读取到 v8 配置标记") } catch APIError.invalidResponse { }
            let healthy = await invalid.checkProxyResponding()
            XCTAssertFalse(healthy)
            XCTAssertFalse(ManagementAPIClient.isV8Configuration(Data(body.utf8)))
        }
    }

    func testCredentialAndLogMutationsValidateTheirOwnSuccessContract() async {
        let (invalid, state) = fixture { _, _ in .reply(#"{"status":"error","success":false}"#) }
        let operations: [() async throws -> Void] = [
            { try await invalid.deleteAuthFile(name: "fixture.json") },
            { try await invalid.setAuthFileDisabled(name: "fixture.json", disabled: true) },
            { try await invalid.clearLogs() }
        ]
        for operation in operations {
            do { try await operation(); XCTFail("HTTP 200 不能覆盖明确失败的运维确认") }
            catch APIError.invalidResponse { }
            catch { XCTFail("应报告无效确认：\(error)") }
        }
        XCTAssertEqual(state.requestCount, 3)
    }

    func testRedirectsCannotForwardKeysAcrossOriginsOrDowngradeTLS() {
        let origin = URL(string: "https://localhost/v8/management/config")
        XCTAssertTrue(ManagementAPIClient.allowsRedirect(from: origin, to: URL(string: "https://LOCALHOST:443/v8/management/config/")))
        for target in ["http://localhost/v8/management/config", "https://localhost:8317/config", "https://example.invalid/config", "file:///tmp/config"] {
            XCTAssertFalse(ManagementAPIClient.allowsRedirect(from: origin, to: URL(string: target)))
        }
        XCTAssertFalse(ManagementAPIClient.allowsRedirect(from: nil, to: origin))
    }

    func testDebugLoggingSavesAllThreeFieldsInOneV8Patch() async throws {
        let (client, state) = fixture { _, _ in .reply(#"{"status":"ok","config-version":8}"#) }
        try await client.setDebugLogging(true)
        try await client.setDebugLogging(false)
        XCTAssertEqual(state.requests.count, 2, "每次切换只允许一次写入，避免三个字段部分成功")
        for (index, enabled) in [true, false].enumerated() {
            let record = state.requests[index]
            XCTAssertEqual(record.url.path, "/v8/management/config")
            XCTAssertEqual(record.method, "PATCH")
            let root = try XCTUnwrap(try json(record) as? [String: [String: [String: Bool]]])
            XCTAssertEqual(root, ["observability": ["logs": ["debug": enabled, "logging-to-file": enabled, "request-log": enabled]]])
        }
    }

    func testRejectedDebugPatchIsNotSplitRetriedOrReportedAsSuccess() async {
        let (client, state) = fixture { _, _ in .replyStatus(#"{"error":"invalid_config","message":"fixture validation failure"}"#, 422) }
        do { try await client.setDebugLogging(true); XCTFail("拒绝的配置写入不能视为成功") }
        catch APIError.configRejected(let status, _) { XCTAssertEqual(status, 422) }
        catch { XCTFail("错误类型不符：\(error)") }
        XCTAssertEqual(state.requestCount, 1)
        XCTAssertEqual(state.requests.first?.method, "PATCH")
    }

    func testEmptyClientKeyListStillLoadsPublicModelCatalogWithoutManagementKey() async throws {
        let (client, state) = fixture { request, _ in
            request.url?.path == "/v1/models" ? .reply(#"{"data":[{"id":"public-model"}]}"#) : .reply("[]")
        }
        let models = try await client.fetchModelAliasCatalog()
        XCTAssertEqual(models, ["public-model"])
        XCTAssertEqual(state.requests.map { $0.url.path }, ["/v8/management/config/access/api-keys", "/v1/models"])
        XCTAssertEqual(state.requests.first?.authorization, "Bearer fixture-management")
        XCTAssertNil(state.requests.last?.authorization, "没有业务密钥时不使用管理密钥，也不发送空 Bearer")
    }

    func testAdditionalCatalogAuthenticationFailureRetainsHTTPStatusWithoutKeyFallback() async {
        let (client, state) = fixture { request, _ in
            request.url?.path == "/v1/models" ? .replyStatus(#"{"error":"missing credentials"}"#, 401) : .reply("[]")
        }
        do { _ = try await client.fetchModelAliasCatalog(); XCTFail("额外认证提供方的拒绝不能被忽略") }
        catch APIError.httpError(let status) { XCTAssertEqual(status, 401) }
        catch { XCTFail("应保留业务 HTTP 状态：\(error)") }
        XCTAssertEqual(state.requestCount, 2)
        XCTAssertNil(state.requests.last?.authorization)
    }

    func testNativeActiveAndLegacyReadyBothCountAsAvailableWithoutChangingRawStatus() async throws {
        let (client, _) = fixture { _, _ in .reply(#"{"files":[{"name":"active.json","provider":"xai","status":"active"},{"name":"legacy.json","provider":"claude","status":"ready"},{"name":"disabled.json","provider":"codex","status":"active","disabled":true},{"name":"unavailable.json","provider":"codex","status":"active","unavailable":true},{"name":"error.json","provider":"codex","status":"error"},{"name":"unknown.json","provider":"codex","status":"unknown"}]}"#) }
        let files = try await client.fetchAuthFiles()
        XCTAssertEqual(files.filter(\.isReady).map(\.name), ["active.json", "legacy.json"])
        XCTAssertEqual(files.first?.status, "active", "兼容判断不应把服务端状态重写成旧 ready")
        XCTAssertEqual(files.first?.providerType, .grok)
    }

    func testFetchAndSetAuthFileRoutingSendsPriorityAndWeight() async throws {
        let (client, state) = fixture { request, _ in
            if request.httpMethod == "GET" {
                return .reply(#"{"files":[{"name":"target.json","weight":5,"priority":100}]}"#)
            }
            return .reply(#"{"status":"ok"}"#)
        }
        let routing = try await client.fetchAuthFileRouting(name: "target.json")
        XCTAssertEqual(routing.weight, 5)
        XCTAssertEqual(routing.priority, 100)

        try await client.setAuthFileRouting(name: "target.json", weight: 3, priority: 50)
        XCTAssertEqual(state.requests.map(\.method), ["GET", "PATCH"])
        XCTAssertEqual(state.requests[1].url.path, "/v8/management/credentials/fields")
        let body = try XCTUnwrap(try json(state.requests[1]) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "target.json")
        XCTAssertEqual(body["weight"] as? Int, 3)
        XCTAssertEqual(body["priority"] as? Int, 50)

        // 校验超出上限或负数优先级失败且不发送请求
        let count = state.requestCount
        do { try await client.setAuthFileRouting(name: "target.json", weight: 1, priority: -1); XCTFail("负数优先级应校验失败") }
        catch CPASettingsValidationError.invalidPriority {}
        do { try await client.setAuthFileRouting(name: "target.json", weight: 1, priority: 1_000_001); XCTFail("超出优先级上限应校验失败") }
        catch CPASettingsValidationError.invalidPriority {}
        XCTAssertEqual(state.requestCount, count)
    }

    func testResetCredentialCooldownPostsAuthIndex() async throws {
        let (client, state) = fixture { _, _ in .reply(#"{"status":"ok"}"#) }
        try await client.resetCredentialCooldown(authIndex: "fixture-auth-123")
        XCTAssertEqual(state.requests.count, 1)
        let record = try XCTUnwrap(state.requests.first)
        XCTAssertEqual(record.method, "POST")
        XCTAssertEqual(record.url.path, "/v8/management/routing/cooldown/reset")
        let body = try XCTUnwrap(try json(record) as? [String: String])
        XCTAssertEqual(body["auth_index"], "fixture-auth-123")

        // 空 authIndex 必须失败且不发送网络请求
        do { try await client.resetCredentialCooldown(authIndex: "   "); XCTFail("空 authIndex 应拒绝") }
        catch APIError.invalidResponse {}
        XCTAssertEqual(state.requestCount, 1)
    }

    @MainActor
    func testAuthFileCooldownDecodingAndSummary() throws {
        let jsonStr = """
        {
            "id": "c1",
            "name": "cool.json",
            "provider": "claude",
            "auth_index": "idx-1",
            "weight": 2,
            "priority": 10,
            "cooldowns": [
                {
                    "scope": "model",
                    "model_key": "claude-3-5-sonnet",
                    "reason": "rate_limit",
                    "remaining_seconds": 125
                },
                {
                    "scope": "credential",
                    "reason": "quota_exhausted",
                    "remaining_seconds": 0
                }
            ]
        }
        """
        let file = try JSONDecoder().decode(AuthFile.self, from: Data(jsonStr.utf8))
        XCTAssertEqual(file.weight, 2)
        XCTAssertEqual(file.priority, 10)
        XCTAssertEqual(file.cooldowns?.count, 2)
        XCTAssertTrue(file.hasActiveCooldown)
        XCTAssertEqual(file.activeCooldowns.count, 1)
        XCTAssertEqual(file.cooldownSummary, "claude-3-5-sonnet (2m5s)")
        XCTAssertTrue(file.cooldownTooltip?.contains("claude-3-5-sonnet: 125s (rate_limit)") == true)

        let row = AccountRowData.from(authFile: file, provider: .claude)
        XCTAssertEqual(row.weight, 2)
        XCTAssertEqual(row.priority, 10)
        XCTAssertTrue(row.hasActiveCooldown)
        XCTAssertTrue(row.canResetCooldown)
        XCTAssertEqual(row.cooldownSummary, "claude-3-5-sonnet (2m5s)")
    }
}
