import XCTest
@testable import QuotioPlus

/// 子代理配置的定向回归：走生产读取／生成入口，全部数据位于独立临时目录。
/// 除行为等价判断外，重点覆盖保存前的最新磁盘校验及失败时不备份、不改文件的事务边界。
final class ClaudeSubagentConfigurationTests: XCTestCase {
    private var home: URL!
    private var service: AgentConfigurationService!
    private var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeSubagent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        service = AgentConfigurationService(homeDirectory: home)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    private func configuration() -> AgentConfiguration {
        var value = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:9/v1", apiKey: "fixture-only-key")
        value.modelSlots = [.opus: "fixture/main", .sonnet: "fixture/sonnet", .haiku: "fixture/haiku"]
        return value
    }
    private func write(_ value: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: settingsURL)
    }
    private func read() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    }
    private func generate(_ value: AgentConfiguration, storage: ConfigStorageOption = .jsonOnly,
                          mode: ConfigurationMode = .automatic) async throws -> AgentConfigResult {
        try await service.generateConfiguration(agent: .claudeCode, config: value, mode: mode,
            storageOption: storage, detectionService: AgentDetectionService())
    }

    func testShellOnlyReplacementRemovalAndManualOutputCannotIgnoreExistingJSON() async throws {
        for model in ["fixture/new", "inherit", nil] as [String?] {
            try write(["env": ["CLAUDE_CODE_SUBAGENT_MODEL": "fixture/old", "USER_SETTING": "keep"]])
            let before = try Data(contentsOf: settingsURL)
            let names = try FileManager.default.contentsOfDirectory(atPath: settingsURL.deletingLastPathComponent().path)
            var value = configuration()
            value.claudeSubagentModel = model
            let result = try await generate(value, storage: .shellOnly, mode: .automatic)
            XCTAssertFalse(result.success)
            XCTAssertNotNil(result.error)
            XCTAssertEqual(try Data(contentsOf: settingsURL), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: settingsURL.deletingLastPathComponent().path), names)
            // 手动模式始终给出 JSON；不能被前一个自动模式中已经隐藏的仅 Shell 选项阻断。
            let preview = try await generate(value, storage: .shellOnly, mode: .manual)
            XCTAssertTrue(preview.success, preview.error ?? "")
            let json = try XCTUnwrap(preview.rawConfigs.first { $0.format == .json })
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.content.utf8)) as? [String: Any])
            XCTAssertEqual((object["env"] as? [String: Any])?["CLAUDE_CODE_SUBAGENT_MODEL"] as? String, model)
            // 继续保留可复制的 Shell 原功能，但有 JSON 冲突时必须注明需要一同应用 JSON。
            // 对未声明值，脚本必须执行 unset；变量名出现不能被误当成仍在赋值旧模型。
            let shell = try XCTUnwrap(preview.rawConfigs.first { $0.format == .shellExport })
            XCTAssertEqual(shell.instructions, "agents.claudeSubagent.shellNeedsJSON".localizedStatic())
            let expected = model.map { "export CLAUDE_CODE_SUBAGENT_MODEL='\($0)'" }
                ?? "unset CLAUDE_CODE_SUBAGENT_MODEL"
            XCTAssertTrue(shell.content.components(separatedBy: .newlines).contains(expected))
            XCTAssertFalse(shell.content.contains("export CLAUDE_CODE_SUBAGENT_MODEL='fixture/old'"))
            XCTAssertEqual(try Data(contentsOf: settingsURL), before)
        }
        var replacement = configuration()
        replacement.claudeSubagentModel = "fixture/new"
        // 手动输出统一采用有效 JSON 方案，不让不可见的自动“双存储”选择改变预览语义。
        let beforePreview = try Data(contentsOf: settingsURL)
        let preview = try await generate(replacement, storage: .both, mode: .manual)
        XCTAssertTrue(preview.success)
        XCTAssertTrue(preview.rawConfigs.contains { $0.format == .json })
        let shell = try XCTUnwrap(preview.rawConfigs.first { $0.format == .shellExport })
        XCTAssertEqual(shell.instructions, "agents.claudeSubagent.shellNeedsJSON".localizedStatic())
        XCTAssertTrue(shell.content.components(separatedBy: .newlines)
            .contains("export CLAUDE_CODE_SUBAGENT_MODEL='fixture/new'"))
        XCTAssertEqual(try Data(contentsOf: settingsURL), beforePreview)
        let result = try await generate(replacement)
        XCTAssertTrue(result.success)
        XCTAssertEqual((try read()["env"] as? [String: String])?["CLAUDE_CODE_SUBAGENT_MODEL"], "fixture/new")
    }

    func testOnlyExistingJSONConflictsBlockShellAndSameValuesRemainAllowed() async throws {
        var value = configuration()
        value.claudeSubagentModel = "fixture/new"
        value.claudeSubagentModelForce = "1"
        // 没有 JSON 声明、或者 JSON 与目标相同时，原“仅 Shell”能力仍正常生成。
        for env in [[:], ["CLAUDE_CODE_SUBAGENT_MODEL": "fixture/new", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1"]] {
            try write(["env": env])
            let before = try Data(contentsOf: settingsURL)
            let result = try await generate(value, storage: .shellOnly)
            XCTAssertTrue(result.success, result.error ?? "")
            XCTAssertEqual(try Data(contentsOf: settingsURL), before)
            XCTAssertTrue(result.shellConfig?.contains("export CLAUDE_CODE_SUBAGENT_MODEL='fixture/new'") == true)
        }
    }

    @MainActor
    func testServiceRechecksDiskAfterPageBaselineWasRead() async throws {
        try write(["env": ["USER_SETTING": "keep"]])
        let viewModel = AgentSetupViewModel(configurationService: service)
        viewModel.selectedAgent = .claudeCode
        viewModel.currentConfiguration = configuration()
        viewModel.updateClaudeSubagentModel("fixture/new")
        viewModel.savedConfig = await service.readConfiguration(agent: .claudeCode)
        viewModel.configStorageOption = .shellOnly
        XCTAssertNil(viewModel.claudeConfigurationValidationMessage)
        // 模拟外部工具在页面打开后写入旧固定值；即使页面基线允许，生成层也必须拒绝。
        try write(["env": ["CLAUDE_CODE_SUBAGENT_MODEL": "fixture/external"]])
        let before = try Data(contentsOf: settingsURL)
        let result = try await generate(try XCTUnwrap(viewModel.currentConfiguration), storage: .shellOnly)
        XCTAssertFalse(result.success)
        XCTAssertEqual(try Data(contentsOf: settingsURL), before)
    }

    func testUnchangedRoleSelectorStillRequiresJSONWhenItsMappingChanges() async throws {
        try write(["env": ["CLAUDE_CODE_SUBAGENT_MODEL": "sonnet", "ANTHROPIC_DEFAULT_SONNET_MODEL": "fixture/old"]])
        var value = configuration()
        value.claudeSubagentModel = "sonnet"
        let denied = try await generate(value, storage: .shellOnly)
        XCTAssertFalse(denied.success)
        value.modelSlots[.sonnet] = "fixture/old"
        let allowed = try await generate(value, storage: .shellOnly)
        XCTAssertTrue(allowed.success, allowed.error ?? "")
    }

    func testForceConflictIsCheckedForBothDirectionsAndDisabledRawValuesRemainCompatible() async throws {
        for (old, new) in [("1", ""), ("", "1"), ("0", "1")] {
            try write(["env": ["CLAUDE_CODE_SUBAGENT_MODEL_FORCE": old]])
            var value = configuration()
            value.claudeSubagentModelForce = new
            let denied = try await generate(value, storage: .shellOnly)
            XCTAssertFalse(denied.success)
            let saved = try await generate(value, storage: .both)
            XCTAssertTrue(saved.success)
            XCTAssertEqual((try read()["env"] as? [String: String])?["CLAUDE_CODE_SUBAGENT_MODEL_FORCE"], new)
        }
    }

    func testInheritAndLegacyForceRoundTripPreserveRawValuesAndUnknownFields() async throws {
        for force in [nil, "", "1", "0", "false", " YES ", "On", "future-value"] as [String?] {
            var env: [String: Any] = ["CLAUDE_CODE_SUBAGENT_MODEL": "inherit", "USER_SETTING": ["future": true]]
            env["CLAUDE_CODE_SUBAGENT_MODEL_FORCE"] = force
            try write(["env": env, "hooks": ["futureHook": ["keep": true]]])
            let snapshot = await service.readConfiguration(agent: .claudeCode)
            let loaded = try XCTUnwrap(snapshot)
            var value = configuration()
            value.claudeSubagentModel = loaded.claudeSubagentModel
            value.claudeSubagentModelForce = loaded.claudeSubagentModelForce
            XCTAssertNil(value.claudeSubagentSelector)
            XCTAssertEqual(value.claudeSubagentSettings.isForced, force == "1" || force == " YES " || force == "On")
            let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: JSONEncoder().encode(value))
            XCTAssertNil(decoded.claudeSubagentSelector)
            XCTAssertEqual(decoded.claudeSubagentModelForce, force)
            let result = try await generate(decoded)
            XCTAssertTrue(result.success)
            let saved = try read()
            let savedEnv = try XCTUnwrap(saved["env"] as? [String: Any])
            XCTAssertEqual(savedEnv["CLAUDE_CODE_SUBAGENT_MODEL"] as? String, "inherit")
            XCTAssertEqual(savedEnv["CLAUDE_CODE_SUBAGENT_MODEL_FORCE"] as? String, force)
            XCTAssertEqual((savedEnv["USER_SETTING"] as? [String: Bool])?["future"], true)
            XCTAssertNotNil(saved["hooks"])
        }
    }

    @MainActor
    func testExplicitDefaultRulesClearBothOverridesWithoutChangingOtherDraftValues() async throws {
        let viewModel = AgentSetupViewModel(configurationService: service)
        var value = configuration()
        value.claudeSubagentModel = "fixture/child"
        value.claudeSubagentModelForce = "1"
        viewModel.currentConfiguration = value
        viewModel.updateClaudeSubagentMode(false)
        let updated = try XCTUnwrap(viewModel.currentConfiguration)
        XCTAssertNil(updated.claudeSubagentSelector)
        XCTAssertEqual(updated.claudeSubagentModel, "inherit")
        XCTAssertEqual(updated.claudeSubagentModelForce, "")
        XCTAssertEqual(updated.modelSlots, value.modelSlots)
        XCTAssertEqual(updated.apiKey, value.apiKey)
        let result = try await generate(updated)
        XCTAssertTrue(result.success)
        let env = try XCTUnwrap(try read()["env"] as? [String: String])
        XCTAssertEqual(env["CLAUDE_CODE_SUBAGENT_MODEL"], "inherit")
        XCTAssertEqual(env["CLAUDE_CODE_SUBAGENT_MODEL_FORCE"], "")
        viewModel.updateClaudeSubagentMode(true)
        viewModel.updateClaudeSubagentModel("fixture/explicit")
        viewModel.updateClaudeSubagentMode(true)
        XCTAssertEqual(viewModel.currentConfiguration?.claudeSubagentModel, "fixture/explicit")
    }

    /// 仅 FORCE 与 inherit + FORCE 都是合法历史配置；读入不改原串，用户明确恢复默认后才清覆盖。
    @MainActor
    func testDefaultRulesCanClearForceWithoutAnExplicitSubagentModel() throws {
        for model in [nil, "inherit"] as [String?] {
            let viewModel = AgentSetupViewModel(configurationService: service)
            var value = configuration()
            value.claudeSubagentModel = model
            value.claudeSubagentModelForce = " YES "
            viewModel.currentConfiguration = value
            XCTAssertNil(viewModel.currentConfiguration?.claudeSubagentSelector)
            XCTAssertEqual(viewModel.currentConfiguration?.claudeSubagentModelForce, " YES ")
            XCTAssertEqual(viewModel.currentConfiguration, value)
            viewModel.updateClaudeSubagentMode(false)
            XCTAssertNil(viewModel.currentConfiguration?.claudeSubagentSelector)
            XCTAssertEqual(viewModel.currentConfiguration?.claudeSubagentModel, "inherit")
            XCTAssertEqual(viewModel.currentConfiguration?.claudeSubagentModelForce, "")
            XCTAssertEqual(viewModel.currentConfiguration?.modelSlots, value.modelSlots)

            // 已关闭的未知旧串仍保持原值，重复点击当前模式不是规范化历史数据的机会。
            viewModel.currentConfiguration?.claudeSubagentModelForce = "future-off-value"
            viewModel.updateClaudeSubagentMode(false)
            XCTAssertEqual(viewModel.currentConfiguration?.claudeSubagentModelForce, "future-off-value")
        }
    }

    @MainActor
    func testForceVersionGuardDoesNotRejectExistingSettingsOrOffState() async throws {
        let viewModel = AgentSetupViewModel(configurationService: service)
        viewModel.selectedAgent = .claudeCode
        viewModel.currentConfiguration = configuration()
        viewModel.agentStatuses = [AgentStatus(agent: .claudeCode, installed: true, configured: true, version: "2.1.256 (Claude Code)")]
        viewModel.updateClaudeSubagentForce(true)
        XCTAssertNotNil(viewModel.claudeConfigurationValidationMessage)
        try write(["env": ["CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1"]])
        viewModel.savedConfig = await service.readConfiguration(agent: .claudeCode)
        XCTAssertNil(viewModel.claudeConfigurationValidationMessage)
        viewModel.updateClaudeSubagentForce(false)
        XCTAssertNil(viewModel.claudeConfigurationValidationMessage)
        viewModel.savedConfig = nil
        viewModel.agentStatuses = [AgentStatus(agent: .claudeCode, installed: true, configured: true, version: "2.1.257 (Claude Code)")]
        viewModel.updateClaudeSubagentForce(true)
        XCTAssertNil(viewModel.claudeConfigurationValidationMessage)
    }

    func testLegacyDraftWithoutForceKeyAndNativeRestoreKeepCompatibility() async throws {
        var value = configuration()
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        encoded.removeValue(forKey: "claudeSubagentModelForce")
        let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertNil(decoded.claudeSubagentModelForce)
        XCTAssertFalse(decoded.claudeSubagentSettings.isForced)
        try write(["env": ["CLAUDE_CODE_SUBAGENT_MODEL": "fixture/old", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1", "USER_SETTING": "keep"]])
        value.setupMode = .defaultSetup
        let result = try await generate(value)
        XCTAssertTrue(result.success)
        let env = try XCTUnwrap(try read()["env"] as? [String: String])
        XCTAssertNil(env["CLAUDE_CODE_SUBAGENT_MODEL"])
        XCTAssertNil(env["CLAUDE_CODE_SUBAGENT_MODEL_FORCE"])
        XCTAssertEqual(env["USER_SETTING"], "keep")
    }

    /// 官方恢复由服务给出明确 Shell 动作，原 VM 必须执行；失败使用同一 JSON 回执恢复原字节。
    @MainActor
    func testOfficialRestoreConsumesShellRemovalAndRollsBackJSONOnProfileFailure() async throws {
        let keys = ["configured", "lastConfigured"].map { "agent.\(CLIAgent.claudeCode.rawValue)." + $0 }
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for shouldFail in [false, true] {
            try write(["env": ["ANTHROPIC_BASE_URL": "https://fixture.invalid", "ANTHROPIC_AUTH_TOKEN": "fixture-only-key",
                               "USER_SETTING": ["future": true]], "hooks": ["keep": true]])
            let originalJSON = try Data(contentsOf: settingsURL)
            let profile = home.appendingPathComponent("profile-\(shouldFail)")
            let originalProfile = """
            export USER_OUTSIDE_QUOTIO=keep
            # CLIProxyAPI Configuration for Claude Code
            export ANTHROPIC_BASE_URL='https://fixture.invalid'
            # End CLIProxyAPI Configuration for Claude Code
            export AFTER_QUOTIO=keep
            """
            try originalProfile.write(to: profile, atomically: true, encoding: .utf8)
            let shell = ShellProfileManager(profilePath: { _ in profile.path }, writeProfile: { text, path in
                if shouldFail { throw CocoaError(.fileWriteNoPermission) }
                try text.write(toFile: path, atomically: true, encoding: .utf8)
            })
            let viewModel = AgentSetupViewModel(configurationService: service, shellManager: shell,
                detectAgentStatuses: { _ in [] })
            viewModel.selectedAgent = .claudeCode
            var value = configuration()
            value.setupMode = .defaultSetup
            viewModel.currentConfiguration = value
            viewModel.selectedSetupMode = .defaultSetup
            viewModel.configStorageOption = .jsonOnly
            await viewModel.applyConfiguration(sessionID: viewModel.configurationSessionID)
            if shouldFail {
                XCTAssertNotNil(viewModel.errorMessage)
                XCTAssertEqual(try Data(contentsOf: settingsURL), originalJSON)
                XCTAssertEqual(try String(contentsOf: profile, encoding: .utf8), originalProfile)
            } else {
                XCTAssertTrue(viewModel.configResult?.success == true, viewModel.errorMessage ?? "未返回恢复结果")
                let restoredEnv = try XCTUnwrap(try read()["env"] as? [String: Any])
                XCTAssertNil(restoredEnv["ANTHROPIC_BASE_URL"])
                XCTAssertEqual((restoredEnv["USER_SETTING"] as? [String: Bool])?["future"], true)
                let restoredProfile = try String(contentsOf: profile, encoding: .utf8)
                XCTAssertFalse(restoredProfile.contains("ANTHROPIC_BASE_URL"))
                XCTAssertTrue(restoredProfile.contains("USER_OUTSIDE_QUOTIO=keep"))
                XCTAssertTrue(restoredProfile.contains("AFTER_QUOTIO=keep"))
            }
        }
    }
}
