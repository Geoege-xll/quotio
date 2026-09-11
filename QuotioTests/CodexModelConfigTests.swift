import XCTest
@testable import Quotio

final class CodexModelConfigTests: XCTestCase {
    private var homeDirectory: URL!
    private var service: AgentConfigurationService!

    override func setUpWithError() throws {
        // 完整配置读写在独立临时目录进行，保护真实的 Codex 登录态与用户文件。
        homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexModelConfigTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: homeDirectory.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        service = AgentConfigurationService(homeDirectory: homeDirectory)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: homeDirectory)
    }

    private var configURL: URL { homeDirectory.appendingPathComponent(".codex/config.toml") }

    private func read(_ content: String) async throws -> AgentConfigurationService.SavedAgentConfig {
        try content.write(to: configURL, atomically: true, encoding: .utf8)
        let result = await service.readConfiguration(agent: .codexCLI)
        return try XCTUnwrap(result)
    }

    func testFreshCodexConfigurationNeverUsesClaudeSlotDefaults() {
        let config = AgentConfiguration(agent: .codexCLI, proxyURL: "", apiKey: "")
        XCTAssertEqual(config.modelSlots, [.sonnet: "gpt-5-codex"])
        XCTAssertEqual(config.codexModel, "gpt-5-codex")
        let restored = AgentConfiguration(agent: .codexCLI, proxyURL: "", apiKey: "", savedModelSlots: [:])
        XCTAssertEqual(restored.codexModel, config.codexModel)
        let claude = AgentConfiguration(agent: .claudeCode, proxyURL: "", apiKey: "")
        XCTAssertEqual(claude.modelSlots[.sonnet], AvailableModel.defaultModels[.sonnet]?.name)
    }

    func testSavedCustomCodexModelAndEmptyFallback() {
        var config = AgentConfiguration(agent: .codexCLI, proxyURL: "", apiKey: "", savedModelSlots: [.sonnet: "custom/model"])
        XCTAssertEqual(config.codexModel, "custom/model")
        config.codexModel = "  "
        XCTAssertEqual(config.codexModel, AgentConfiguration.defaultCodexModel)
        config.modelSlots.removeValue(forKey: .sonnet)
        XCTAssertEqual(config.codexModel, AgentConfiguration.defaultCodexModel)
    }

    func testReadsOnlyTopLevelModelAndSelectedProvider() async throws {
        let saved = try await read("""
        model = "top-model"
        model_provider = "cliproxyapi"
        model_reasoning_effort = "high"
        [model_providers.cliproxyapi]
        base_url = "http://127.0.0.1:8317/v1"
        [profiles.review]
        model = "review-model"
        model_provider = "other"
        model_reasoning_effort = "low"
        [model_providers.other]
        base_url = "https://example.invalid/v1"
        """)
        XCTAssertEqual(saved.modelSlots[.sonnet], "top-model")
        XCTAssertEqual(saved.baseURL, "http://127.0.0.1:8317/v1")
        XCTAssertEqual(saved.reasoningEffort, .high)
        XCTAssertTrue(saved.isProxyConfigured)
    }

    func testQuotedProviderTablesPreserveLocalEndpointAndDottedIDs() async throws {
        for (provider, table) in [("local", "model_providers.\"local\""), ("local.proxy", "model_providers.'local.proxy'"), ("local", "\"model_providers\" . 'local'")] {
            let saved = try await read("""
            model = "custom-model"
            model_provider = "\(provider)"
            [\(table)]
            base_url = "http://127.0.0.1:8317/v1"
            """)
            XCTAssertEqual(saved.baseURL, "http://127.0.0.1:8317/v1")
            XCTAssertTrue(saved.isProxyConfigured)
        }
    }

    func testInactiveLocalProviderDoesNotMarkRemoteProviderAsProxy() async throws {
        let saved = try await read("""
        model = "remote-model"
        model_provider = "remote"
        [model_providers.remote]
        base_url = "https://example.invalid/v1"
        [model_providers.cliproxyapi]
        base_url = "http://127.0.0.1:8317/v1"
        """)
        XCTAssertEqual(saved.baseURL, "https://example.invalid/v1")
        XCTAssertFalse(saved.isProxyConfigured)
    }

    func testMissingTopLevelModelDoesNotBorrowProfileOrArrayTableModel() async throws {
        for content in ["[profiles.review]\nmodel = 'profile-model'", "[[agents]]\nmodel = 'agent-model'"] {
            let saved = try await read(content)
            XCTAssertNil(saved.modelSlots[.sonnet])
        }
    }

    func testQuotedModelKeyLiteralValueAndTrailingComment() async throws {
        let saved = try await read("""
        # model = "comment-model"
        "model"='custom/model#literal' # 保留字符串内部的井号
        model_provider="cliproxyapi"
        [model_providers.cliproxyapi]
        base_url='http://127.0.0.1:8317/v1' # 行尾注释不属于 URL
        """)
        XCTAssertEqual(saved.modelSlots[.sonnet], "custom/model#literal")
        XCTAssertEqual(saved.baseURL, "http://127.0.0.1:8317/v1")
    }

    func testMultilineTextCannotInjectModelOrProvider() async throws {
        let saved = try await read(#"""
        instructions = """
        model = "fake-model"
        [profiles.fake]
        model_provider = "cliproxyapi"
        """
        model = "real-model"
        """#)
        XCTAssertEqual(saved.modelSlots[.sonnet], "real-model")
        XCTAssertFalse(saved.isProxyConfigured)
    }

    func testAutomaticReconfigureChangesOnlyTopLevelModelAndPreservesProfile() async throws {
        _ = try await read("""
        "model" = "old-model"
        model_provider = "cliproxyapi"
        custom_setting = "keep"
        [model_providers.cliproxyapi]
        base_url = "http://127.0.0.1:8317/v1"
        [profiles.review]
        model = "review-model"
        model_reasoning_effort = "low"
        """)
        var config = AgentConfiguration(agent: .codexCLI, proxyURL: "http://127.0.0.1:8317/v1", apiKey: "test-key")
        config.codexModel = "custom/new-model"
        let result = try await service.generateConfiguration(agent: .codexCLI, config: config, mode: .automatic, detectionService: AgentDetectionService())
        XCTAssertTrue(result.success, result.error ?? "")
        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(content.contains("model = \"custom/new-model\""))
        XCTAssertFalse(content.contains("old-model"))
        XCTAssertTrue(content.contains("custom_setting = \"keep\""))
        XCTAssertTrue(content.contains("[profiles.review]\nmodel = \"review-model\"\nmodel_reasoning_effort = \"low\""))
        let saved = await service.readConfiguration(agent: .codexCLI)
        XCTAssertEqual(saved?.modelSlots[.sonnet], "custom/new-model")
        XCTAssertNotNil(result.backupPath)
    }

    /// Codex 的菜单目录与启动模型分别配置；更换默认模型不能覆盖用户自建的菜单目录。
    func testReconfigurePreservesCustomCatalogAndCLISelectedModelRoundTrips() async throws {
        _ = try await read("""
        model = "old-model"
        model_catalog_json = "/custom/models.json"
        model_provider = "cliproxyapi"
        [model_providers.cliproxyapi]
        base_url = "http://127.0.0.1:8317/v1"
        """)
        var config = AgentConfiguration(agent: .codexCLI, proxyURL: "http://127.0.0.1:8317/v1", apiKey: "test-key")
        config.codexModel = "custom/proxy-alias"
        _ = try await service.generateConfiguration(
            agent: .codexCLI, config: config, mode: .automatic, detectionService: AgentDetectionService()
        )
        var content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(content.contains("model_catalog_json = \"/custom/models.json\""))
        XCTAssertTrue(content.contains("model = \"custom/proxy-alias\""))

        // 模拟 Codex /model 更新顶层选择；回填必须读取新值，不能返回旧别名或 Claude 角色槽默认值。
        content = content.replacingOccurrences(of: "model = \"custom/proxy-alias\"", with: "model = \"gpt-5.6-sol\"")
        let saved = try await read(content)
        XCTAssertEqual(saved.modelSlots[.sonnet], "gpt-5.6-sol")
        XCTAssertTrue(saved.isProxyConfigured)
    }

    @MainActor
    func testDefaultModelSelectionUpdatesOnlyTheSelectedAgent() {
        let viewModel = AgentSetupViewModel()
        viewModel.selectedAgent = .codexCLI
        viewModel.currentConfiguration = AgentConfiguration(agent: .codexCLI, proxyURL: "", apiKey: "")
        viewModel.updateDefaultModel("custom/codex")
        XCTAssertEqual(viewModel.currentConfiguration?.codexModel, "custom/codex")
        viewModel.selectedAgent = .claudeCode
        viewModel.currentConfiguration = AgentConfiguration(agent: .claudeCode, proxyURL: "", apiKey: "")
        let slots = viewModel.currentConfiguration?.modelSlots
        viewModel.updateDefaultModel("sonnet")
        XCTAssertEqual(viewModel.currentConfiguration?.claudeModel, "sonnet")
        XCTAssertEqual(viewModel.currentConfiguration?.modelSlots, slots)
    }
}
