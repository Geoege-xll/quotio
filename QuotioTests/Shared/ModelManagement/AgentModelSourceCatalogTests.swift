import Foundation
import XCTest
@testable import QuotioPlus

/// 当前来源只从后端注册证据产生，离线验证单账号、账号池、缺失及部分失败，不读取真实凭据。
final class AgentModelSourceCatalogTests: XCTestCase {
    private func selection() -> AgentModelCatalogService.Selection {
        let model = AvailableModel(id: "shared-id", name: "shared-id", provider: "openai", isDefault: false)
        return .init(catalog: [model], candidates: [model])
    }
    private func registration(_ id: String, account: String) -> AgentModelSourceCatalog.Registration {
        .init(credentialID: id, platform: "codex", account: account,
              models: [.init(id: "shared-id", ownedBy: "openai", type: nil, displayName: "Friendly Model")])
    }
    func testSingleCompleteSourceShowsAccountAndFriendlyNameWithoutChangingID() throws {
        let result = AgentModelSourceCatalog.projecting(selection(), registrations: [registration("a", account: "work@example.test")], complete: true)
        let model = try XCTUnwrap(result.catalog.first)
        XCTAssertEqual(model.id, "shared-id")
        XCTAssertEqual(model.name, "Friendly Model")
        XCTAssertEqual(model.displaySource?.account, "work@example.test")
        XCTAssertEqual(model.displaySource?.isAccountPool, false)
        XCTAssertEqual(result.catalog, result.candidates)
        let row = ClaudeModelPresentation.catalogOption(.init(model: model.id), models: result.catalog)
        XCTAssertEqual(row.label, "Friendly Model")
        XCTAssertEqual(row.description, "Codex · work@example.test")
    }
    func testTwoCredentialIdentitiesArePoolEvenWhenTheirEmailMatches() throws {
        let result = AgentModelSourceCatalog.projecting(selection(), registrations: [registration("a", account: "same@test.invalid"), registration("b", account: "same@test.invalid")], complete: true)
        let model = try XCTUnwrap(result.catalog.first)
        XCTAssertTrue(model.displaySource?.isAccountPool == true)
        XCTAssertNil(model.displaySource?.account)
        let row = ClaudeModelPresentation.catalogOption(.init(model: model.id), models: result.catalog)
        XCTAssertEqual(row.description, "Codex · " + "agents.claudeMenu.accountPool".localizedStatic())
        XCTAssertFalse(row.description.contains("same@"))
    }
    func testPartialOrMissingEvidenceNeverInventsFixedAccountOrOpenAIProvider() throws {
        for registrations in [[registration("a", account: "work@test.invalid")], []] {
            let result = AgentModelSourceCatalog.projecting(selection(), registrations: registrations, complete: false)
            XCTAssertNil(result.catalog.first?.displaySource)
            let row = ClaudeModelPresentation.catalogOption(.init(model: "shared-id"), models: result.catalog)
            XCTAssertEqual(row.description, "agents.claudeMenu.sourceUnknown".localizedStatic())
            XCTAssertNotEqual(row.description, row.label)
            XCTAssertFalse(row.description.contains("OpenAI"))
        }
    }
    func testV8EnrichmentExcludesDisabledCredentialsAndUsesOnlyManagementAuthentication() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState { request, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-management")
            if request.url?.path == "/v8/management/credentials" {
                return .reply(#"{"files":[{"id":"a","name":"a.json","provider":"codex","email":"work@test.invalid"},{"id":"b","name":"b.json","provider":"codex","disabled":true}]}"#)
            }
            XCTAssertEqual(request.url?.path, "/v8/management/credentials/models")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a")
            return .reply(#"{"models":[{"id":"shared-id","display_name":"Friendly Model"}]}"#)
        }
        LifecycleHTTPProtocol.register(state, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        let client = ManagementAPIClient(baseURL: "https://" + host + ManagementAPIClient.managementPath,
                                         authKey: "fixture-management", configuration: configuration)
        addTeardownBlock { await client.invalidate(); LifecycleHTTPProtocol.remove(host: host) }
        let result = try await AgentModelSourceCatalog.enrich(selection(), client: client)
        XCTAssertEqual(result.catalog.first?.displaySource?.account, "work@test.invalid")
        XCTAssertEqual(result.catalog.first?.name, "Friendly Model")
        XCTAssertEqual(state.requestCount, 2, "禁用账号不能贡献名称、来源或额外请求")
    }

    /// 官方 name 参数兼容 ID；同名但不同凭据必须分别读取，不能成功查询两次却拿到同一账号的模型。
    func testSameFilenameUsesUniqueBackendIDAndAmbiguousFallbackDoesNotClaimSource() async throws {
        for ambiguous in [false, true] {
            let host = UUID().uuidString.lowercased() + ".invalid"
            let state = LifecycleHTTPState { request, _ in
                if request.url?.path.hasSuffix("/credentials") == true {
                    return ambiguous
                        ? .reply(#"{"files":[{"name":"same.json","provider":"codex"},{"name":"same.json","provider":"codex"}]}"#)
                        : .reply(#"{"files":[{"id":"a","name":"same.json","provider":"codex","email":"a@test.invalid"},{"id":"b","name":"same.json","provider":"codex","email":"b@test.invalid"}]}"#)
                }
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
                XCTAssertTrue(query == "a" || query == "b")
                return .reply(query == "a" ? #"{"models":[{"id":"model-a"}]}"# : #"{"models":[{"id":"model-b"}]}"#)
            }
            LifecycleHTTPProtocol.register(state, host: host)
            let transport = URLSessionConfiguration.ephemeral
            transport.protocolClasses = [LifecycleHTTPProtocol.self]
            let client = ManagementAPIClient(baseURL: "https://" + host + ManagementAPIClient.managementPath,
                                             authKey: "fixture-only", configuration: transport)
            let models = ["model-a", "model-b"].map { AvailableModel(id: $0, name: $0, provider: "fixture", isDefault: false) }
            let result = try await AgentModelSourceCatalog.enrich(.init(catalog: models, candidates: models), client: client)
            await client.invalidate()
            LifecycleHTTPProtocol.remove(host: host)
            if ambiguous {
                XCTAssertTrue(result.catalog.allSatisfy { $0.displaySource == nil })
                XCTAssertEqual(state.requestCount, 1, "歧义身份不能反复按同一文件名查询后冒充账号池")
            } else {
                XCTAssertEqual(result.catalog[0].displaySource?.account, "a@test.invalid")
                XCTAssertEqual(result.catalog[1].displaySource?.account, "b@test.invalid")
                XCTAssertTrue(result.catalog.allSatisfy { $0.displaySource?.isAccountPool == false })
            }
        }
    }
    func testExplicitMetadataIsOptionalAndOldModelEncodingStillDecodes() throws {
        let data = Data(#"{"data":[{"id":"long-id","display_name":"Long Model","max_input_tokens":1048576},{"id":"plain","name":42,"context_length":"unknown"}]}"#.utf8)
        let entries = try ModelCatalog.parse(data)
        let models = ModelCatalog.agentSetupModels(from: entries)
        XCTAssertEqual(models.map(\.id), ["long-id", "plain"])
        XCTAssertEqual(models[0].name, "Long Model")
        XCTAssertEqual(models[0].contextWindow, 1_048_576)
        XCTAssertNil(models[1].contextWindow)
        let old = try JSONDecoder().decode(AvailableModel.self, from: Data(#"{"id":"old","name":"old","provider":"fixture","isDefault":false}"#.utf8))
        XCTAssertNil(old.displaySource)
        XCTAssertNil(old.contextWindow)
    }

    /// 来源补充属于原目录请求的同一轮：管理客户端已替换时，即使没有新页面请求，也不能提交旧来源。
    /// 注入离线传输和独立偏好，既不启动 CPA，也不接触真实账号与授权文件。
    @MainActor
    func testLateSourceResponseCannotCommitAfterManagementClientChanges() async throws {
        let suite = "ClaudeModelSourceIsolation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let root = QuotaViewModel(directAuthService: DirectAuthFileService(authDirectory: directory),
            startsBackgroundServices: false, modeManager: OperatingModeManager(defaults: defaults),
            menuBarSettings: MenuBarSettingsManager(defaults: defaults), refreshSettings: RefreshSettingsManager(defaults: defaults),
            warmupSettings: WarmupSettingsManager(defaults: defaults),
            notificationManager: NotificationManager(testDefaults: defaults, notificationSink: { _ in }))
        let gate = LifecycleHTTPResponseGate()
        let started = expectation(description: "旧客户端的来源请求已挂起")
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState { request, _ in
            if request.url?.path.hasSuffix("/credentials") == true {
                return .reply(#"{"files":[{"id":"a","name":"a.json","provider":"codex","email":"old@test.invalid"}]}"#)
            }
            started.fulfill()
            return .deferred(gate)
        }
        LifecycleHTTPProtocol.register(state, host: host)
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [LifecycleHTTPProtocol.self]
        let old = ManagementAPIClient(baseURL: "https://" + host + ManagementAPIClient.managementPath,
            authKey: "old-management", configuration: transport)
        let replacement = ManagementAPIClient(baseURL: "https://unused.invalid" + ManagementAPIClient.managementPath,
            authKey: "new-management", configuration: transport)
        addTeardownBlock { @MainActor in
            gate.release(.fail(.cancelled))
            root.setAuthImportClientForTesting(nil)
            await old.invalidate(); await replacement.invalidate()
            LifecycleHTTPProtocol.remove(host: host)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        root.setAuthImportClientForTesting(old)
        let model = selection().catalog[0]
        let setup = AgentSetupViewModel(configurationService: AgentConfigurationService(homeDirectory: directory),
            fetchModels: { _, _ in [model] }, configurationEndpoint: { "https://fixture.invalid" })
        setup.quotaViewModel = root
        setup.selectedAgent = .claudeCode
        setup.currentConfiguration = .init(agent: .claudeCode, proxyURL: "https://fixture.invalid/v1", apiKey: "client-only")
        let request = Task { await setup.loadModels() }
        await fulfillment(of: [started], timeout: 2)
        root.setAuthImportClientForTesting(replacement)
        gate.release(.reply(#"{"models":[{"id":"shared-id","display_name":"Old Account Model"}]}"#))
        let committed = await request.value
        XCTAssertFalse(committed)
        XCTAssertTrue(setup.availableModels.isEmpty)
        XCTAssertTrue(setup.claudeCompatibilityModels.isEmpty)
        XCTAssertFalse(setup.isFetchingModels, "失效请求仍应释放自己持有的加载状态")
        XCTAssertEqual(setup.currentConfiguration?.apiKey, "client-only")
    }
}
