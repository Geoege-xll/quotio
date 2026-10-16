import XCTest
@testable import QuotioPlus

/// 动态默认方案的定向回归：通过注入目录读取、临时用户目录和显式响应屏障验证，
/// 不读取真实账号、不启动 CPA，也不依赖厂商当前型号或公网连通性。
@MainActor
final class DynamicModelConfigurationTests: XCTestCase {
    private func model(_ id: String) -> AvailableModel {
        AvailableModel(id: id, name: id, provider: "fixture", isDefault: false)
    }

    private func configure(_ viewModel: AgentSetupViewModel, model: String = "saved/custom") {
        viewModel.selectedAgent = .codexCLI
        viewModel.currentConfiguration = AgentConfiguration(agent: .codexCLI,
            proxyURL: "https://fixture.invalid/v1", apiKey: "fixture-key", savedModelSlots: [.sonnet: model])
    }

    private actor Gate {
        let started: XCTestExpectation
        private var continuation: CheckedContinuation<[AvailableModel], Never>?
        init(_ started: XCTestExpectation) { self.started = started }
        func fetch() async -> [AvailableModel] {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        func release(_ result: [AvailableModel]) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    func testLiveDirectoryAndManualSelectionPreserveSavedModel() async {
        let models = [model("service-new-model"), model("gpt-5-codex")]
        let viewModel = AgentSetupViewModel(fetchModels: { url, key in
            XCTAssertEqual(url, "https://fixture.invalid/v1")
            XCTAssertEqual(key, "fixture-key")
            return models
        })
        configure(viewModel)
        let success = await viewModel.loadModels()
        XCTAssertTrue(success)
        XCTAssertEqual(Set(viewModel.availableModels), Set(models))
        XCTAssertEqual(viewModel.currentConfiguration?.codexModel, "saved/custom")
        XCTAssertNil(viewModel.modelLoadMessage)
        viewModel.updateDefaultModel("manual/not-in-directory")
        XCTAssertEqual(viewModel.currentConfiguration?.codexModel, "manual/not-in-directory")
        XCTAssertNil(viewModel.configurationValidationMessage)
    }

    func testEmptyAndFailedDirectoryDoNotInjectCandidatesOrChangeSelection() async {
        for fails in [false, true] {
            let viewModel = AgentSetupViewModel(fetchModels: { _, _ in
                if fails { throw URLError(.notConnectedToInternet) }
                return []
            })
            configure(viewModel)
            viewModel.availableModels = [model("previous-service-model")]
            let success = await viewModel.loadModels()
            XCTAssertEqual(success, !fails)
            XCTAssertTrue(viewModel.availableModels.isEmpty)
            XCTAssertEqual(viewModel.currentConfiguration?.codexModel, "saved/custom")
            XCTAssertNotNil(viewModel.modelLoadMessage)
            XCTAssertFalse(viewModel.isFetchingModels)
        }
    }

    func testMissingClientKeyNeverRequestsDirectoryOrReplacesSavedModel() async {
        let viewModel = AgentSetupViewModel(fetchModels: { _, _ in
            XCTFail("未取得客户端 key 时不能发送目录请求，更不能拿管理密钥回退")
            return []
        })
        configure(viewModel)
        viewModel.currentConfiguration?.apiKey = "  "
        let success = await viewModel.loadModels()
        XCTAssertFalse(success)
        XCTAssertTrue(viewModel.availableModels.isEmpty)
        XCTAssertEqual(viewModel.currentConfiguration?.codexModel, "saved/custom")
        XCTAssertNotNil(viewModel.modelLoadMessage)
        XCTAssertNotNil(viewModel.configurationValidationMessage)
        await viewModel.applyConfiguration()
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isConfiguring)
        viewModel.selectedSetupMode = .defaultSetup
        XCTAssertNil(viewModel.configurationValidationMessage, "恢复非代理模式不要求客户端 key")
    }

    func testNewCodexNeedsExplicitSelectionButClaudeRolesRemainNative() async {
        let viewModel = AgentSetupViewModel(fetchModels: { _, _ in [] })
        configure(viewModel, model: "")
        XCTAssertNotNil(viewModel.configurationValidationMessage)
        await viewModel.applyConfiguration()
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isConfiguring)
        viewModel.updateDefaultModel("actual-service-model")
        XCTAssertNil(viewModel.configurationValidationMessage)
        viewModel.selectedSetupMode = .defaultSetup
        viewModel.updateDefaultModel("")
        XCTAssertNil(viewModel.configurationValidationMessage, "恢复客户端默认模式不要求代理模型")
        for agent in CLIAgent.allCases where agent != .claudeCode {
            XCTAssertTrue(AgentConfiguration(agent: agent, proxyURL: "", apiKey: "").modelSlots.isEmpty)
        }
        let claude = AgentConfiguration(agent: .claudeCode, proxyURL: "", apiKey: "")
        XCTAssertEqual(claude.claudeModel, "opus")
        XCTAssertEqual(claude.modelSlots[.sonnet], "sonnet")
        XCTAssertFalse(claude.claudeModelPicker.shouldWrite)
    }

    func testLateDirectoryCannotOverwriteNewRefreshOrItsLoadingState() async {
        let oldStarted = expectation(description: "旧目录读取挂起")
        let newStarted = expectation(description: "新目录读取挂起")
        let old = Gate(oldStarted), new = Gate(newStarted)
        let viewModel = AgentSetupViewModel(fetchModels: { _, key in
            await (key == "fixture-key" ? old : new).fetch()
        })
        configure(viewModel)
        let oldTask = Task { await viewModel.loadModels() }
        await fulfillment(of: [oldStarted], timeout: 2)
        viewModel.resetSheetState()
        XCTAssertTrue(viewModel.isFetchingModels, "onAppear 的表单重置不能使刚启动的读取失效")
        viewModel.currentConfiguration?.apiKey = "new-key"
        let newTask = Task { await viewModel.loadModels() }
        await fulfillment(of: [newStarted], timeout: 2)
        await old.release([model("stale-model")])
        let oldSuccess = await oldTask.value
        XCTAssertFalse(oldSuccess)
        XCTAssertTrue(viewModel.availableModels.isEmpty)
        XCTAssertTrue(viewModel.isFetchingModels, "旧 defer 不得结束新请求的加载状态")
        await new.release([model("new-model")])
        let newSuccess = await newTask.value
        XCTAssertTrue(newSuccess)
        XCTAssertEqual(viewModel.availableModels.map(\.id), ["new-model"])
        XCTAssertFalse(viewModel.isFetchingModels)
    }

    func testDismissReopenAndChangedEndpointRejectLateDirectory() async {
        for reopens in [false, true] {
            let started = expectation(description: "目录读取挂起")
            let gate = Gate(started)
            let viewModel = AgentSetupViewModel(fetchModels: { _, _ in await gate.fetch() })
            configure(viewModel)
            let task = Task { await viewModel.loadModels() }
            await fulfillment(of: [started], timeout: 2)
            if reopens {
                viewModel.dismissConfiguration()
                configure(viewModel, model: "new-session-model")
            } else {
                viewModel.currentConfiguration?.proxyURL = "https://other.invalid/v1"
            }
            await gate.release([model("old-source-model")])
            let success = await task.value
            XCTAssertFalse(success)
            XCTAssertTrue(viewModel.availableModels.isEmpty)
            XCTAssertNil(viewModel.modelLoadMessage)
            XCTAssertEqual(viewModel.currentConfiguration?.codexModel, reopens ? "new-session-model" : "saved/custom")
        }
    }

    func testProviderSearchKeepsFullDirectoryAndCustomAliases() {
        let models = [model("custom-new"), model("gpt-5-codex"), model("other-new"), model("custom-new")]
        XCTAssertEqual(CustomProviderSheet.matchingModels(from: models, search: ""), models)
        XCTAssertEqual(CustomProviderSheet.matchingModels(from: models, search: "CUSTOM").map(\.id), ["custom-new", "custom-new"])
    }

    func testEmptyNewConfigurationNeverWritesFilesAndDynamicCatalogGeneratesOnlyReturnedIDs() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("DynamicModels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = AgentConfigurationService(homeDirectory: home)
        for agent in [CLIAgent.codexCLI, .openCode, .factoryDroid] {
            let config = AgentConfiguration(agent: agent, proxyURL: "https://fixture.invalid/v1", apiKey: "fixture")
            let result = try await service.generateConfiguration(agent: agent, config: config, mode: .automatic,
                detectionService: AgentDetectionService(), availableModels: [])
            XCTAssertFalse(result.success)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
        }
        for agent in [CLIAgent.openCode, .factoryDroid] {
            let config = AgentConfiguration(agent: agent, proxyURL: "https://fixture.invalid/v1", apiKey: "fixture")
            let result = try await service.generateConfiguration(agent: agent, config: config, mode: .manual,
                detectionService: AgentDetectionService(), availableModels: [model("only-live-model")])
            XCTAssertTrue(result.success, result.error ?? "")
            let output = try XCTUnwrap(result.rawConfigs.first).content
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            if agent == .openCode {
                let providers = try XCTUnwrap(object["provider"] as? [String: Any])
                let provider = try XCTUnwrap(providers["quotio"] as? [String: Any])
                let models = try XCTUnwrap(provider["models"] as? [String: Any])
                XCTAssertEqual(Set(models.keys), ["only-live-model"])
            } else {
                let models = try XCTUnwrap(object["custom_models"] as? [[String: Any]])
                XCTAssertEqual(models.compactMap { $0["model"] as? String }, ["only-live-model"])
            }
        }
    }
    func testMissingClientKeyCannotOverwriteExistingClientFiles() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("MissingClientKey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = AgentConfigurationService(homeDirectory: home)
        let files = [".claude/settings.json", ".codex/config.toml", ".factory/config.json", ".config/opencode/opencode.json"]
        for file in files {
            let url = home.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "existing-valid-credentials".write(to: url, atomically: true, encoding: .utf8)
        }
        for agent in CLIAgent.allCases {
            var config = AgentConfiguration(agent: agent, proxyURL: "https://fixture.invalid/v1", apiKey: "")
            config.modelSlots[.sonnet] = "saved/custom"
            let result = try await service.generateConfiguration(agent: agent, config: config, mode: .automatic,
                detectionService: AgentDetectionService(), availableModels: [model("actual-model")])
            XCTAssertFalse(result.success)
            for file in files {
                XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(file), encoding: .utf8), "existing-valid-credentials")
            }
        }
    }

    func testOfflineCatalogClientsKeepEverySavedModelAndItsMetadata() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("SavedDynamicModels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let openCodeURL = home.appendingPathComponent(".config/opencode/opencode.json")
        let factoryURL = home.appendingPathComponent(".factory/config.json")
        try FileManager.default.createDirectory(at: openCodeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: factoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let savedModels: [String: [String: Any]] = ["saved/first": ["name": "First", "limit": ["context": 42], "unknown": true],
            "saved/second": ["name": "Second", "options": ["custom": "preserve"]]]
        let savedFactory: [[String: Any]] = [["model": "saved/first", "model_display_name": "First", "unknown": true],
            ["model": "saved/second", "model_display_name": "Second", "max_output_tokens": 42]]
        try JSONSerialization.data(withJSONObject: ["plugin": ["keep"], "provider": ["quotio": ["models": savedModels,
            "options": ["baseURL": "http://localhost:8317/v1"]]]]).write(to: openCodeURL)
        try JSONSerialization.data(withJSONObject: ["custom_models": savedFactory]).write(to: factoryURL)
        let service = AgentConfigurationService(homeDirectory: home)
        for (agent, url) in [(CLIAgent.openCode, openCodeURL), (.factoryDroid, factoryURL)] {
            // 复现真实回填返回空槽的页面；服务必须读取原文件，不能只验证测试人造的角色槽。
            let loaded = await service.readConfiguration(agent: agent)
            let saved = try XCTUnwrap(loaded)
            XCTAssertTrue(saved.modelSlots.isEmpty)
            let config = AgentConfiguration(agent: agent, proxyURL: "https://new.invalid/v1", apiKey: "new-key", savedModelSlots: saved.modelSlots)
            let result = try await service.generateConfiguration(agent: agent, config: config, mode: .automatic,
                detectionService: AgentDetectionService(), availableModels: [])
            XCTAssertTrue(result.success, result.error ?? "")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            if agent == .openCode {
                let providers = try XCTUnwrap(object["provider"] as? [String: Any])
                let provider = try XCTUnwrap(providers["quotio"] as? [String: Any])
                XCTAssertEqual(provider["models"] as? NSDictionary, savedModels as NSDictionary)
                XCTAssertEqual(object["plugin"] as? [String], ["keep"])
            } else {
                let models = try XCTUnwrap(object["custom_models"] as? [[String: Any]])
                XCTAssertEqual(models.compactMap { $0["model"] as? String }, ["saved/first", "saved/second"])
                XCTAssertEqual(models[0]["unknown"] as? Bool, true)
                XCTAssertEqual(models[1]["max_output_tokens"] as? Int, 42)
                XCTAssertTrue(models.allSatisfy { $0["api_key"] as? String == "new-key" && $0["base_url"] as? String == "https://new.invalid/v1" })
            }
        }
    }

    // MARK: - 真实提交与目录重试的专项审计回归

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DynamicModelAudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeJSON(_ value: [String: Any], _ path: String, home: URL) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: url)
        return url
    }

    func testFirstCatalogConfigurationWaitsForDirectoryThenApplies() async throws {
        for agent in [CLIAgent.openCode, .factoryDroid] {
            let started = expectation(description: "首次目录仍在读取")
            let gate = Gate(started)
            let vm = AgentSetupViewModel(configurationService: AgentConfigurationService(homeDirectory: try temporaryHome()),
                fetchModels: { _, _ in await gate.fetch() })
            vm.selectedAgent = agent
            vm.currentConfiguration = AgentConfiguration(agent: agent, proxyURL: "https://fixture.invalid/v1", apiKey: "fixture")
            vm.configurationMode = .manual
            let loading = Task { await vm.loadModels() }
            await fulfillment(of: [started], timeout: 2)
            XCTAssertNotNil(vm.configurationValidationMessage)
            await vm.applyConfiguration()
            XCTAssertNil(vm.configResult, "首次读取未完成不能进入失败结果页")
            await gate.release([model("actual-first-model")])
            let loaded = await loading.value
            XCTAssertTrue(loaded)
            XCTAssertNil(vm.configurationValidationMessage)
            await vm.applyConfiguration()
            XCTAssertEqual(vm.configResult?.success, true)
            XCTAssertTrue(vm.configResult?.rawConfigs.first?.content.contains("actual-first-model") == true)
        }
    }

    private actor RetryDirectory {
        private var count = 0
        func fetch(_ model: AvailableModel) throws -> [AvailableModel] {
            count += 1
            if count == 1 { throw URLError(.notConnectedToInternet) }
            return [model]
        }
    }

    func testDirectoryAndSaveFailuresCanRetryInSameDraft() async throws {
        for agent in [CLIAgent.openCode, .factoryDroid] {
            let retries = RetryDirectory(), actual = model("actual-retry-model")
            let vm = AgentSetupViewModel(configurationService: AgentConfigurationService(homeDirectory: try temporaryHome()),
                fetchModels: { _, _ in try await retries.fetch(actual) })
            vm.selectedAgent = agent
            vm.currentConfiguration = AgentConfiguration(agent: agent, proxyURL: "https://fixture.invalid/v1", apiKey: "fixture")
            vm.configurationMode = .manual
            let initial = await vm.loadModels()
            XCTAssertFalse(initial)
            await vm.applyConfiguration()
            XCTAssertEqual(vm.configResult?.success, false)
            vm.currentConfiguration?.claudeAutoCompactPercentage = 73 // 用原草稿的非默认值检测重试是否重建配置。
            vm.retryConfiguration()
            XCTAssertNil(vm.configResult)
            XCTAssertNil(vm.errorMessage)
            XCTAssertEqual(vm.currentConfiguration?.claudeAutoCompactPercentage, 73)
            let loaded = await vm.loadModels(forceRefresh: true)
            XCTAssertTrue(loaded)
            await vm.applyConfiguration()
            XCTAssertEqual(vm.configResult?.success, true)
            XCTAssertEqual(vm.currentConfiguration?.claudeAutoCompactPercentage, 73)
        }
    }

    func testCancelledOldCallerCannotClearNewDirectory() async {
        let started = expectation(description: "旧调用方挂起")
        let gate = Gate(started)
        let vm = AgentSetupViewModel(fetchModels: { _, _ in XCTFail("已取消调用不得发送新请求"); return [] })
        configure(vm)
        vm.availableModels = [model("current-session-model")]
        let old = Task {
            _ = await gate.fetch()
            return await vm.loadModels()
        }
        await fulfillment(of: [started], timeout: 2)
        old.cancel()
        await gate.release([])
        let loaded = await old.value
        XCTAssertFalse(loaded)
        XCTAssertEqual(vm.availableModels.map(\.id), ["current-session-model"])
        XCTAssertFalse(vm.isFetchingModels)
    }

    func testFormAppearanceKeepsRestoredDefaultMode() {
        let vm = AgentSetupViewModel()
        vm.selectedAgent = .codexCLI
        vm.currentConfiguration = AgentConfiguration(agent: .codexCLI, proxyURL: "", apiKey: "", setupMode: .defaultSetup)
        vm.selectedSetupMode = .defaultSetup
        vm.resetSheetState()
        XCTAssertEqual(vm.selectedSetupMode, .defaultSetup)
        XCTAssertEqual(vm.currentConfiguration?.setupMode, .defaultSetup)
        XCTAssertNil(vm.configurationValidationMessage)
    }

    func testConnectionProbeRejectsMissingClientKeyBeforeURLParsing() async {
        let vm = AgentSetupViewModel()
        for agent in CLIAgent.allCases {
            vm.selectedAgent = agent
            // 无效 URL 保证回归即使缺少屏障也不会接触公网；具体返回文案区分认证屏障与 URL 探测。
            vm.currentConfiguration = AgentConfiguration(agent: agent, proxyURL: "http://[", apiKey: " ")
            await vm.testConnection()
            XCTAssertEqual(vm.testResult?.message, "agents.models.clientKeyRequired".localized())
            XCTAssertEqual(vm.testResult?.success, false)
            XCTAssertNil(vm.testResult?.latencyMs)
            XCTAssertFalse(vm.isTesting)
        }
    }

    func testSuccessfulRefreshMergesOpenCodeModelsAndProviderMetadata() async throws {
        let home = try temporaryHome()
        let previousModels: [String: Any] = ["old-only": ["name": "Old", "limit": ["context": 42]],
            "same-model": ["name": "User Name", "custom": true, "options": ["user": 7]]]
        let url = try writeJSON(["model": "quotio/old-only", "plugin": ["user-plugin"],
            "provider": ["other": ["keep": true], "quotio": ["npm": "custom-adapter", "unknown": 9,
                "options": ["headers": ["x-user": "keep"], "baseURL": "https://fixture.invalid/v1"], "models": previousModels]]],
            ".config/opencode/opencode.json", home: home)
        let service = AgentConfigurationService(homeDirectory: home)
        var config = AgentConfiguration(agent: .openCode, proxyURL: "https://fixture.invalid/v1", apiKey: "new-key")
        config.modelSlots[.sonnet] = "explicit-model"
        let result = try await service.generateConfiguration(agent: .openCode, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: [model("same-model"), model("new-model")])
        XCTAssertTrue(result.success, result.error ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let providers = try XCTUnwrap(object["provider"] as? [String: Any])
        let quotio = try XCTUnwrap(providers["quotio"] as? [String: Any])
        let models = try XCTUnwrap(quotio["models"] as? [String: Any])
        XCTAssertEqual(Set(models.keys), ["old-only", "same-model", "new-model", "explicit-model"])
        XCTAssertEqual(models["old-only"] as? NSDictionary, previousModels["old-only"] as? NSDictionary)
        XCTAssertEqual(models["same-model"] as? NSDictionary, previousModels["same-model"] as? NSDictionary)
        XCTAssertEqual(quotio["npm"] as? String, "custom-adapter")
        XCTAssertEqual(quotio["unknown"] as? Int, 9)
        XCTAssertEqual((quotio["options"] as? [String: Any])?["headers"] as? NSDictionary, ["x-user": "keep"])
        XCTAssertEqual(object["model"] as? String, "quotio/old-only")
        XCTAssertEqual(object["plugin"] as? [String], ["user-plugin"])
        XCTAssertNotNil(result.backupPath)
    }

    func testSuccessfulRefreshKeepsFactorySettingsModelsAndOtherServiceCredentials() async throws {
        let home = try temporaryHome()
        let external: [String: Any] = ["model": "same-model", "base_url": "https://other.invalid/v1", "api_key": "external-key", "provider": "anthropic"]
        let models: [[String: Any]] = [
            ["model": "old-only", "base_url": "https://fixture.invalid/v1", "unknown": true],
            ["model": "same-model", "base_url": "https://fixture.invalid/v1/", "model_display_name": "User Name", "max_output_tokens": 42], external]
        let url = try writeJSON(["custom_models": models, "mcpServers": ["user": ["command": "keep"]], "unknown": 73],
            ".factory/config.json", home: home)
        let service = AgentConfigurationService(homeDirectory: home)
        let config = AgentConfiguration(agent: .factoryDroid, proxyURL: "https://fixture.invalid/v1", apiKey: "new-key")
        let result = try await service.generateConfiguration(agent: .factoryDroid, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: [model("same-model"), model("new-model"), model("new-model")])
        XCTAssertTrue(result.success, result.error ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let merged = try XCTUnwrap(object["custom_models"] as? [[String: Any]])
        XCTAssertEqual(merged.compactMap { $0["model"] as? String }, ["old-only", "same-model", "same-model", "new-model"])
        XCTAssertEqual(merged[0]["unknown"] as? Bool, true)
        XCTAssertEqual(merged[1]["max_output_tokens"] as? Int, 42)
        XCTAssertEqual(merged[1]["model_display_name"] as? String, "User Name")
        XCTAssertEqual(merged[0]["api_key"] as? String, "new-key")
        XCTAssertEqual(merged[2] as NSDictionary, external as NSDictionary)
        XCTAssertEqual(object["unknown"] as? Int, 73)
        XCTAssertNotNil(object["mcpServers"])
        XCTAssertNotNil(result.backupPath)
    }

    func testMalformedFactoryFileCannotBeOverwrittenByLiveDirectory() async throws {
        for malformed in ["not-json", "[]", #"{"custom_models":"invalid"}"#] {
            let home = try temporaryHome()
            let url = home.appendingPathComponent(".factory/config.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try malformed.write(to: url, atomically: true, encoding: .utf8)
            let config = AgentConfiguration(agent: .factoryDroid, proxyURL: "https://fixture.invalid/v1", apiKey: "fixture")
            let result = try await AgentConfigurationService(homeDirectory: home).generateConfiguration(agent: .factoryDroid,
                config: config, mode: .automatic, detectionService: AgentDetectionService(), availableModels: [model("actual")])
            XCTAssertFalse(result.success)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), malformed)
        }
    }

    func testClientConfigKeepsVersionedHostnameAndDeploymentPrefix() async throws {
        let service = AgentConfigurationService(homeDirectory: try temporaryHome())
        for agent in CLIAgent.allCases {
            var config = AgentConfiguration(agent: agent, proxyURL: "https://v1.fixture.invalid/prefix/v1/", apiKey: "fixture")
            config.modelSlots[.sonnet] = "actual-model"
            let result = try await service.generateConfiguration(agent: agent, config: config, mode: .manual,
                detectionService: AgentDetectionService(), availableModels: [model("actual-model")])
            XCTAssertTrue(result.success, result.error ?? "")
            XCTAssertTrue(result.rawConfigs.contains { $0.content.contains("https://v1.fixture.invalid/prefix") }, agent.rawValue)
            XCTAssertFalse(result.rawConfigs.contains { $0.content.contains("https:/.fixture") })
        }
        let url = try XCTUnwrap(ModelCatalogClient.modelsURL(baseURL: "https://v1.fixture.invalid/prefix/v1/?team=fixture#note"))
        XCTAssertEqual(url.path, "/prefix/v1/models")
        XCTAssertEqual(url.query, "team=fixture")
        XCTAssertNil(url.fragment)
    }

    func testPiDirectoryFailureKeepsFilesAndRetryPreservesChosenOldModel() async throws {
        let home = try temporaryHome(), retries = RetryDirectory(), old = model("old-saved-model")
        let urls = PiAgentSupport.configURLs(homeDirectory: home)
        try FileManager.default.createDirectory(at: urls[0].deletingLastPathComponent(), withIntermediateDirectories: true)
        let provider: [String: Any] = ["baseUrl": "https://old.invalid", "apiKey": "old-key", "unknown": 7]
        let settings: [String: Any] = ["packages": [PiAgentSupport.package, "user-package"], "defaultProvider": PiAgentSupport.provider,
            "defaultModel": old.id, "user-setting": true]
        try JSONSerialization.data(withJSONObject: provider).write(to: urls[0])
        try JSONSerialization.data(withJSONObject: settings).write(to: urls[1])
        let before = try urls.map { try Data(contentsOf: $0) }
        let service = PiAgentConfigurationService(homeDirectory: home, fetchModels: { _, _ in try await retries.fetch(old) })
        var config = AgentConfiguration(agent: .pi, proxyURL: "https://fixture.invalid/v1", apiKey: "new-key")
        config.modelSlots[.sonnet] = old.id
        do {
            _ = try await service.generate(config: config, mode: .automatic, detectionService: AgentDetectionService())
            XCTFail("目录失败不能进入写文件或安装流程")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
        let result = try await service.generate(config: config, mode: .automatic, detectionService: AgentDetectionService())
        XCTAssertTrue(result.success)
        let latestProvider = try PiAgentSupport.object(at: urls[0]), latestSettings = try PiAgentSupport.object(at: urls[1])
        XCTAssertEqual(latestProvider["apiKey"] as? String, "new-key")
        XCTAssertEqual(latestProvider["unknown"] as? Int, 7)
        XCTAssertEqual(latestSettings["defaultModel"] as? String, old.id)
        XCTAssertEqual(latestSettings["packages"] as? [String], [PiAgentSupport.package, "user-package"])
        XCTAssertEqual(latestSettings["user-setting"] as? Bool, true)
    }

    func testEmptyOrWhitespaceClientFilesStillSupportFirstConfiguration() async throws {
        for agent in [CLIAgent.openCode, .factoryDroid] {
            for original in ["", " \n\t "] {
                let home = try temporaryHome()
                let url = home.appendingPathComponent(agent == .openCode ? ".config/opencode/opencode.json" : ".factory/config.json")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try original.write(to: url, atomically: true, encoding: .utf8)
                let config = AgentConfiguration(agent: agent, proxyURL: "https://fixture.invalid/v1", apiKey: "fixture")
                let result = try await AgentConfigurationService(homeDirectory: home).generateConfiguration(agent: agent,
                    config: config, mode: .automatic, detectionService: AgentDetectionService(), availableModels: [model("first-model")])
                XCTAssertTrue(result.success, result.error ?? "")
                XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("first-model"))
                XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(result.backupPath)), encoding: .utf8), original)
            }
        }
    }

}
