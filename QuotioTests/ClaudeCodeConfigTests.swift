import XCTest
@testable import Quotio

final class ClaudeCodeConfigTests: XCTestCase {
    /// 每个测试通过临时用户目录执行完整配置流程，不读取或修改真实 Claude Code 的凭据。
    private var homeDirectory: URL!
    private var service: AgentConfigurationService!

    override func setUpWithError() throws {
        homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        service = AgentConfigurationService(homeDirectory: homeDirectory)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: homeDirectory)
    }

    private var settingsURL: URL {
        homeDirectory.appendingPathComponent(".claude/settings.json")
    }

    private func configuration() -> AgentConfiguration {
        var config = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:8317/v1", apiKey: "test-key")
        config.modelSlots = [.opus: "provider/reasoning-model", .sonnet: "provider/coding-model", .haiku: "provider/fast-model"]
        return config
    }

    private func generate(_ config: AgentConfiguration, mode: ConfigurationMode = .automatic,
                          storageOption: ConfigStorageOption = .jsonOnly) async throws -> AgentConfigResult {
        let result = try await service.generateConfiguration(
            agent: .claudeCode, config: config, mode: mode,
            storageOption: storageOption, detectionService: AgentDetectionService()
        )
        XCTAssertTrue(result.success, result.error ?? "配置生成失败")
        return result
    }

    private func readSettings() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    }

    func testAutomaticConfigurationWritesModelMappingsAndPickerDescriptions() async throws {
        let config = configuration()
        _ = try await generate(config)
        let settings = try readSettings()
        let env = try XCTUnwrap(settings["env"] as? [String: String])
        for slot in ModelSlot.allCases {
            let key = "ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL"
            // /model 补全读取说明，选择器读取名称；两者必须与实际请求用的 ID 一致。
            XCTAssertEqual(env[key], config.modelSlots[slot])
            XCTAssertEqual(env[key + "_NAME"], config.modelSlots[slot])
            XCTAssertEqual(env[key + "_DESCRIPTION"], config.modelSlots[slot])
        }
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "opus")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "http://127.0.0.1:8317")
        let saved = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(saved?.modelSlots, config.modelSlots)
    }

    func testReconfigurationRefreshesDescriptionsPreservesUserSettingsAndDistinctBackups() async throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original: [String: Any] = [
            "permissions": ["allow": ["Read"]],
            "env": ["USER_SETTING": "keep", "ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION": "old model"]
        ]
        let originalData = try JSONSerialization.data(withJSONObject: original)
        try originalData.write(to: settingsURL)
        let first = try await generate(configuration())
        var changed = configuration()
        changed.modelSlots[.opus] = "provider/new-model"
        let previousData = try Data(contentsOf: settingsURL)
        let second = try await generate(changed)
        let settings = try readSettings()
        let env = try XCTUnwrap(settings["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION"], "provider/new-model")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"], "provider/new-model")
        XCTAssertEqual(env["USER_SETTING"], "keep")
        XCTAssertEqual(settings["permissions"] as? [String: [String]], ["allow": ["Read"]])
        let firstBackup = try XCTUnwrap(first.backupPath)
        let secondBackup = try XCTUnwrap(second.backupPath)
        XCTAssertNotEqual(firstBackup, secondBackup)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: firstBackup)), originalData)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: secondBackup)), previousData)
    }

    func testEmptyAndMissingSlotsUseSameDefaultsAsConfigurationForm() async throws {
        var config = configuration()
        config.modelSlots = [.opus: "  ", .sonnet: ""]
        _ = try await generate(config)
        let env = try XCTUnwrap(readSettings()["env"] as? [String: String])
        for slot in ModelSlot.allCases {
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL"], AvailableModel.defaultModels[slot]?.name)
        }
    }

    func testShellExportsRoundTripSameModelFieldsWithoutShellExpansion() async throws {
        var config = configuration()
        // 这些字符必须作为模型 ID 原样写入，不能被 Shell 展开或作为命令执行。
        config.modelSlots[.opus] = "provider/model'$UNSET_VALUE`literal`"
        let result = try await generate(config, mode: .manual, storageOption: .shellOnly)
        let json = try XCTUnwrap(result.rawConfigs.first { $0.format == .json }?.content.data(using: .utf8))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let expected = try XCTUnwrap(settings["env"] as? [String: String])
        let script = try XCTUnwrap(result.shellConfig)
        for shell in ["/bin/zsh", "/bin/bash"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.environment = [:]
            process.arguments = ["-c", script + "\n/usr/bin/env"]
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let lines = Set(String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init))
            for (key, value) in expected {
                XCTAssertTrue(lines.contains("\(key)=\(value)"), "Shell 未原样保留字段：\(key)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }

    func testRestoringDefaultRemovesMappingDisplayMetadataAndKeepsUserKeys() async throws {
        _ = try await generate(configuration())
        var settings = try readSettings()
        var env = try XCTUnwrap(settings["env"] as? [String: String])
        env["USER_SETTING"] = "keep"
        settings["env"] = env
        // 用户显式设置的官方模型由用户管理，恢复代理配置时不应误删。
        settings["model"] = "claude-sonnet-4-6"
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
        var config = configuration()
        config.setupMode = .defaultSetup
        _ = try await generate(config)
        let restored = try readSettings()
        XCTAssertEqual(restored["env"] as? [String: String], ["USER_SETTING": "keep"])
        XCTAssertEqual(restored["model"] as? String, "claude-sonnet-4-6")
    }

    func testManualResetIncludesDisplayMetadataInRemovalInstructions() async throws {
        var config = configuration()
        config.setupMode = .defaultSetup
        let result = try await generate(config, mode: .manual)
        for slot in ModelSlot.allCases {
            let key = "ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL"
            XCTAssertTrue(result.instructions.contains(key + "_NAME"))
            XCTAssertTrue(result.instructions.contains(key + "_DESCRIPTION"))
        }
    }
    func testDefaultModelIsIndependentOfSlotMappingsAndRoundTrips() async throws {
        var config = configuration()
        config.claudeModel = "sonnet"
        _ = try await generate(config)
        let settings = try readSettings()
        let env = try XCTUnwrap(settings["env"] as? [String: String])
        XCTAssertEqual(settings["model"] as? String, "sonnet")
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "sonnet")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], config.modelSlots[.opus])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL"], config.modelSlots[.sonnet])
        let saved = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(saved?.defaultModel, "sonnet")
    }

    func testCustomDefaultIsWrittenToBothJSONAndShell() async throws {
        var config = configuration()
        config.claudeModel = "custom/start-model"
        let result = try await generate(config, storageOption: .both)
        let settings = try readSettings()
        let env = try XCTUnwrap(settings["env"] as? [String: String])
        XCTAssertEqual(settings["model"] as? String, "custom/start-model")
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "custom/start-model")
        XCTAssertTrue(result.shellConfig?.contains("export ANTHROPIC_MODEL='custom/start-model'") == true)
    }

    func testReadDefaultHonorsEnvironmentBeforeLegacyTopLevelModel() async throws {
        _ = try await generate(configuration())
        var settings = try readSettings()
        settings["model"] = "legacy/model"
        settings["env"] = ["ANTHROPIC_MODEL": "haiku"]
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
        let withEnvironment = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(withEnvironment?.defaultModel, "haiku")
        settings["env"] = [:] as [String: String]
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
        let legacy = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(legacy?.defaultModel, "legacy/model")
    }

    func testResetRemovesManagedDefaultForAliasesAndArbitraryModelIDs() async throws {
        for model in ["haiku", "custom/start-model"] {
            var config = configuration()
            config.claudeModel = model
            _ = try await generate(config)
            config.setupMode = .defaultSetup
            _ = try await generate(config)
            let settings = try readSettings()
            XCTAssertNil(settings["model"])
            XCTAssertNil(settings["env"])
        }
    }

    func testOldEncodedConfigurationDefaultsToOpusSlot() throws {
        let data = try JSONEncoder().encode(configuration())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "claudeDefaultModel")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: oldData)
        XCTAssertEqual(decoded.claudeModel, "opus")
    }

    func testCustomDisplayNamesRoundTripWithoutChangingRequestModels() async throws {
        var config = configuration()
        config.claudeModelDisplayNames = [.opus: "主力推理", .sonnet: "日常编码"]
        let result = try await generate(config, storageOption: .both)
        let env = try XCTUnwrap(readSettings()["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "provider/reasoning-model")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"], "主力推理")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION"], "主力推理 · provider/reasoning-model")
        XCTAssertTrue(result.shellConfig?.contains("export ANTHROPIC_DEFAULT_SONNET_MODEL_NAME='日常编码'") == true)
        let saved = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(saved?.modelDisplayNames[.opus], "主力推理")
        XCTAssertEqual(saved?.modelSlots, config.modelSlots)
    }

    func testEmptyDisplayNameFallsBackToActualModelAndOldDataDecodes() throws {
        var config = configuration()
        config.claudeModelDisplayNames = [.opus: "  "]
        XCTAssertEqual(config.claudeDisplayName(for: .opus), "provider/reasoning-model")
        let data = try JSONEncoder().encode(config)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "claudeModelDisplayNames")
        let restored = try JSONDecoder().decode(AgentConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.claudeDisplayName(for: .sonnet), "provider/coding-model")
    }

    @MainActor
    func testChangingModelPreservesCustomNameButUpdatesAutomaticName() {
        let viewModel = AgentSetupViewModel()
        viewModel.currentConfiguration = configuration()
        viewModel.updateModelDisplayName(.opus, name: "主力模型")
        viewModel.updateModelSlot(.opus, model: "new/request-model")
        XCTAssertEqual(viewModel.currentConfiguration?.claudeDisplayName(for: .opus), "主力模型")
        viewModel.updateModelDisplayName(.sonnet, name: "provider/coding-model")
        viewModel.updateModelSlot(.sonnet, model: "new/coding-model")
        XCTAssertEqual(viewModel.currentConfiguration?.claudeDisplayName(for: .sonnet), "new/coding-model")
    }

    func testAdvancedSettingsWriteToJSONAndShell() async throws {
        var config = configuration()
        config.claudeMaxContextTokens = 275_000
        config.claudeAutoCompactPercentage = 72
        config.claudeDisableAutoCompact = true

        let result = try await generate(config, storageOption: .both)
        let env = try XCTUnwrap(readSettings()["env"] as? [String: String])
        XCTAssertEqual(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "275000")
        XCTAssertEqual(env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"], "72")
        XCTAssertEqual(env["DISABLE_AUTO_COMPACT"], "1")
        XCTAssertEqual(env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"], "1")
        XCTAssertEqual(env["CLAUDE_CODE_SUBAGENT_MODEL"], config.modelSlots[.haiku])

        let shell = try XCTUnwrap(result.shellConfig)
        XCTAssertTrue(shell.contains("export CLAUDE_CODE_MAX_CONTEXT_TOKENS='275000'"))
        XCTAssertTrue(shell.contains("export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE='72'"))
        XCTAssertTrue(shell.contains("export DISABLE_AUTO_COMPACT='1'"))
    }

    func testOneMillionRolesUseIndependentSuffixesAndRestoreNormalContext() async throws {
        var config = configuration()
        config.claudeMaxContextTokens = 275_000
        config.claudeModel1M = [.opus: true, .haiku: true]
        config.claudeModel = "provider/reasoning-model"
        _ = try await generate(config)

        var env = try XCTUnwrap(readSettings()["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "provider/reasoning-model[1m]")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL"], "provider/coding-model")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "provider/fast-model[1m]")
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "provider/reasoning-model[1m]")
        XCTAssertEqual(env["CLAUDE_CODE_SUBAGENT_MODEL"], "provider/fast-model[1m]")
        XCTAssertEqual(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "1000000")

        let saved = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(saved?.modelSlots, config.modelSlots)
        XCTAssertEqual(saved?.claudeModel1M, [.opus: true, .haiku: true])
        XCTAssertEqual(saved?.claudeMaxContextTokens, 1_000_000)

        config.claudeModel1M = [:]
        _ = try await generate(config)
        env = try XCTUnwrap(readSettings()["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "provider/reasoning-model")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "provider/fast-model")
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "provider/reasoning-model")
        XCTAssertEqual(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "275000")
    }

    func testOneMillionSuffixIsNeverDuplicated() async throws {
        var config = configuration()
        config.modelSlots[.opus] = "provider/reasoning-model[1m]"
        config.claudeModel1M = [.opus: true]
        _ = try await generate(config)

        let env = try XCTUnwrap(readSettings()["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "provider/reasoning-model[1m]")
    }

    func testReadAdvancedSettingsFallsBackForInvalidValues() async throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let settings: [String: Any] = [
            "env": [
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "provider/reasoning-model[1m]",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "provider/coding-model",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL": "provider/fast-model[1m]",
                "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "0",
                "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "101",
                "DISABLE_AUTO_COMPACT": "true"
            ]
        ]
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)

        let savedConfig = await service.readConfiguration(agent: .claudeCode)
        let saved = try XCTUnwrap(savedConfig)
        XCTAssertEqual(saved.modelSlots[.opus], "provider/reasoning-model")
        XCTAssertEqual(saved.modelSlots[.haiku], "provider/fast-model")
        XCTAssertEqual(saved.claudeModel1M, [.opus: true, .haiku: true])
        XCTAssertEqual(saved.claudeMaxContextTokens, AgentConfiguration.defaultClaudeMaxContextTokens)
        XCTAssertEqual(saved.claudeAutoCompactPercentage, AgentConfiguration.defaultClaudeAutoCompactPercentage)
        XCTAssertFalse(saved.claudeDisableAutoCompact)
    }

    func testReenablingAutomaticCompactionRemovesStaleManagedValue() async throws {
        var config = configuration()
        config.claudeDisableAutoCompact = true
        _ = try await generate(config)
        config.claudeDisableAutoCompact = false
        _ = try await generate(config)

        let env = try XCTUnwrap(readSettings()["env"] as? [String: String])
        XCTAssertNil(env["DISABLE_AUTO_COMPACT"])
    }

    func testOldEncodedConfigurationUsesAdvancedDefaults() throws {
        let data = try JSONEncoder().encode(configuration())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "claudeMaxContextTokens")
        object.removeValue(forKey: "claudeAutoCompactPercentage")
        object.removeValue(forKey: "claudeDisableAutoCompact")
        object.removeValue(forKey: "claudeModel1M")

        let decoded = try JSONDecoder().decode(
            AgentConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.claudeMaxContextTokens, AgentConfiguration.defaultClaudeMaxContextTokens)
        XCTAssertEqual(decoded.claudeAutoCompactPercentage, AgentConfiguration.defaultClaudeAutoCompactPercentage)
        XCTAssertFalse(decoded.claudeDisableAutoCompact)
        XCTAssertTrue(decoded.claudeModel1M.isEmpty)
    }

}
