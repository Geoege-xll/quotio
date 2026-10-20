import XCTest
@testable import QuotioPlus

/// 真实账号启停入口的离线集成回归：管理 API 使用 URLProtocol，配置目录使用注入的当前服务响应。
/// 不启动／停止 CPA，不读取真实认证目录；隔离偏好且禁止额度后台批次，验证成功、失败和迟到响应边界。
@MainActor
final class AccountModelCatalogRefreshTests: XCTestCase {
    private actor Catalog {
        private(set) var count = 0
        func fetch() -> [AvailableModel] {
            count += 1
            let ids = count == 2 ? ["shared-model"] : ["shared-model", "exclusive-model"]
            return ids.map { AvailableModel(id: $0, name: $0, provider: "fixture", isDefault: false) }
        }
    }
    private struct Fixture {
        let root: QuotaViewModel
        let setup: AgentSetupViewModel
        let catalog: Catalog
        let state: LifecycleHTTPState
        let mode: OperatingModeManager
        let disabled: AuthFile
        let enabled: AuthFile
    }

    private func fixture(status: Int = 200, gate: LifecycleHTTPResponseGate? = nil,
                         started: XCTestExpectation? = nil) async throws -> Fixture {
        let suite = "quotio-account-models-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(OperatingMode.localProxy.rawValue, forKey: "operatingMode")
        let mode = OperatingModeManager(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = QuotaViewModel(directAuthService: DirectAuthFileService(authDirectory: directory),
            startsBackgroundServices: false, modeManager: mode, menuBarSettings: MenuBarSettingsManager(defaults: defaults),
            refreshSettings: RefreshSettingsManager(defaults: defaults), warmupSettings: WarmupSettingsManager(defaults: defaults),
            notificationManager: NotificationManager(testDefaults: defaults, notificationSink: { _ in }))
        root.customProvidersForTesting = []
        // refreshData 保持生产路径，但最近刷新时间阻止其创建额外额度取数 Task。
        root.recordQuotaRefreshStart()
        let manager = root.proxyManager, oldStatus = manager.proxyStatus, oldSession = manager.runtimeSessionID
        manager.setRuntimeStateForTesting(running: true, sessionID: UUID())
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState { request, _ in
            switch request.url?.path {
            case "/v8/management/routing/cooldown/reset":
                return .replyStatus(#"{"status":"ok","config-version":8}"#, status)
            case "/v8/management/credentials/status":
                XCTAssertEqual(request.httpMethod, "PATCH")
                if let gate { started?.fulfill(); return .deferred(gate) }
                return .replyStatus(#"{"status":"ok","config-version":8}"#, status)
            case "/v8/management/credentials":
                if request.httpMethod == "POST" { return .replyStatus(#"{"status":"ok","config-version":8}"#, status) }
                if request.httpMethod == "DELETE" { return .replyStatus(#"{"status":"ok","config-version":8}"#, status) }
                return .reply(#"{"files":[]}"#)
            case "/v8/management/config/access/api-keys": return .reply(#"["fixture-client-key"]"#)
            default: return .fail(.unsupportedURL)
            }
        }
        LifecycleHTTPProtocol.register(state, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        let client = ManagementAPIClient(baseURL: "https://" + host + ManagementAPIClient.managementPath,
            authKey: "fixture-management-key", configuration: configuration)
        root.setAuthImportClientForTesting(client)
        let catalog = Catalog()
        let setup = AgentSetupViewModel(configurationService: AgentConfigurationService(homeDirectory: directory),
            fetchModels: { _, _ in await catalog.fetch() })
        setup.selectedAgent = .codexCLI
        var config = AgentConfiguration(agent: .codexCLI, proxyURL: manager.baseURL + "/v1", apiKey: "fixture-client-key")
        config.codexModel = "exclusive-model"
        setup.currentConfiguration = config
        root.setAgentSetupViewModelForTesting(setup)
        let name = "isolated-" + UUID().uuidString + ".json"
        let enabled = try JSONDecoder().decode(AuthFile.self, from: Data("{\"name\":\"\(name)\",\"provider\":\"codex\",\"disabled\":false}".utf8))
        let disabled = try JSONDecoder().decode(AuthFile.self, from: Data("{\"name\":\"\(name)\",\"provider\":\"codex\",\"disabled\":true}".utf8))
        let oldDisabled = UserDefaults.standard.stringArray(forKey: "persisted.disabledAuthFiles")
        addTeardownBlock { @MainActor in
            root.stopQuotaAutoRefresh()
            manager.setRuntimeStateForTesting(running: oldStatus.running, sessionID: oldSession)
            await client.invalidate()
            LifecycleHTTPProtocol.remove(host: host)
            defaults.removePersistentDomain(forName: suite)
            if let oldDisabled { UserDefaults.standard.set(oldDisabled, forKey: "persisted.disabledAuthFiles") }
            else { UserDefaults.standard.removeObject(forKey: "persisted.disabledAuthFiles") }
            try? FileManager.default.removeItem(at: directory)
        }
        let loaded = await setup.loadModels()
        XCTAssertTrue(loaded)
        return Fixture(root: root, setup: setup, catalog: catalog, state: state, mode: mode, disabled: disabled, enabled: enabled)
    }

    func testDisableAndEnableReloadCatalogAndRetainSharedModelAndOldSelection() async throws {
        let f = try await fixture()
        XCTAssertEqual(Set(f.setup.currentModelCandidates.map(\.id)), ["shared-model", "exclusive-model"])
        await f.root.toggleAuthFileDisabled(f.enabled)
        XCTAssertEqual(f.setup.currentModelCandidates.map(\.id), ["shared-model"], "其它账号仍提供的模型继续保留")
        XCTAssertEqual(f.setup.currentConfiguration?.codexModel, "exclusive-model", "停用账号不能删除旧配置")
        let unconfirmed = AgentModelCandidatePolicy(agent: .codexCLI, models: f.setup.currentModelCandidates,
            aliases: [], selectedModel: "exclusive-model")
        XCTAssertTrue(unconfirmed.hasUnconfirmedSelection)
        await f.root.toggleAuthFileDisabled(f.disabled)
        XCTAssertEqual(Set(f.setup.currentModelCandidates.map(\.id)), ["shared-model", "exclusive-model"])
        let count = await f.catalog.count
        XCTAssertEqual(count, 3, "初次、停用后、启用后各请求一轮目录")
        let bodies = try f.state.requests.filter { $0.url.path.hasSuffix("/credentials/status") }.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.body)) as? [String: Any])
        }
        XCTAssertEqual(bodies.compactMap { $0["disabled"] as? Bool }, [true, false])
        XCTAssertNil(f.root.errorMessage)
    }

    func testFailedToggleDoesNotInvalidateOrReloadCurrentDirectory() async throws {
        let f = try await fixture(status: 403)
        let before = f.setup.currentModelCandidates
        let revision = f.setup.currentModelCatalogRevision
        await f.root.toggleAuthFileDisabled(f.enabled)
        XCTAssertNotNil(f.root.errorMessage)
        XCTAssertEqual(f.setup.currentModelCandidates, before)
        XCTAssertEqual(f.setup.currentModelCatalogRevision, revision)
        let count = await f.catalog.count
        XCTAssertEqual(count, 1)
    }

    func testOldToggleResponseCannotInvalidateNewProxySessionModels() async throws {
        let started = expectation(description: "旧代理会话的停用请求挂起")
        let gate = LifecycleHTTPResponseGate()
        let f = try await fixture(gate: gate, started: started)
        let mutation = Task { await f.root.toggleAuthFileDisabled(f.enabled) }
        await fulfillment(of: [started], timeout: 2)
        f.root.proxyManager.setRuntimeStateForTesting(running: true, sessionID: UUID())
        let refreshed = await f.setup.loadModels()
        XCTAssertTrue(refreshed)
        let before = f.setup.currentModelCandidates
        let revision = f.setup.currentModelCatalogRevision
        gate.release(.reply(#"{"status":"ok","config-version":8}"#))
        await mutation.value
        XCTAssertEqual(f.setup.currentModelCandidates, before)
        XCTAssertEqual(f.setup.currentModelCatalogRevision, revision)
        let count = await f.catalog.count
        XCTAssertEqual(count, 2)
        XCTAssertNil(f.root.errorMessage)
    }
    func testDeletionReloadsModelCatalogAndPreservesExistingSelection() async throws {
        let f = try await fixture()
        await f.root.deleteAuthFile(f.enabled)
        XCTAssertEqual(f.setup.currentModelCandidates.map(\.id), ["shared-model"])
        XCTAssertEqual(f.setup.currentConfiguration?.codexModel, "exclusive-model")
        let count = await f.catalog.count
        XCTAssertEqual(count, 2)
        XCTAssertTrue(f.state.requests.contains { $0.method == "DELETE" && $0.url.path.hasSuffix("/credentials") })
    }

    func testSingleAndBatchCooldownRecoveryReloadModelSourcesOnlyAfterSuccess() async throws {
        for batch in [false, true] {
            let f = try await fixture()
            f.root.authFiles = [.init(id: "cooling", name: "cooling.json", provider: "codex", authIndex: "cooling-index",
                cooldowns: [.init(scope: "credential", remainingSeconds: 60)])]
            if batch { await f.root.resetAllCooldowns() }
            else { await f.root.resetAuthFileCooldown(authIndex: "cooling-index") }
            let count = await f.catalog.count
            XCTAssertEqual(count, 2)
            XCTAssertEqual(f.setup.currentModelCandidates.map(\.id), ["shared-model"])
            XCTAssertEqual(f.setup.currentConfiguration?.codexModel, "exclusive-model")
        }
        let failed = try await fixture(status: 403)
        await failed.root.resetAuthFileCooldown(authIndex: "cooling-index")
        let count = await failed.catalog.count
        XCTAssertEqual(count, 1, "失败重置不能失效已有目录或多做模型请求")
    }

    func testSuccessfulCredentialUploadUsesSameModelSourceRefreshBridge() async throws {
        let f = try await fixture()
        try await f.root.uploadAuthFile(name: "new-fixture.json", content: Data("{}".utf8))
        let count = await f.catalog.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(f.setup.currentConfiguration?.codexModel, "exclusive-model")
    }

}
