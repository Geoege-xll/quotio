import XCTest
@testable import QuotioPlus

/// 纯展示规则与真实文件合并共同验证；凭据、模型目录和账号均为临时夹具，不发送推理请求。
final class ClaudeModelPresentationTests: XCTestCase {
    private var home: URL!
    private var service: AgentConfigurationService!
    private var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudePresentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        service = AgentConfigurationService(homeDirectory: home)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    private func model(_ id: String, platform: String?) -> AvailableModel {
        AvailableModel(id: id, name: id, provider: platform ?? "openai", isDefault: false, displayPlatform: platform)
    }
    private func read() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    }
    private func write(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
    }
    private func save(_ config: AgentConfiguration, models: [AvailableModel] = []) async throws -> AgentConfigResult {
        let result = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            storageOption: .both, detectionService: AgentDetectionService(), availableModels: models)
        XCTAssertTrue(result.success)
        return result
    }

    func testQualifiedSelectorsKeepPrefixContextAndRequestSpelling() {
        XCTAssertEqual(ClaudeModelPresentation.platformModel("zhipu/glm-5.3[1M]", availableModels: [model("zhipu/glm-5.3", platform: "openai")]), "zhipu/glm-5.3[1m]")
        XCTAssertEqual(ClaudeModelPresentation.platformModel("codex/gpt-6-astra"), "codex/gpt-6-astra")
    }
    func testBareModelsUseOnlyExplicitUniquePlatformMetadata() {
        XCTAssertEqual(ClaudeModelPresentation.platformModel("gemini-3.8-flash-high[1m]", availableModels: [model("gemini-3.8-flash-high", platform: "google")]), "google/gemini-3.8-flash-high[1m]")
        XCTAssertEqual(ClaudeModelPresentation.platformModel("opaque-model", availableModels: [model("opaque-model", platform: nil)]), "opaque-model", "协议兜底 openai 不等于目录明确报告的平台")
        XCTAssertEqual(ClaudeModelPresentation.platformModel("shared-model", availableModels: [model("shared-model", platform: "google"), model("shared-model", platform: "codex")], hints: ["shared-model": "google"]), "shared-model")
    }
    func testSavedPlatformHintsMustMatchTheSameModel() {
        XCTAssertEqual(ClaudeModelPresentation.platformHint(model: "glm-5.3[1m]", description: "zhipu/glm-5.3"), "zhipu")
        XCTAssertNil(ClaudeModelPresentation.platformHint(model: "glm-5.3", description: "zhipu/glm-5.2"))
        XCTAssertNil(ClaudeModelPresentation.platformHint(model: "glm-5.3", description: "自定义说明"))
        XCTAssertEqual(ClaudeModelPresentation.platformModel("glm-5.3[1m]", hints: ["glm-5.3": "zhipu"]), "zhipu/glm-5.3[1m]")
    }
    func testMagpieModelLabelAndAccountMoveToSeparateColumns() throws {
        let original = ClaudeModelPickerOption(model: "codex/gpt-6.1-sol", label: "GPT-6.1-Sol · Codex",
            description: "work@example.com · via magpie", extraFields: ["behavesAs": .string("capability")])
        let formatted = try XCTUnwrap(ClaudeModelPresentation.magpieOption(original))
        XCTAssertEqual(formatted.label, "GPT-6.1-Sol")
        XCTAssertEqual(formatted.description, "Codex · work@example.com")
        XCTAssertEqual(formatted.id, original.id)
        XCTAssertEqual(formatted.model, original.model)
        XCTAssertEqual(formatted.extraFields, original.extraFields)
        XCTAssertNil(ClaudeModelPresentation.magpieOption(formatted), "已经格式化的条目不再重复追加平台")
    }
    func testMagpieNoAccountAndCustomNamesAreNotInventedOrDiscarded() throws {
        let noAccount = ClaudeModelPickerOption(model: "zhipu/glm-5.3[1M]", label: "GLM-5.3 · Zhipu GLM", description: "via magpie")
        let formatted = try XCTUnwrap(ClaudeModelPresentation.magpieOption(noAccount))
        XCTAssertEqual(formatted.label, "GLM-5.3[1m]")
        XCTAssertEqual(formatted.description, "智谱")
        let named = ClaudeModelPickerOption(model: "codex/gpt-6-astra", label: "我的推理模型 · Codex", description: "Codex · 工作账号 · via magpie")
        XCTAssertEqual(ClaudeModelPresentation.magpieOption(named)?.label, "我的推理模型")
        XCTAssertEqual(ClaudeModelPresentation.magpieOption(named)?.description, "Codex · 工作账号")
        XCTAssertNil(ClaudeModelPresentation.magpieOption(ClaudeModelPickerOption(model: "codex/model", label: "保留标题", description: "用户独立说明")))
    }
    func testMagpieRoutingGroupsDoNotPretendToBeAnAccount() throws {
        let group = ClaudeModelPickerOption(model: "group/mix", label: "Mix · routing group", description: "routing group · via magpie")
        let formatted = try XCTUnwrap(ClaudeModelPresentation.magpieOption(group))
        XCTAssertEqual(formatted.label, "Mix")
        XCTAssertEqual(formatted.description, "路由组")
    }
    func testMagpieMenuMergeKeepsOrderDuplicatesFlagsAndUnknownFields() async throws {
        let menu: [String: Any] = ["replaceBuiltInOptions": false, "future": ["keep": true], "options": [
            ["model": "codex/gpt-6.1-sol", "label": "GPT-6.1-Sol · Codex", "description": "work@example.com · via magpie", "futureID": Int64.max],
            ["model": "codex/gpt-6.1-sol", "label": "另一账号 · Codex", "description": "other@example.com · via magpie"],
            ["model": "custom/model", "label": "独立标题", "description": "独立说明", "behavesAs": "capability"]]]
        try write(["modelPicker": menu, "permissions": ["allow": ["Read"]]])
        let config = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:9/v1", apiKey: "fake-key")
        _ = try await save(config)
        let settings = try read()
        let output = try XCTUnwrap(settings["modelPicker"] as? [String: Any])
        let rows = try XCTUnwrap(output["options"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.compactMap { $0["model"] as? String }, ["codex/gpt-6.1-sol", "codex/gpt-6.1-sol", "custom/model"])
        XCTAssertEqual(rows[0]["label"] as? String, "GPT-6.1-Sol")
        XCTAssertEqual(rows[1]["description"] as? String, "Codex · other@example.com")
        XCTAssertEqual((rows[0]["futureID"] as? NSNumber)?.int64Value, Int64.max)
        XCTAssertEqual(rows[2] as NSDictionary, (menu["options"] as! [[String: Any]])[2] as NSDictionary)
        XCTAssertNil(output["quotioManaged"])
        XCTAssertEqual(output["future"] as? [String: Bool], ["keep": true])
        XCTAssertEqual(settings["permissions"] as? [String: [String]], ["allow": ["Read"]])
        // 磁盘保留不够，表单预览也必须呈现同模型的两个账号，不能只显示第一个账号。
        let loaded = await service.readConfiguration(agent: .claudeCode)
        var preview = config
        preview.claudeModelPicker = try XCTUnwrap(loaded).claudeModelPicker
        XCTAssertFalse(preview.claudeModelPicker.shouldWrite)
        XCTAssertEqual(preview.claudeEffectivePickerOptions.count, 3)
        XCTAssertEqual(preview.claudeEffectivePickerOptions.prefix(2).map { preview.claudePickerDescription(for: $0) },
            ["Codex · work@example.com", "Codex · other@example.com"])
        let first = output as NSDictionary
        _ = try await save(config)
        XCTAssertEqual(try XCTUnwrap(read()["modelPicker"] as? NSDictionary), first, "重复应用必须幂等")
    }
    func testUnknownMenuStructureIsPreservedWhole() {
        let menu: [String: Any] = ["future": 42, "options": [["futureModel": "unknown"], ["model": "codex/gpt-6-sol", "description": "via magpie"]]]
        XCTAssertEqual(ClaudeModelPresentation.formattedMagpieMenu(menu) as? NSDictionary, menu as NSDictionary)
    }
    func testFableRoundTripsDefaultContextSubagentNamesAndPlatformDescriptions() async throws {
        var config = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:9/v1", apiKey: "fake-key")
        config.modelSlots = [.opus: "glm-5.3", .fable: "codex/gpt-6-astra", .sonnet: "gemini-3.8-flash-high", .haiku: "fast/model"]
        config.claudeModel1M = [.opus: true, .fable: true]
        config.claudeModel = "fable"
        config.claudeSubagentModel = "fable"
        let result = try await save(config, models: [model("glm-5.3", platform: "zhipu"), model("gemini-3.8-flash-high", platform: "google")])
        let env = try XCTUnwrap(read()["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "glm-5.3[1m]", "说明补平台不改请求 ID")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION"], "zhipu/glm-5.3[1m]")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_FABLE_MODEL"], "codex/gpt-6-astra[1m]")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"], "Fable")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION"], "google/gemini-3.8-flash-high")
        XCTAssertEqual(env["CLAUDE_CODE_SUBAGENT_MODEL"], "fable")
        XCTAssertTrue(result.shellConfig?.contains("ANTHROPIC_DEFAULT_FABLE_MODEL") == true)
        XCTAssertNil(try read()["modelPicker"])
        let loaded = await service.readConfiguration(agent: .claudeCode)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.modelSlots[.fable], "codex/gpt-6-astra")
        XCTAssertEqual(saved.defaultModel, "fable")
        XCTAssertEqual(saved.claudeModel1M[.fable], true)
        config.claudeModelPlatformHints = saved.modelPlatformHints
        _ = try await save(config)
        XCTAssertEqual((try read()["env"] as? [String: String])?["ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION"], "google/gemini-3.8-flash-high")
        config.setupMode = .defaultSetup
        _ = try await save(config)
        XCTAssertNil((try read()["env"] as? [String: String])?["ANTHROPIC_DEFAULT_FABLE_MODEL"])
    }
    func testLegacyConfigAndOtherAgentsDoNotAcquireAnUnselectedFableTarget() async throws {
        let config = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:9/v1", apiKey: "fake-key")
        XCTAssertFalse(config.configuredClaudeSlots.contains(.fable))
        _ = try await save(config)
        XCTAssertNil((try read()["env"] as? [String: String])?["ANTHROPIC_DEFAULT_FABLE_MODEL"])
        for agent in [CLIAgent.ampCLI, .openCode, .factoryDroid, .codexCLI, .pi] {
            XCTAssertNil(AgentConfiguration(agent: agent, proxyURL: "http://127.0.0.1:9/v1", apiKey: "fake-key").modelSlots[.fable])
        }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        json.removeValue(forKey: "claudeModelPlatformHints")
        let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.claudeModelPlatformHints.isEmpty)
        XCTAssertFalse(decoded.configuredClaudeSlots.contains(.fable))
    }
    func testUnmappedFableDefaultAndSubagentKeepTheNativeRoleInsteadOfAnInventedTarget() async throws {
        // 默认和子代理可以引用 Fable，但没有槽映射时不能宣称某个具体官方版本已被固定。
        var config = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:9/v1", apiKey: "fake-key")
        config.claudeModel = "fable"
        config.claudeSubagentModel = "fable"
        XCTAssertEqual(config.claudeRequestModel(for: .fable), "fable")
        XCTAssertEqual(config.claudeDefaultRequestModel, "fable")
        XCTAssertEqual(config.claudeResolvedSelector("fable"), "fable")
        XCTAssertEqual(config.claudeResolvedSelector("fable[1m]"), "fable[1m]")
        _ = try await save(config)
        let settings = try read()
        let env = try XCTUnwrap(settings["env"] as? [String: String])
        XCTAssertEqual(settings["model"] as? String, "fable")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_MODEL"], "fable")
        XCTAssertEqual(env["CLAUDE_CODE_SUBAGENT_MODEL"], "fable")
        XCTAssertNil(env["ANTHROPIC_DEFAULT_FABLE_MODEL"])
    }
    @MainActor
    func testRestoreLegacyThreeSlotBackupClearsFableBeforeSavingAgain() async throws {
        // 覆盖真实恢复入口：磁盘恢复成功后，同一份表单不得继续携带恢复前的可选槽目标。
        var current = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:9/v1", apiKey: "fake-key")
        current.modelSlots[.fable] = "codex/gpt-6-astra"
        current.claudeModel1M[.fable] = true
        _ = try await save(current)
        let backupURL = settingsURL.appendingPathExtension("backup.100")
        let legacy: [String: Any] = ["model": "sonnet", "env": [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:9", "ANTHROPIC_AUTH_TOKEN": "fake-key",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "zhipu/glm-5.3",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "google/gemini-3.8-flash-high",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "codex/gpt-6-luna"
        ]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: backupURL)
        let vm = AgentSetupViewModel(configurationService: service)
        vm.selectedAgent = .claudeCode
        vm.currentConfiguration = current
        await vm.restoreFromBackup(.init(path: backupURL.path, timestamp: Date(timeIntervalSince1970: 100), agent: .claudeCode))
        XCTAssertNil(vm.errorMessage)
        let restored = try XCTUnwrap(vm.currentConfiguration)
        XCTAssertNil(restored.modelSlots[.fable])
        XCTAssertFalse(restored.usesClaude1MContext(for: .fable))
        XCTAssertEqual(restored.claudeModel, "sonnet")
        XCTAssertEqual(restored.modelSlots[.opus], "zhipu/glm-5.3")
        _ = try await save(restored)
        let env = try XCTUnwrap(read()["env"] as? [String: String])
        XCTAssertNil(env["ANTHROPIC_DEFAULT_FABLE_MODEL"])
        XCTAssertNil(env["ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"])
        XCTAssertNil(env["ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION"])
    }
    @MainActor
    func testFableVersionGateDoesNotBlockOldThreeSlotConfigurations() {
        let vm = AgentSetupViewModel(configurationService: service)
        vm.selectedAgent = .claudeCode
        vm.currentConfiguration = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:9/v1", apiKey: "fake-key")
        vm.agentStatuses = [AgentStatus(agent: .claudeCode, installed: true, configured: true, version: "2.1.236")]
        XCTAssertNil(vm.claudeConfigurationValidationMessage)
        vm.updateModelSlot(.fable, model: "zhipu/glm-5.3[1m]")
        XCTAssertNotNil(vm.claudeConfigurationValidationMessage)
        vm.agentStatuses = [AgentStatus(agent: .claudeCode, installed: true, configured: true, version: "2.1.287")]
        XCTAssertNil(vm.claudeConfigurationValidationMessage)
    }
    func testMissingCatalogOwnerDoesNotBecomeAnOpenAIPlatformClaim() throws {
        let entry = ModelCatalogEntry(id: "opaque-model", owner: nil)
        let models = ModelCatalog.agentSetupModels(from: [entry])
        XCTAssertEqual(models.first?.provider, "openai", "原选择器协议兼容值保持")
        XCTAssertNil(models.first?.displayPlatform)
        XCTAssertEqual(ClaudeModelPresentation.platformModel("opaque-model", availableModels: models), "opaque-model")
        let old = Data(#"{"id":"old","name":"old","provider":"openai","isDefault":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AvailableModel.self, from: old).displayPlatform)
    }
}
