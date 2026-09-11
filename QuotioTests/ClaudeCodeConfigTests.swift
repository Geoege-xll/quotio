import XCTest
import SwiftUI
import AppKit
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
            // 补全使用角色，选择面板使用名称；自动名称保留角色，说明与实际请求 ID 一致。
            XCTAssertEqual(env[key], config.modelSlots[slot])
            XCTAssertEqual(env[key + "_NAME"], slot.rawValue.capitalized)
            XCTAssertEqual(env[key + "_DESCRIPTION"], config.modelSlots[slot])
        }
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_MODEL"], "opus")
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
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"], "Opus")
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
            process.environment = ["ANTHROPIC_MODEL": "old/forced-model"]
            process.arguments = ["-c", script + "\n/usr/bin/env"]
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let lines = Set(String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init))
            XCTAssertTrue(lines.contains("ANTHROPIC_MODEL=\(config.claudeModel)"), "仅 Shell 模式必须保留显式启动模型")
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
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_MODEL"], "sonnet")
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
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_MODEL"], "custom/start-model")
        XCTAssertTrue(result.shellConfig?.contains("export ANTHROPIC_DEFAULT_MODEL='custom/start-model'") == true)
    }

    /// 仅 Shell 模式不改 JSON，必须保留能覆盖已有顶层 model 的启动变量，尤其是 Haiku 角色。
    func testShellOnlyKeepsExplicitLaunchModelForHaikuAndCustomIDs() async throws {
        for model in ["haiku", "custom/start-model"] {
            var config = configuration()
            config.claudeModel = model
            let result = try await generate(config, storageOption: .shellOnly)
            XCTAssertTrue(result.shellConfig?.contains("export ANTHROPIC_MODEL='\(model)'") == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
        }
    }

    /// 手动模式和 JSON-only 的 Shell 预览可被单独复制，不能假设用户同时保存了 JSON。
    func testStandaloneShellAlternativesKeepExplicitModel() async throws {
        var config = configuration()
        config.claudeModel = "haiku"
        for storage in [ConfigStorageOption.jsonOnly, .shellOnly, .both] {
            let result = try await service.generateConfiguration(
                agent: .claudeCode, config: config, mode: .manual,
                storageOption: storage, detectionService: AgentDetectionService()
            )
            let shell = try XCTUnwrap(result.rawConfigs.first { $0.format == .shellExport }?.content)
            XCTAssertTrue(shell.contains("export ANTHROPIC_MODEL='haiku'"))
            XCTAssertFalse(shell.contains("unset ANTHROPIC_MODEL"))
        }
        let automatic = try await generate(config)
        let shell = try XCTUnwrap(automatic.rawConfigs.first { $0.format == .shellExport }?.content)
        XCTAssertTrue(shell.contains("export ANTHROPIC_MODEL='haiku'"))
    }

    /// 同时保存两种配置时，Shell 不再钉住模型；/model 后续保存的 JSON 选择应继续生效。
    func testCombinedStorageUnsetsInheritedForcedShellModel() async throws {
        let result = try await generate(configuration(), storageOption: .both)
        let script = try XCTUnwrap(result.shellConfig)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.environment = ["ANTHROPIC_MODEL": "old/forced-model"]
        process.arguments = ["-c", script + "\n/usr/bin/env"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n")
        XCTAssertFalse(lines.contains { $0.hasPrefix("ANTHROPIC_MODEL=") })
        XCTAssertTrue(lines.contains("ANTHROPIC_DEFAULT_MODEL=opus"))
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
        for model in ["haiku", "haiku[1m]", "opus[1m]", "custom/start-model"] {
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

    /// 恢复默认只清除仍受角色映射管理的选择，不能仅凭字符串属于 Claude 角色就扩大清理范围。
    func testResetPreservesNativeRoleWithoutManagedMapping() async throws {
        _ = try await generate(configuration())
        var settings = try readSettings()
        settings["model"] = "haiku"
        var env = try XCTUnwrap(settings["env"] as? [String: String])
        env.removeValue(forKey: "ANTHROPIC_DEFAULT_HAIKU_MODEL")
        settings["env"] = env
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
        var config = configuration()
        config.setupMode = .defaultSetup
        _ = try await generate(config)
        XCTAssertEqual(try readSettings()["model"] as? String, "haiku")
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

    /// 模拟用户在 /model 中选中 Sonnet 后，Claude Code 只更新顶层 model 的真实行为。
    /// 旧版遗留的 ANTHROPIC_MODEL 必须在重新配置时移除，否则重启后仍会回到旧模型。
    func testModelSelectionAfterSavingIsNotOverriddenByLegacyEnvironment() async throws {
        _ = try await generate(configuration())
        var settings = try readSettings()
        var env = try XCTUnwrap(settings["env"] as? [String: String])
        env["ANTHROPIC_MODEL"] = "legacy/forced-model"
        env["USER_SETTING"] = "keep"
        settings["env"] = env
        settings["availableModels"] = ["opus", "sonnet", "haiku"]
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)

        _ = try await generate(configuration())
        settings = try readSettings()
        env = try XCTUnwrap(settings["env"] as? [String: String])
        XCTAssertNil(env["ANTHROPIC_MODEL"])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_MODEL"], "opus")
        XCTAssertEqual(env["USER_SETTING"], "keep")
        XCTAssertEqual(settings["availableModels"] as? [String], ["opus", "sonnet", "haiku"])

        settings["model"] = "sonnet"
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
        let saved = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(saved?.defaultModel, "sonnet")

        // Shell 默认值没有顶层 model 时仍可回填，不把用户清除顶层选择视为配置丢失。
        settings.removeValue(forKey: "model")
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
        let fallback = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(fallback?.defaultModel, "opus")
    }

    /// 已有发现设置按原值回填；关闭再保存时必须覆盖旧版的 1，且不改变槽映射和名称。
    func testGatewayDiscoveryRoundTripsAndCanBeDisabledWithoutChangingMappings() async throws {
        var config = configuration()
        config.claudeModelDisplayNames = [.opus: "主力模型"]
        config.claudeGatewayModelDiscovery = true
        _ = try await generate(config)
        let enabled = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(enabled?.claudeGatewayModelDiscovery, true)

        config.claudeGatewayModelDiscovery = false
        let result = try await generate(config, storageOption: .both)
        let env = try XCTUnwrap(readSettings()["env"] as? [String: String])
        XCTAssertEqual(env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"], "0")
        XCTAssertTrue(result.shellConfig?.contains("export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY='0'") == true)
        let disabled = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(disabled?.claudeGatewayModelDiscovery, false)
        XCTAssertEqual(disabled?.modelSlots, config.modelSlots)
        XCTAssertEqual(disabled?.modelDisplayNames[.opus], "主力模型")
    }

    /// 预览必须与实际写入的说明完全一致，包括不同槽各自的 1M 后缀和自定义名称。
    func testDisplayPreviewMatchesGeneratedDescriptionsForCustomNamesAndOneMillion() async throws {
        var config = configuration()
        config.claudeModelDisplayNames = [.opus: "主力推理", .sonnet: "  "]
        config.claudeModel1M = [.opus: true, .haiku: true]
        _ = try await generate(config)
        let env = try XCTUnwrap(readSettings()["env"] as? [String: String])
        XCTAssertEqual(config.claudeModelDescription(for: .opus), "主力推理 · provider/reasoning-model[1m]")
        XCTAssertEqual(config.claudeModelDescription(for: .sonnet), "provider/coding-model")
        for slot in ModelSlot.allCases {
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL"], config.claudeRequestModel(for: slot))
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL_DESCRIPTION"], config.claudeModelDescription(for: slot))
        }
    }

    func testEmptyDisplayNameFallsBackToRoleAndOldDataDecodes() throws {
        var config = configuration()
        config.claudeModelDisplayNames = [.opus: "  "]
        XCTAssertEqual(config.claudeDisplayName(for: .opus), "Opus")
        let data = try JSONEncoder().encode(config)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "claudeModelDisplayNames")
        let restored = try JSONDecoder().decode(AgentConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.claudeDisplayName(for: .sonnet), "Sonnet")
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
        XCTAssertEqual(viewModel.currentConfiguration?.claudeDisplayName(for: .sonnet), "Sonnet")
        viewModel.updateModelDisplayName(.haiku, name: "provider/fast-model[1M]")
        viewModel.updateModelSlot(.haiku, model: "new/fast-model")
        XCTAssertEqual(viewModel.currentConfiguration?.claudeDisplayName(for: .haiku), "Haiku")
    }

    /// 回归用户截图：Opus、Haiku 使用同一请求模型，进入会话后的选择器仍需保留各自角色标题。
    func testSharedRequestModelKeepsDistinctPickerRolesAcrossSaveAndReload() async throws {
        var config = configuration()
        config.modelSlots[.opus] = "shared/model"
        config.modelSlots[.haiku] = "shared/model"
        for _ in 0..<2 {
            _ = try await generate(config)
            let env = try XCTUnwrap(readSettings()["env"] as? [String: String])
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"], "Opus")
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"], "Haiku")
            for slot in [ModelSlot.opus, .haiku] {
                XCTAssertEqual(env["ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL"], "shared/model")
                XCTAssertEqual(env["ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL_DESCRIPTION"], "shared/model")
            }
            let loaded = await service.readConfiguration(agent: .claudeCode)
            let saved = try XCTUnwrap(loaded)
            XCTAssertTrue(saved.modelDisplayNames.isEmpty, "自动角色名称回填为空，继续使用统一默认值")
            config.claudeModelDisplayNames = saved.modelDisplayNames
        }
    }

    /// 已保存的自动 ID 名称必须在回填及重新生成时迁移；有意义的自定义名称保持不变。
    func testLegacyModelIDNamesMigrateWithoutChangingCustomNamesOrRequestModels() async throws {
        var config = configuration()
        config.claudeModel1M = [.opus: true]
        _ = try await generate(config)
        var settings = try readSettings()
        var env = try XCTUnwrap(settings["env"] as? [String: String])
        env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"] = "provider/reasoning-model[1M]"
        env["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"] = "  日常编码  "
        env["ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"] = "provider/fast-model"
        settings["env"] = env
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
        let loaded = await service.readConfiguration(agent: .claudeCode)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.modelDisplayNames, [.sonnet: "日常编码"])
        config.claudeModelDisplayNames = saved.modelDisplayNames
        _ = try await generate(config)
        let updated = try XCTUnwrap(readSettings()["env"] as? [String: String])
        for slot in ModelSlot.allCases {
            let key = "ANTHROPIC_DEFAULT_\(slot.envSuffix)_MODEL"
            XCTAssertEqual(updated[key], env[key], "迁移显示名称不能更改请求目标或 1M")
        }
        XCTAssertEqual(updated["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"], "Opus")
        XCTAssertEqual(updated["ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"], "Haiku")
        XCTAssertEqual(updated["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"], "日常编码")
    }

    /// 旧 Codable 草稿可以直接进入生成器，不能只修复从 settings.json 回填的入口。
    func testLegacyEncodedDraftNormalizesAutomaticNamesButPreservesCustomSpelling() async throws {
        var config = configuration()
        config.claudeModelDisplayNames = [.opus: "provider/reasoning-model", .sonnet: "sonnet", .haiku: "provider/fast-model[1m]"]
        let restored = try JSONDecoder().decode(AgentConfiguration.self, from: JSONEncoder().encode(config))
        _ = try await generate(restored)
        let env = try XCTUnwrap(readSettings()["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"], "Opus")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"], "Haiku")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"], "sonnet", "用户自定义大小写不能被自动角色标题改写")
    }

    /// Claude 拒绝 DEFAULT_MODEL=haiku：启动选择保留角色，Default 项必须使用解析后的实际 ID。
    func testHaikuDefaultFallbackResolvesRequestModelAndIndependentContext() async throws {
        for (selector, slot1M, expected) in [
            ("haiku", false, "provider/fast-model"),
            ("haiku", true, "provider/fast-model[1m]"),
            ("haiku[1m]", false, "provider/fast-model[1m]")
        ] {
            var config = configuration()
            config.claudeModel = selector
            config.claudeModel1M = [.haiku: slot1M]
            let result = try await generate(config, storageOption: .both)
            var settings = try readSettings()
            let env = try XCTUnwrap(settings["env"] as? [String: String])
            XCTAssertEqual(settings["model"] as? String, selector)
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_MODEL"], expected)
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "provider/fast-model" + (slot1M ? "[1m]" : ""))
            XCTAssertTrue(result.shellConfig?.contains("export ANTHROPIC_DEFAULT_MODEL='\(expected)'") == true)
            let manual = try await generate(config, mode: .manual, storageOption: .shellOnly)
            XCTAssertTrue(manual.shellConfig?.contains("export ANTHROPIC_MODEL='\(selector)'") == true)
            XCTAssertTrue(manual.shellConfig?.contains("export ANTHROPIC_DEFAULT_MODEL='\(expected)'") == true)
            // 模拟原生 /model Default 清除显式选择后回填，目标仍可识别，避免退到未知的系统默认。
            settings.removeValue(forKey: "model")
            try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
            let loaded = await service.readConfiguration(agent: .claudeCode)
            let saved = try XCTUnwrap(loaded)
            XCTAssertEqual(saved.defaultModel, "provider/fast-model")
            XCTAssertEqual(saved.claudeDefaultModel1M, expected.hasSuffix("[1m]"))
        }
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
        XCTAssertEqual(env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"], "0")
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
        // 同名的直接默认选择独立于角色，不能因为 Opus 勾选 1M 就被隐式改变。
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_MODEL"], "provider/reasoning-model")
        XCTAssertEqual(env["CLAUDE_CODE_SUBAGENT_MODEL"], "provider/fast-model[1m]")
        XCTAssertEqual(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "275000")

        let saved = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(saved?.modelSlots, config.modelSlots)
        XCTAssertEqual(saved?.claudeModel1M, [.opus: true, .haiku: true])
        XCTAssertEqual(saved?.claudeMaxContextTokens, 275_000)

        config.claudeModel1M = [:]
        _ = try await generate(config)
        env = try XCTUnwrap(readSettings()["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "provider/reasoning-model")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "provider/fast-model")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_MODEL"], "provider/reasoning-model")
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
        object.removeValue(forKey: "claudeGatewayModelDiscovery")
        object.removeValue(forKey: "claudeDefaultModel1M")

        let decoded = try JSONDecoder().decode(
            AgentConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.claudeMaxContextTokens, AgentConfiguration.defaultClaudeMaxContextTokens)
        XCTAssertEqual(decoded.claudeAutoCompactPercentage, AgentConfiguration.defaultClaudeAutoCompactPercentage)
        XCTAssertFalse(decoded.claudeDisableAutoCompact)
        XCTAssertTrue(decoded.claudeModel1M.isEmpty)
        XCTAssertFalse(decoded.claudeGatewayModelDiscovery)
        XCTAssertFalse(decoded.claudeDefaultModel1M)
    }

    /// 同一个模型用于默认行和多个角色时，每行的上下文声明都必须互相独立。
    func testDefaultOneMillionIsIndependentEvenWhenAllRowsUseSameID() async throws {
        var config = configuration()
        config.claudeModel = "shared/model"
        config.modelSlots = Dictionary(uniqueKeysWithValues: ModelSlot.allCases.map { ($0, "shared/model") })
        config.claudeMaxContextTokens = 275_000
        for enabled in [false, true] {
            config.claudeDefaultModel1M = enabled
            config.claudeModel1M = [.opus: !enabled, .sonnet: enabled]
            let result = try await generate(config, storageOption: .both)
            let settings = try readSettings()
            let env = try XCTUnwrap(settings["env"] as? [String: String])
            let expected = enabled ? "shared/model[1m]" : "shared/model"
            XCTAssertEqual(settings["model"] as? String, expected)
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_MODEL"], expected)
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], enabled ? "shared/model" : "shared/model[1m]")
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "shared/model")
            XCTAssertEqual(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "275000")
            XCTAssertTrue(result.shellConfig?.contains("export ANTHROPIC_DEFAULT_MODEL='\(expected)'") == true)
            let saved = await service.readConfiguration(agent: .claudeCode)
            XCTAssertEqual(saved?.defaultModel, "shared/model")
            XCTAssertEqual(saved?.claudeDefaultModel1M, enabled)
        }
    }

    /// 保存继承时必须保留角色 token；槽目标或开关变化后，默认行自动跟随且可无损回填。
    @MainActor
    func testDefaultRoleKeepsReferenceAndInheritsOnlyThatRolesContext() async throws {
        var config = configuration()
        config.claudeDefaultModel1M = true // 暂存的独立选择不应影响跟随模式。
        for slot in ModelSlot.allCases {
            config.claudeModel = slot.rawValue
            for enabled in [false, true] {
                config.claudeModel1M = [.opus: true, .sonnet: true, .haiku: true]
                config.claudeModel1M[slot] = enabled
                config.modelSlots[slot] = "changed/\(slot.rawValue)"
                _ = try await generate(config)
                XCTAssertEqual(try readSettings()["model"] as? String, slot.rawValue)
                XCTAssertEqual(config.claudeDefaultUses1MContext, enabled)
                XCTAssertEqual(config.claudeDefaultRequestModel, "changed/\(slot.rawValue)" + (enabled ? "[1m]" : ""))
                let saved = await service.readConfiguration(agent: .claudeCode)
                XCTAssertEqual(saved?.defaultModel, slot.rawValue)
                XCTAssertEqual(saved?.claudeModel1M[slot] ?? false, enabled)
            }
        }
    }

    /// 旧 JSON 和 cc-switch 来源可能含大写后缀；回填需分离默认行状态，输出只保留一份小写后缀。
    @MainActor
    func testExistingDefaultSuffixRoundTripsIndependentlyFromMatchingRole() async throws {
        _ = try await generate(configuration())
        var settings = try readSettings()
        settings["model"] = "provider/reasoning-model[1M]"
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
        let loaded = await service.readConfiguration(agent: .claudeCode)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.defaultModel, "provider/reasoning-model")
        XCTAssertTrue(saved.claudeDefaultModel1M)
        XCTAssertTrue(saved.claudeModel1M.isEmpty)
        var config = configuration()
        config.claudeDefaultModel = saved.defaultModel
        config.claudeDefaultModel1M = saved.claudeDefaultModel1M
        _ = try await generate(config)
        XCTAssertEqual(try readSettings()["model"] as? String, "provider/reasoning-model[1m]")
        config.claudeDefaultModel1M = false
        _ = try await generate(config)
        XCTAssertEqual(try readSettings()["model"] as? String, "provider/reasoning-model")
    }

    /// Claude 的迁移或 /model 命令可能保存角色[1m]；它不能悄悄打开角色自身的 1M 开关。
    @MainActor
    func testExplicitRoleSuffixPreservedUntilUserReturnsToInheritance() async throws {
        var config = configuration()
        config.claudeModel = "opus[1M]"
        XCTAssertNil(config.claudeDefaultModelSlot)
        XCTAssertEqual(config.claudeDefaultRequestModel, "provider/reasoning-model[1m]")
        _ = try await generate(config)
        let saved = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(saved?.defaultModel, "opus[1m]")
        XCTAssertEqual(saved?.claudeDefaultModel1M, true)
        XCTAssertTrue(saved?.claudeModel1M.isEmpty == true)
        let viewModel = AgentSetupViewModel()
        viewModel.currentConfiguration = config
        viewModel.updateClaudeDefault1MContext(false)
        XCTAssertEqual(viewModel.currentConfiguration?.claudeModel, "opus")
        XCTAssertEqual(viewModel.currentConfiguration?.claudeDefaultModelSlot, .opus)
        XCTAssertEqual(viewModel.currentConfiguration?.claudeDefaultUses1MContext, false)
        viewModel.updateClaude1MContext(true, for: .opus)
        viewModel.updateClaudeDefault1MContext(false) // 继承时只读，不能改动角色或覆盖继承。
        XCTAssertEqual(viewModel.currentConfiguration?.claudeDefaultUses1MContext, true)
    }

    func testLegacyCodableDefaultSuffixRestoresIndependentOneMillion() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration())) as? [String: Any])
        object["claudeDefaultModel"] = "custom/model[1M]"
        object.removeValue(forKey: "claudeDefaultModel1M")
        let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.claudeModel, "custom/model")
        XCTAssertTrue(decoded.claudeDefaultModel1M)
        XCTAssertEqual(decoded.claudeDefaultModelSelector, "custom/model[1m]")
        let restored = try JSONDecoder().decode(AgentConfiguration.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(restored.claudeDefaultModelSelector, decoded.claudeDefaultModelSelector)
    }

    /// 单独渲染模型表格，避免完整弹窗的滚动区域遮住待验收的默认行；输出位于仓库构建目录。
    @MainActor
    func testRenderDefaultRowInheritanceAndIndependentContext() throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ClaudeDefaultRowReview", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for follows in [true, false] {
            var config = configuration()
            config.claudeModel = follows ? "opus" : "provider/reasoning-model"
            config.claudeDefaultModel1M = !follows
            config.claudeModel1M = [.opus: follows]
            config.claudeModelDisplayNames = [.opus: "主力推理", .sonnet: "日常编码", .haiku: "快速任务"]
            let viewModel = AgentSetupViewModel()
            viewModel.selectedAgent = .claudeCode
            viewModel.currentConfiguration = config
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let view = ClaudeModelMappingView(viewModel: viewModel, onOneMillionChange: {})
                    .frame(width: 540).padding(20)
                    .background(QuotioTheme.Colors.cardBackground(for: scheme))
                    .environment(\.colorScheme, scheme)
                let hosting = NSHostingView(rootView: view)
                hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("default-\(follows ? "inherited" : "independent")-\(name).png"))
            }
        }
    }

    @MainActor
    func testRenderAndExportClaudeModelSlotsAndAdvancedSettings() async throws {
        let output = URL(fileURLWithPath: "/Users/liqunmacmini/Desktop/quotio/build/ClaudeModelDisplayReview", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var config = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:8317/v1", apiKey: "quotio-local-test")
        config.claudeModel = ModelSlot.opus.rawValue
        config.modelSlots = [
            .opus: "gemini-3.8-flash-high",
            .sonnet: "glm-5.3",
            .haiku: "gemini-3.8-flash-high"
        ]
        config.claudeModelDisplayNames = [
            .opus: "主力推理",
            .sonnet: "日常编码",
            .haiku: "快速任务"
        ]
        config.claudeModel1M = [.opus: true]

        let viewModel = AgentSetupViewModel()
        viewModel.selectedAgent = .claudeCode
        viewModel.currentConfiguration = config

        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = AgentConfigSheet(viewModel: viewModel, agent: .claudeCode)
                .frame(width: 580, height: 750)
                .environment(\.colorScheme, scheme)

            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()

            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("claude-sheet-\(name).png"))
        }
    }
}
