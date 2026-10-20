import Foundation
import XCTest
@testable import QuotioPlus

/// 通过实际 URLSession 与离线 URLProtocol 验证三种读取语义，避免只断言新服务转发到了哪个方法。
/// 所有主机名和密钥均为夹具；候选用例注入内存 Copilot 可用性，不读取真实账号或写客户端配置。
@MainActor
final class AgentModelCatalogServiceTests: XCTestCase {
    private func fixture(_ response: @escaping @Sendable (URLRequest, Int) -> LifecycleHTTPState.Response)
        -> (url: String, session: URLSession, state: LifecycleHTTPState) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState(response: response)
        LifecycleHTTPProtocol.register(state, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock {
            session.invalidateAndCancel()
            LifecycleHTTPProtocol.remove(host: host)
        }
        return ("https://" + host + "/v1", session, state)
    }

    func testLiveCatalogAndConnectionKeepRequestContractAndRawOrder() async throws {
        let http = fixture { request, _ in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.timeoutInterval, 10)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-client")
            XCTAssertEqual(request.url?.path, "/v1/models")
            XCTAssertNil(request.httpBody)
            return .reply(#"{"data":[{"id":"z-model","owned_by":"custom"},{"id":"a-model"},{"id":"z-model","owned_by":"custom"}]}"#)
        }
        let entries = try await AgentModelCatalogService.fetchModelCatalog(
            proxyURL: http.url, apiKey: "fixture-client", session: http.session)
        XCTAssertEqual(entries.map(\.id), ["z-model", "a-model", "z-model"])
        XCTAssertNil(entries[1].owner, "实时目录不能凭空填充提供商或进行候选投影")
        let connection = await AgentModelCatalogService.testConnection(
            proxyURL: http.url, apiKey: "fixture-client", session: http.session)
        XCTAssertTrue(connection.success)
        XCTAssertEqual(connection.message, "Connected successfully")
        XCTAssertEqual(connection.modelResponded, "z-model")
        XCTAssertNotNil(connection.latencyMs)
        XCTAssertEqual(http.state.requestCount, 2, "两次显式读取分别只发送一个请求")
    }

    func testEmptyCatalogAndCandidatesStayEmptyWithoutBuiltInModels() async throws {
        let http = fixture { _, _ in .reply(#"{"data":[]}"#) }
        let entries = try await AgentModelCatalogService.fetchModelCatalog(
            proxyURL: http.url, apiKey: "", session: http.session)
        let candidates = try await AgentModelCatalogService.fetchAvailableModels(
            proxyURL: http.url, apiKey: "", session: http.session, fetchCopilotModelIDs: { [] })
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(candidates.isEmpty, "读取业务与配置候选均不得补入内置模型")
        XCTAssertEqual(http.state.requests.map(\.authorization), ["Bearer ", "Bearer "])
    }

    func testCandidateFilteringKeepsOrderDuplicatesAndNonCopilotModels() async throws {
        let http = fixture { _, _ in .reply(#"{"data":[{"id":"unavailable","owned_by":"github-copilot"},{"id":"custom-model"},{"id":"enabled","owned_by":"github-copilot"},{"id":"enabled","owned_by":"github-copilot"}]}"#) }
        let candidates = try await AgentModelCatalogService.fetchAvailableModels(
            proxyURL: http.url, apiKey: "fixture", session: http.session, fetchCopilotModelIDs: { ["enabled"] })
        XCTAssertEqual(candidates.map(\.id), ["custom-model", "enabled", "enabled"])
        XCTAssertEqual(candidates.map(\.provider), ["openai", "github-copilot", "github-copilot"])
        XCTAssertTrue(candidates.allSatisfy { !$0.isDefault })
    }

    func testMissingCopilotAvailabilityDoesNotHideOriginalCandidates() async throws {
        let http = fixture { _, _ in .reply(#"{"data":[{"id":"unconfirmed","owned_by":"github-copilot"}]}"#) }
        let candidates = try await AgentModelCatalogService.fetchAvailableModels(
            proxyURL: http.url, apiKey: "fixture", session: http.session, fetchCopilotModelIDs: { [] })
        XCTAssertEqual(candidates.map(\.id), ["unconfirmed"])
    }

    func testCompatibilityUsesRawRegistryEvenWhenCopilotCandidateIsFiltered() async throws {
        let http = fixture { _, _ in .reply(#"{"data":[{"id":"codex/fixture-model","owned_by":"github-copilot"},{"id":"fixture-model","owned_by":"custom"}]}"#) }
        let selection = try await AgentModelCatalogService.fetchModelSelection(
            proxyURL: http.url, apiKey: "fixture", session: http.session, fetchCopilotModelIDs: { ["another-model"] })
        XCTAssertEqual(selection.catalog.map(\.id), ["codex/fixture-model", "fixture-model"])
        XCTAssertEqual(selection.candidates.map(\.id), ["fixture-model"])
        let vm = AgentSetupViewModel(fetchModelSelection: { _, _ in selection })
        vm.selectedAgent = .claudeCode
        var config = AgentConfiguration(agent: .claudeCode, proxyURL: http.url, apiKey: "fixture")
        config.modelSlots[.opus] = "codex/fixture-model"
        vm.currentConfiguration = config
        let success = await vm.loadModels()
        XCTAssertTrue(success)
        XCTAssertEqual(vm.availableModels.map(\.id), ["fixture-model"], "UI 原候选筛选不改变")
        let plan = try XCTUnwrap(vm.claudeCompatibilityPlan)
        XCTAssertEqual(plan.configuration.modelSlots[.opus], "codex/fixture-model", "合法完整路由不能按本机账号候选推断删除")
        XCTAssertTrue(plan.migrations.isEmpty)
        XCTAssertEqual(http.state.requestCount, 1, "证据和候选必须来自同一轮请求，不新增目录请求")
    }

    func testMalformedHTTP200FailsCatalogButRemainsSuccessfulConnection() async {
        let http = fixture { _, _ in .reply("not-a-model-directory") }
        do {
            _ = try await AgentModelCatalogService.fetchModelCatalog(proxyURL: http.url, apiKey: "fixture", session: http.session)
            XCTFail("实时目录不能把不可解析正文当作空目录或默认列表")
        } catch { XCTAssertFalse(error is CancellationError) }
        let connection = await AgentModelCatalogService.testConnection(
            proxyURL: http.url, apiKey: "fixture", session: http.session)
        XCTAssertTrue(connection.success)
        XCTAssertEqual(connection.message, "Connected successfully")
        XCTAssertNil(connection.modelResponded)
        XCTAssertNotNil(connection.latencyMs)
        XCTAssertEqual(http.state.requestCount, 2)
    }

    func testHTTPFailurePreservesEachErrorPolicyWithoutRetry() async {
        let http = fixture { _, _ in .replyStatus(#"{"error":{"message":"fixture-upstream-unavailable"}}"#, 503) }
        do {
            _ = try await AgentModelCatalogService.fetchModelCatalog(proxyURL: http.url, apiKey: "fixture", session: http.session)
            XCTFail("非 200 目录必须沿用原传输错误")
        } catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
        let connection = await AgentModelCatalogService.testConnection(
            proxyURL: http.url, apiKey: "fixture", session: http.session)
        XCTAssertFalse(connection.success)
        XCTAssertEqual(connection.message, "fixture-upstream-unavailable")
        XCTAssertNotNil(connection.latencyMs)
        XCTAssertEqual(http.state.requestCount, 2)
    }

    func testTransportFailureThrowsForCatalogAndReturnsFailedConnection() async {
        let http = fixture { _, _ in .fail(.notConnectedToInternet) }
        do {
            _ = try await AgentModelCatalogService.fetchModelCatalog(proxyURL: http.url, apiKey: "fixture", session: http.session)
            XCTFail("目录错误必须向调用方传播")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        let connection = await AgentModelCatalogService.testConnection(
            proxyURL: http.url, apiKey: "fixture", session: http.session)
        XCTAssertFalse(connection.success)
        XCTAssertEqual(connection.message, URLError(.notConnectedToInternet).localizedDescription)
        XCTAssertNil(connection.latencyMs)
        XCTAssertEqual(http.state.requestCount, 2)
    }

    func testCancellationKeepsThrowingCatalogAndNonthrowingConnectionPolicies() async {
        let catalogReached = expectation(description: "目录请求已进入传输")
        let catalog = fixture { _, _ in catalogReached.fulfill(); return .hold }
        let loading = Task { try await AgentModelCatalogService.fetchModelCatalog(
            proxyURL: catalog.url, apiKey: "fixture", session: catalog.session) }
        await fulfillment(of: [catalogReached], timeout: 2)
        loading.cancel()
        do {
            _ = try await loading.value
            XCTFail("取消不能返回空列表或静态模型")
        } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }

        let connectionReached = expectation(description: "连接请求已进入传输")
        let connection = fixture { _, _ in connectionReached.fulfill(); return .hold }
        let checking = Task { await AgentModelCatalogService.testConnection(
            proxyURL: connection.url, apiKey: "fixture", session: connection.session) }
        await fulfillment(of: [connectionReached], timeout: 2)
        checking.cancel()
        let result = await checking.value
        XCTAssertFalse(result.success)
        XCTAssertNil(result.latencyMs)
        XCTAssertEqual(catalog.state.requestCount, 1)
        XCTAssertEqual(connection.state.requestCount, 1)
    }

    func testInvalidURLRetainsOriginalErrorsWithoutSendingRequest() async {
        let http = fixture { _, _ in .reply(#"{"data":[]}"#) }
        do {
            _ = try await AgentModelCatalogService.fetchModelCatalog(proxyURL: "http://[", apiKey: "fixture", session: http.session)
            XCTFail("无效 URL 不能触发传输")
        } catch { XCTAssertEqual((error as? URLError)?.code, .badURL) }
        let connection = await AgentModelCatalogService.testConnection(
            proxyURL: "http://[", apiKey: "fixture", session: http.session)
        XCTAssertFalse(connection.success)
        XCTAssertEqual(connection.message, "Invalid proxy URL")
        XCTAssertNil(connection.latencyMs)
        XCTAssertEqual(http.state.requestCount, 0)
    }
}
