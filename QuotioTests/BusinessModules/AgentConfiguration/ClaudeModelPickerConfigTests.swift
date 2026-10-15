import XCTest
@testable import QuotioPlus

/// 验证真实文件读写和迁移，所有文件都位于每个测试独立的临时用户目录。
/// 不读取本机登录态，不向上游发送推理请求，也不改写用户的 Shell 配置。
final class ClaudeModelPickerConfigTests: XCTestCase {
    private var home: URL!
    private var service: AgentConfigurationService!
    private var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudePicker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        service = AgentConfigurationService(homeDirectory: home)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    private func configuration() -> AgentConfiguration {
        var config = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:8317/v1", apiKey: "test-key")
        config.modelSlots = [.opus: "shared/model", .sonnet: "shared/model", .haiku: "fast/model"]
        // 本组既有用例继续验证旧菜单的生成/编辑能力；新配置默认行为使用独立用例验证。
        config.claudeModelPicker = .roleDefaults()
        return config
    }

    private func write(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
    }

    private func read() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    }

    @discardableResult
    private func save(_ config: AgentConfiguration) async throws -> AgentConfigResult {
        let result = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            storageOption: .both, detectionService: AgentDetectionService())
        XCTAssertTrue(result.success, result.error ?? "配置生成失败")
        return result
    }

    func testExplicitLegacyMenuKeepsRoleSelectorsAndDistinctNamesForSharedTarget() async throws {
        var config = configuration()
        config.claudeModelDisplayNames = [.opus: "深度推理", .sonnet: "日常编码"]
        config.claudeModel1M = [.opus: true]
        try await save(config)
        let settings = try read()
        let picker = try XCTUnwrap(settings["modelPicker"] as? [String: Any])
        let rows = try XCTUnwrap(picker["options"] as? [[String: Any]])
        XCTAssertEqual(picker["replaceBuiltInOptions"] as? Bool, true)
        XCTAssertEqual(rows.compactMap { $0["model"] as? String }, ["opus", "sonnet", "haiku"])
        XCTAssertEqual(rows.compactMap { $0["label"] as? String }, ["深度推理", "日常编码", "Haiku"])
        XCTAssertEqual(rows.compactMap { $0["description"] as? String }, ["shared/model[1m]", "shared/model", "fast/model"])
        XCTAssertNil(settings["availableModels"])
        XCTAssertNil((settings["env"] as? [String: String])?["CLAUDE_CODE_SUBAGENT_MODEL"])
    }

    func testOrderedOptionsDeduplicateCompleteSelectorsButKeepOneMillionVariant() async throws {
        var config = configuration()
        config.claudeModelPicker.options = [
            ClaudeModelPickerOption(model: "custom/model", label: "我的模型"),
            ClaudeModelPickerOption(model: "custom/model", label: "重复模型"),
            ClaudeModelPickerOption(model: "custom/model[1M]", label: "长上下文"),
            ClaudeModelPickerOption(model: "sonnet")
        ]
        try await save(config)
        let rows = try XCTUnwrap((read()["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["model"] as? String }, ["custom/model", "custom/model[1m]", "sonnet"])
        XCTAssertEqual(rows.first?["label"] as? String, "我的模型")
    }

    func testImportedMenuPreservesLabelsOrderCapabilitiesAndUnknownFields() async throws {
        let original: [String: Any] = ["replaceBuiltInOptions": false, "futureSetting": ["enabled": true], "options": [
            ["model": "other/model", "label": "用户名称", "description": "用户说明", "behavesAs": "claude-opus-4-8", "futureRow": [1, 2]],
            ["model": "opus", "label": "外部角色标题"]
        ]]
        try write(["modelPicker": original, "permissions": ["allow": ["Read"]], "model": "sonnet"])
        let loaded = await service.readConfiguration(agent: .claudeCode)
        let saved = try XCTUnwrap(loaded)
        var config = configuration()
        config.claudeModelPicker = saved.claudeModelPicker
        XCTAssertEqual(config.claudeModelPicker.mode, .append)
        XCTAssertFalse(config.claudeModelPicker.isQuotioManaged)
        // 明确编辑时才开启写入；普通页面回填不会自动修改用户菜单。
        config.claudeModelPicker.shouldWrite = true
        config.claudeModelPicker.options[0].label = "更新的用户名称"
        try await save(config)
        let picker = try XCTUnwrap(read()["modelPicker"] as? [String: Any])
        let rows = try XCTUnwrap(picker["options"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["model"] as? String }, ["other/model", "opus"])
        XCTAssertEqual(rows[0]["label"] as? String, "更新的用户名称")
        XCTAssertEqual(rows[0]["description"] as? String, "用户说明")
        XCTAssertEqual(rows[0]["behavesAs"] as? String, "claude-opus-4-8")
        XCTAssertEqual(rows[0]["futureRow"] as? [Int], [1, 2])
        XCTAssertEqual(picker["futureSetting"] as? [String: Bool], ["enabled": true])
        XCTAssertEqual((try read())["permissions"] as? [String: [String]], ["allow": ["Read"]])
        XCTAssertNil(picker["quotioManaged"])
    }

    func testUnsupportedExternalMenuRoundTripsWithoutDiscardingRows() async throws {
        let original: [String: Any] = ["options": [["futureModel": "unrecognized"], ["model": "valid/model"]], "future": 42]
        try write(["modelPicker": original])
        let loaded = await service.readConfiguration(agent: .claudeCode)
        var config = configuration()
        config.claudeModelPicker = try XCTUnwrap(loaded).claudeModelPicker
        XCTAssertEqual(config.claudeModelPicker.mode, .external)
        try await save(config)
        XCTAssertEqual(try XCTUnwrap(read()["modelPicker"] as? NSDictionary), original as NSDictionary)
    }

    func testInvalidReplaceFlagIsPreservedAsUnsupportedExternalConfiguration() async throws {
        let original: [String: Any] = ["options": [["model": "valid/model"]], "replaceBuiltInOptions": "future-mode"]
        var config = configuration()
        config.claudeModelPicker = .read(original)
        XCTAssertEqual(config.claudeModelPicker.mode, .external)
        try await save(config)
        XCTAssertEqual(try XCTUnwrap(read()["modelPicker"] as? NSDictionary), original as NSDictionary)
    }

    func testUnknownLargeIntegerFieldDoesNotLosePrecision() async throws {
        let original: [String: Any] = ["options": [["model": "valid/model", "futureID": Int64.max]]]
        var config = configuration()
        config.claudeModelPicker = .read(original)
        try await save(config)
        let rows = try XCTUnwrap((read()["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]])
        XCTAssertEqual((rows[0]["futureID"] as? NSNumber)?.int64Value, Int64.max)
    }

    func testManagedMenuRemainsUnchangedWhenRoleMappingIsReconfigured() async throws {
        var config = configuration()
        config.claudeModelDisplayNames = [.opus: "原名称"]
        try await save(config)
        let original = try XCTUnwrap(read()["modelPicker"] as? NSDictionary)
        let loaded = await service.readConfiguration(agent: .claudeCode)
        config.claudeModelPicker = try XCTUnwrap(loaded).claudeModelPicker
        XCTAssertFalse(config.claudeModelPicker.shouldWrite)
        XCTAssertEqual(config.claudeModelPicker.options[0].label, "原名称")
        XCTAssertEqual(config.claudeModelPicker.options[0].description, "shared/model")
        config.modelSlots[.opus] = "new/model"
        try await save(config)
        XCTAssertEqual(try XCTUnwrap(read()["modelPicker"] as? NSDictionary), original)
        XCTAssertEqual((try read()["env"] as? [String: String])?["ANTHROPIC_DEFAULT_OPUS_MODEL"], "new/model")
        XCTAssertEqual((try read()["env"] as? [String: String])?["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"], "原名称")
    }

    func testNewConfigurationUsesNativeMenuAndAutomaticNamesWithoutWritingPicker() async throws {
        var config = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:8317/v1", apiKey: "test-key")
        config.modelSlots = [.opus: "reasoning/model", .sonnet: "coding/model", .haiku: "fast/model"]
        XCTAssertEqual(config.claudeModelPicker.mode, .native)
        XCTAssertFalse(config.claudeModelPicker.shouldWrite)
        XCTAssertNil(config.claudeSubagentSelector)
        let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.claudeModelPicker.mode, .native)
        XCTAssertFalse(decoded.claudeModelPicker.shouldWrite)
        try await save(config)
        let settings = try read()
        XCTAssertNil(settings["modelPicker"])
        let env = try XCTUnwrap(settings["env"] as? [String: String])
        for slot in ModelSlot.legacyCases {
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL_NAME"], slot.rawValue.capitalized)
        }
    }

    @MainActor
    func testExistingMenusNamesAndSubagentSurviveEditingOnlyRoleModels() async throws {
        let menus: [[String: Any]] = [
            ["replaceBuiltInOptions": false, "future": ["keep": true], "options": [
                ["model": "custom/model", "label": "自定义标题", "description": "自定义说明", "behavesAs": "capability"],
                ["model": "sonnet", "label": "独立菜单名称"]]],
            ["quotioManaged": true, "replaceBuiltInOptions": true, "options": [
                ["model": "opus", "label": "旧受管标题", "description": "旧受管说明"]]],
            ["future": 42, "options": [["futureModel": "尚未支持的外部结构"]]]
        ]
        for menu in menus {
            try write(["modelPicker": menu, "model": "custom/default", "permissions": ["allow": ["Read"]],
                "env": ["ANTHROPIC_DEFAULT_OPUS_MODEL": "old/reasoning", "ANTHROPIC_DEFAULT_SONNET_MODEL": "old/coding",
                    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "old/fast", "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "工程推理",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "工程编码", "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "快捷任务",
                    "CLAUDE_CODE_SUBAGENT_MODEL": "custom/child[1m]", "USER_SETTING": "keep"]])
            let loaded = await service.readConfiguration(agent: .claudeCode)
            let saved = try XCTUnwrap(loaded)
            var config = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:8317/v1", apiKey: "test-key",
                savedModelSlots: saved.modelSlots)
            config.claudeModelPicker = saved.claudeModelPicker
            config.claudeModelDisplayNames = saved.modelDisplayNames
            config.claudeSubagentModel = saved.claudeSubagentModel
            config.claudeModel = saved.defaultModel ?? "opus"
            let viewModel = AgentSetupViewModel(configurationService: service)
            viewModel.selectedAgent = .claudeCode
            viewModel.currentConfiguration = config
            viewModel.savedConfig = saved
            viewModel.updateModelSlot(.sonnet, model: "updated/coding")
            viewModel.updateClaude1MContext(true, for: .sonnet)
            // 未改写的旧菜单不应让旧 CLI、Shell 导出或外部未知结构阻止模型槽配置。
            viewModel.agentStatuses = [AgentStatus(agent: .claudeCode, installed: true, configured: true, version: "2.1.236")]
            viewModel.configStorageOption = .shellOnly
            XCTAssertNil(viewModel.claudeConfigurationValidationMessage)
            let edited = try XCTUnwrap(viewModel.currentConfiguration)
            try await save(edited)
            let settings = try read()
            XCTAssertEqual(settings["modelPicker"] as? NSDictionary, menu as NSDictionary)
            let env = try XCTUnwrap(settings["env"] as? [String: String])
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL"], "updated/coding[1m]")
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"], "工程推理")
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"], "工程编码")
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"], "快捷任务")
            XCTAssertEqual(env["CLAUDE_CODE_SUBAGENT_MODEL"], "custom/child[1m]")
            XCTAssertEqual(env["USER_SETTING"], "keep")
            XCTAssertEqual(settings["model"] as? String, "custom/default")
            XCTAssertEqual(settings["permissions"] as? [String: [String]], ["allow": ["Read"]])
        }
    }

    @MainActor
    func testExplicitEditsOfReloadedMenuEnableWritingForLegacyCallers() async throws {
        // 直接经过“生成 -> 回填 -> 明确编辑 -> 保存”链路，不手动打开 shouldWrite，
        // 防止后台接口只改内存、实际 JSON 却继续沿用旧菜单的静默回归。
        for action in ["add", "update", "remove", "move"] {
            var config = configuration()
            try await save(config)
            let loaded = await service.readConfiguration(agent: .claudeCode)
            config.claudeModelPicker = try XCTUnwrap(loaded).claudeModelPicker
            XCTAssertFalse(config.claudeModelPicker.shouldWrite)
            let viewModel = AgentSetupViewModel(configurationService: service)
            viewModel.currentConfiguration = config
            switch action {
            case "add":
                viewModel.addClaudePickerOption()
                XCTAssertTrue(viewModel.currentConfiguration?.claudeModelPicker.shouldWrite == true)
                var added = try XCTUnwrap(viewModel.currentConfiguration?.claudeModelPicker.options.last)
                added.model = "explicit/custom"
                viewModel.updateClaudePickerOption(added)
            case "update":
                var option = try XCTUnwrap(viewModel.currentConfiguration?.claudeModelPicker.options.first)
                option.description = "明确修改后的说明"
                viewModel.updateClaudePickerOption(option)
            case "remove":
                viewModel.removeClaudePickerOption(config.claudeModelPicker.options[0].id)
            default:
                viewModel.moveClaudePickerOption(config.claudeModelPicker.options[0].id, by: 1)
            }
            let edited = try XCTUnwrap(viewModel.currentConfiguration)
            XCTAssertTrue(edited.claudeModelPicker.shouldWrite)
            try await save(edited)
            let rows = try XCTUnwrap((read()["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]])
            switch action {
            case "add": XCTAssertEqual(rows.last?["model"] as? String, "explicit/custom")
            case "update": XCTAssertEqual(rows.first?["description"] as? String, "明确修改后的说明")
            case "remove": XCTAssertEqual(rows.compactMap { $0["model"] as? String }, ["sonnet", "haiku"])
            default: XCTAssertEqual(rows.compactMap { $0["model"] as? String }, ["sonnet", "opus", "haiku"])
            }
        }
    }

    func testLegacyDraftKeepsFixedHaikuAndDoesNotTakeOverExistingMenu() async throws {
        var config = configuration()
        config.claudeModel1M = [.haiku: true]
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        legacy.removeValue(forKey: "claudeModelPicker")
        legacy.removeValue(forKey: "claudeSubagentModel")
        let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.claudeModelPicker.mode, .native)
        XCTAssertFalse(decoded.claudeModelPicker.shouldWrite)
        XCTAssertEqual(decoded.claudeSubagentSelector, "fast/model[1m]")
        let existing: [String: Any] = ["options": [["model": "user/model", "label": "保留我"]]]
        try write(["modelPicker": existing])
        try await save(decoded)
        XCTAssertEqual(try XCTUnwrap(read()["modelPicker"] as? NSDictionary), existing as NSDictionary)
    }

    func testNewDraftInheritingSessionSurvivesCodableRoundTrip() throws {
        let config = configuration()
        let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertNil(decoded.claudeSubagentSelector)
        XCTAssertEqual(decoded.claudeModelPicker, config.claudeModelPicker)
    }

    func testFixedSubagentReadAndInheritanceClearJSONAndShellOverride() async throws {
        try write(["env": ["CLAUDE_CODE_SUBAGENT_MODEL": "existing/child[1m]", "USER_SETTING": "keep"]])
        let loaded = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(loaded?.claudeSubagentModel, "existing/child[1m]")
        var config = configuration()
        config.claudeSubagentModel = loaded?.claudeSubagentModel
        try await save(config)
        XCTAssertEqual((try read()["env"] as? [String: String])?["CLAUDE_CODE_SUBAGENT_MODEL"], "existing/child[1m]")
        config.claudeSubagentModel = nil
        let result = try await save(config)
        XCTAssertNil((try read()["env"] as? [String: String])?["CLAUDE_CODE_SUBAGENT_MODEL"])
        XCTAssertEqual((try read()["env"] as? [String: String])?["USER_SETTING"], "keep")
        XCTAssertTrue(result.shellConfig?.contains("unset CLAUDE_CODE_SUBAGENT_MODEL") == true)
    }

    func testSubagentRoleReferenceAndCustomContextStayIndependent() async throws {
        var config = configuration()
        config.claudeSubagentModel = "sonnet"
        try await save(config)
        XCTAssertEqual((try read()["env"] as? [String: String])?["CLAUDE_CODE_SUBAGENT_MODEL"], "sonnet")
        XCTAssertEqual(config.claudeResolvedSelector("sonnet"), "shared/model")
        config.claudeSubagentModel = "child/model[1M]"
        config.claudeModel1M[.haiku] = true
        try await save(config)
        XCTAssertEqual((try read()["env"] as? [String: String])?["CLAUDE_CODE_SUBAGENT_MODEL"], "child/model[1m]")
    }

    func testRestoringNativeConnectionRemovesOnlyOwnedMenu() async throws {
        var config = configuration()
        try await save(config)
        config.setupMode = .defaultSetup
        try await save(config)
        XCTAssertNil(try read()["modelPicker"])
        let external: [String: Any] = ["options": [["model": "user/model", "label": "用户菜单"]]]
        try write(["modelPicker": external])
        try await save(config)
        XCTAssertEqual(try XCTUnwrap(read()["modelPicker"] as? NSDictionary), external as NSDictionary)
    }

    @MainActor
    func testFormReordersByIdentityAndSynchronizesRoleNames() throws {
        let viewModel = AgentSetupViewModel(configurationService: service)
        viewModel.selectedAgent = .claudeCode
        viewModel.currentConfiguration = configuration()
        let initial = try XCTUnwrap(viewModel.currentConfiguration?.claudeModelPicker.options)
        viewModel.moveClaudePickerOption(initial[0].id, by: 1)
        XCTAssertEqual(viewModel.currentConfiguration?.claudeModelPicker.options.map(\.id), [initial[1].id, initial[0].id, initial[2].id])
        var role = initial[0]
        role.label = "菜单里编辑的名称"
        viewModel.updateClaudePickerOption(role)
        XCTAssertEqual(viewModel.currentConfiguration?.claudeDisplayName(for: .opus), "菜单里编辑的名称")
        viewModel.updateModelDisplayName(.opus, name: "角色里编辑的名称")
        let updated = try XCTUnwrap(viewModel.currentConfiguration)
        XCTAssertEqual(updated.claudePickerLabel(for: updated.claudeModelPicker.options[1]), "角色里编辑的名称")
        viewModel.updateClaudePickerMode(.native)
        viewModel.updateClaudePickerMode(.curated)
        XCTAssertEqual(viewModel.currentConfiguration?.claudeModelPicker.options.map(\.id), [initial[1].id, initial[0].id, initial[2].id])
    }

    @MainActor
    func testValidationPreventsEmptyRowsShellOnlyAndUnsupportedCLI() {
        let viewModel = AgentSetupViewModel(configurationService: service)
        viewModel.selectedAgent = .claudeCode
        viewModel.currentConfiguration = configuration()
        XCTAssertNil(viewModel.claudeConfigurationValidationMessage)
        viewModel.configStorageOption = .shellOnly
        XCTAssertNotNil(viewModel.claudeConfigurationValidationMessage)
        viewModel.configStorageOption = .jsonOnly
        viewModel.agentStatuses = [AgentStatus(agent: .claudeCode, installed: true, configured: false, version: "2.1.236 (Claude Code)")]
        XCTAssertNotNil(viewModel.claudeConfigurationValidationMessage)
        viewModel.updateClaudePickerMode(.native)
        XCTAssertNil(viewModel.claudeConfigurationValidationMessage)
        viewModel.agentStatuses = []
        viewModel.updateClaudePickerMode(.curated)
        viewModel.addClaudePickerOption()
        XCTAssertNotNil(viewModel.claudeConfigurationValidationMessage)
    }

    @MainActor
    func testShellOnlyCannotRemoveExistingJSONMenuOrFixedSubagent() async throws {
        let viewModel = AgentSetupViewModel(configurationService: service)
        viewModel.selectedAgent = .claudeCode
        for hasMenu in [true, false] {
            var config = configuration()
            config.claudeSubagentModel = "existing/child"
            if !hasMenu { config.claudeModelPicker.mode = .native }
            try await save(config)
            let before = try Data(contentsOf: settingsURL)
            viewModel.currentConfiguration = config
            viewModel.savedConfig = await service.readConfiguration(agent: .claudeCode)
            viewModel.configStorageOption = .shellOnly
            viewModel.updateClaudePickerMode(.native)
            // 有菜单时保持子代理目标，单独验证菜单清理；无菜单时单独验证子代理继承。
            if !hasMenu { viewModel.updateClaudeSubagentModel(nil) }
            // 普通断言失败不会中止 XCTest；必须先抛错退出，保证未来校验回归也不会触碰真实 Shell。
            _ = try XCTUnwrap(viewModel.claudeConfigurationValidationMessage)
            // 提交必须在 Shell 或 JSON 写入前被阻止，旧文件和真实 Shell 都不会受到影响。
            await viewModel.applyConfiguration()
            XCTAssertNotNil(viewModel.errorMessage)
            XCTAssertEqual(try Data(contentsOf: settingsURL), before)
            viewModel.configStorageOption = .both
            XCTAssertNil(viewModel.claudeConfigurationValidationMessage)
        }
    }

    @MainActor
    func testRecreatingUnsupportedMenuThroughNativeModeAcquiresOwnership() async throws {
        let viewModel = AgentSetupViewModel(configurationService: service)
        viewModel.currentConfiguration = configuration()
        viewModel.currentConfiguration?.claudeModelPicker = .read(["options": [["futureModel": "unknown"]]])
        viewModel.updateClaudePickerMode(.native)
        viewModel.updateClaudePickerMode(.curated)
        let picker = try XCTUnwrap(viewModel.currentConfiguration?.claudeModelPicker)
        XCTAssertTrue(picker.isQuotioManaged)
        XCTAssertNil(picker.preservedExternalJSON)
        XCTAssertEqual(picker.options.map(\.model), ["opus", "sonnet", "haiku"])
        var config = try XCTUnwrap(viewModel.currentConfiguration)
        try await save(config)
        XCTAssertEqual((try read()["modelPicker"] as? [String: Any])?["quotioManaged"] as? Bool, true)
        config.setupMode = .defaultSetup
        try await save(config)
        XCTAssertNil(try read()["modelPicker"])
    }
}
