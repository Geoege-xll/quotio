import XCTest
@testable import QuotioPlus

/// 跨网关兼容性的业务回归：真实配置服务读写临时目录，不访问用户配置、钥匙串或上游。
/// 断言最终请求身份与数据保留，而不是仅比较界面文字。
final class ClaudeConfigurationCompatibilityTests: XCTestCase {
    private var home: URL!
    private var service: AgentConfigurationService!
    private var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    private var models: [AvailableModel] {
        ["gpt-6.1-sol", "gpt-6-astra", "glm-5.3", "glm/glm-5.3"].map {
            .init(id: $0, name: $0, provider: "fixture", isDefault: false)
        }
    }
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCompatibility-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        service = AgentConfigurationService(homeDirectory: home)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    private func config() -> AgentConfiguration {
        var c = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:9/v1", apiKey: "fixture")
        c.modelSlots = [.opus: "codex/gpt-6.1-sol", .sonnet: "codex/gpt-6-astra", .haiku: "custom/manual", .fable: "glm/glm-5.3"]
        c.claudeDefaultModel = "codex/gpt-6.1-sol"
        c.claudeDefaultModel1M = true
        c.claudeSubagentModel = "codex/gpt-6-astra[1M]"
        return c
    }
    private func menu() -> [String: Any] {
        ["future": ["enabled": true], "options": [
            ["model": "codex/gpt-6.1-sol", "label": "GPT", "description": "Codex · account-A", "futureID": Int64.max],
            ["model": "codex/gpt-6.1-sol", "label": "另一账号", "description": "Codex · account-B"],
            ["model": "zhipu/glm-5.3[1M]", "label": "GLM", "description": "智谱"],
            ["model": "antigravity/missing-model[1m]", "label": "旧型号", "future": ["retain": true]],
            ["model": "glm/glm-5.3", "label": "合法前缀"],
        ]]
    }
    private func write(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]).write(to: settingsURL)
    }
    private func read() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    }
    private func save(_ c: AgentConfiguration, models: [AvailableModel]? = nil,
                      mode: ConfigurationMode = .automatic, storage: ConfigStorageOption = .jsonOnly) async throws -> AgentConfigResult {
        try await service.generateConfiguration(agent: .claudeCode, config: c, mode: mode,
            storageOption: storage, detectionService: AgentDetectionService(), availableModels: models ?? self.models)
    }

    func testSinglePlanCoordinatesRolesDefaultMenuSubagentAndLegacyReferences() throws {
        var c = config()
        c.claudeModel1M[.opus] = true
        c.claudeModelPicker = .read(menu())
        c.claudeModelPicker.shouldWrite = false
        let legacy = ClaudeLegacyModelReferences(smallFastModel: "codex/gpt-6-astra[1M]",
            capabilities: "codex/gpt-6.1-sol=effort,max_effort;future-format;opaque=model=keep",
            modelSettings: ["codex/gpt-6.1-sol": .object(["future": .integer(Int64.max)])])
        let plan = ClaudeConfigurationPlan(configuration: c, availableModels: models, legacy: legacy)
        XCTAssertEqual(plan.configuration.claudeRequestModel(for: .opus), "gpt-6.1-sol[1m]")
        XCTAssertEqual(plan.configuration.claudeDefaultRequestModel, "gpt-6.1-sol[1m]")
        XCTAssertEqual(plan.configuration.claudeSubagentSelector, "gpt-6-astra[1m]")
        XCTAssertEqual(plan.configuration.modelSlots[.fable], "glm/glm-5.3")
        XCTAssertEqual(plan.configuration.claudeEffectivePickerOptions.map(\.model),
                       ["gpt-6.1-sol", "gpt-6.1-sol", "glm-5.3[1m]", "antigravity/missing-model[1m]", "glm/glm-5.3"])
        XCTAssertEqual(plan.legacy.smallFastModel, "gpt-6-astra[1m]")
        XCTAssertEqual(plan.legacy.capabilities, "gpt-6.1-sol=effort,max_effort;future-format;opaque=model=keep")
        XCTAssertEqual(plan.legacy.modelSettings?["gpt-6.1-sol"], legacy.modelSettings?["codex/gpt-6.1-sol"])
        XCTAssertEqual(plan.unresolved, ["antigravity/missing-model[1m]"])
        XCTAssertEqual(c.modelSlots[.opus], "codex/gpt-6.1-sol", "纯计划不能回写原表单")
        XCTAssertFalse(plan.configuration.claudeModelPicker.shouldWrite)
    }

    func testExactQualifiedIDsUnknownNamespacesAndNativeAliasesArePreserved() {
        var c = config()
        c.modelSlots = [.opus: "codex/gpt-6.1-sol", .sonnet: "team/gpt-6-astra", .haiku: "haiku", .fable: "fable"]
        c.claudeDefaultModel = "opus[1m]"
        c.claudeSubagentModel = "fable"
        let catalog = models + [.init(id: "codex/gpt-6.1-sol", name: "名称不是ID", provider: "other", isDefault: false)]
        let plan = ClaudeConfigurationPlan(configuration: c, availableModels: catalog)
        XCTAssertEqual(plan.configuration.modelSlots, c.modelSlots)
        XCTAssertEqual(plan.configuration.claudeDefaultModel, "opus[1m]")
        XCTAssertEqual(plan.configuration.claudeSubagentModel, "fable")
        XCTAssertTrue(plan.migrations.isEmpty)
    }

    func testPreservedNameInAutomaticRoleMenuKeepsOneMillionLabel() {
        var c = config()
        c.claudeModelDisplayNames = [.opus: "gpt-6.1-sol"]
        c.claudeModelPicker = .read(["options": [["model": "opus[1m]"]]])
        let plan = ClaudeConfigurationPlan(configuration: c, availableModels: models)
        let option = plan.configuration.claudeModelPicker.options[0]
        XCTAssertEqual(plan.configuration.claudePickerLabel(for: option), "gpt-6.1-sol · 1M")
        XCTAssertEqual(option.model, "opus[1m]")
    }

    func testEmptyDirectoryDoesNotGuessAndMissingModelsKeepOriginalValues() {
        let c = config()
        let empty = ClaudeConfigurationPlan(configuration: c, availableModels: [])
        XCTAssertEqual(empty.configuration.modelSlots, c.modelSlots)
        XCTAssertTrue(empty.migrations.isEmpty)
        let absent = ClaudeConfigurationPlan(configuration: c, availableModels: [models[2]])
        XCTAssertEqual(absent.configuration.modelSlots, c.modelSlots)
        XCTAssertTrue(absent.unresolved.contains("codex/gpt-6.1-sol"))
    }

    func testConflictingAssociatedKeysKeepAllValuesAndCurrentTargetWins() {
        let legacy = ClaudeLegacyModelReferences(capabilities: "codex/gpt-6.1-sol=max_effort;gpt-6.1-sol=effort",
            modelSettings: ["codex/gpt-6.1-sol": .string("old"), "gpt-6.1-sol": .object(["future": .unsignedInteger(UInt64.max)])])
        let plan = ClaudeConfigurationPlan(configuration: config(), availableModels: models, legacy: legacy)
        XCTAssertEqual(plan.legacy, legacy)
        XCTAssertEqual(plan.conflicts, ["codex/gpt-6.1-sol"])
    }

    func testRealSaveMatchesPlanAndPreservesBackupUnknownFieldsAndDuplicateAccounts() async throws {
        let input: [String: Any] = ["modelPicker": menu(), "permissions": ["allow": ["Read"]], "futureRoot": [1, 2],
            "env": ["USER_SETTING": "keep", "ANTHROPIC_SMALL_FAST_MODEL": "codex/gpt-6-astra[1m]",
                    "CLAUDE_CODE_MODEL_CAPABILITIES": "codex/gpt-6.1-sol=effort"],
            "modelSettings": ["codex/gpt-6.1-sol": ["future": Int64.max]]]
        try write(input)
        let before = try Data(contentsOf: settingsURL)
        let c = config(), plan = ClaudeConfigurationPlan(configuration: c, availableModels: models, legacy: .read(input))
        let result = try await save(c, storage: .both)
        XCTAssertTrue(result.success, result.error ?? "")
        let out = try read(), env = try XCTUnwrap(out["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], plan.configuration.claudeRequestModel(for: .opus))
        XCTAssertEqual(out["model"] as? String, plan.configuration.claudeDefaultModelSelector)
        XCTAssertEqual(env["CLAUDE_CODE_SUBAGENT_MODEL"], plan.configuration.claudeSubagentSelector)
        XCTAssertEqual(env["ANTHROPIC_SMALL_FAST_MODEL"], plan.legacy.smallFastModel)
        XCTAssertEqual(env["CLAUDE_CODE_MODEL_CAPABILITIES"], plan.legacy.capabilities)
        XCTAssertTrue(result.shellConfig?.contains("ANTHROPIC_SMALL_FAST_MODEL='gpt-6-astra[1m]'") == true)
        let picker = try XCTUnwrap(out["modelPicker"] as? [String: Any])
        let rows = try XCTUnwrap(picker["options"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.prefix(2).compactMap { $0["model"] as? String }, ["gpt-6.1-sol", "gpt-6.1-sol"])
        XCTAssertEqual((rows[0]["futureID"] as? NSNumber)?.int64Value, Int64.max)
        let originalRows = try XCTUnwrap((input["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]])
        XCTAssertEqual(rows[3] as NSDictionary, originalRows[3] as NSDictionary)
        XCTAssertNil(picker["quotioManaged"])
        XCTAssertNil(picker["replaceBuiltInOptions"])
        XCTAssertEqual(out["permissions"] as? [String: [String]], ["allow": ["Read"]])
        XCTAssertEqual(out["futureRoot"] as? [Int], [1, 2])
        XCTAssertEqual(env["USER_SETTING"], "keep")
        let backupPath = try XCTUnwrap(result.backupPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backupPath)), before)
        let first = out as NSDictionary
        let second = try await save(c, storage: .both)
        XCTAssertTrue(second.success)
        XCTAssertEqual(try read() as NSDictionary, first, "重复使用旧草稿保存也必须幂等")
    }

    func testSavingUsesLatestDiskMenuInsteadOfAnEarlierFormSnapshot() async throws {
        try write(["modelPicker": menu()])
        let loaded = await service.readConfiguration(agent: .claudeCode)
        let saved = try XCTUnwrap(loaded)
        var c = config(); c.claudeModelPicker = saved.claudeModelPicker
        let latest: [String: Any] = ["options": [["model": "codex/gpt-6-astra", "label": "其他工具的新标题", "future": 9]]]
        try write(["modelPicker": latest])
        let result = try await save(c)
        XCTAssertTrue(result.success)
        let rows = try XCTUnwrap((read()["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["model"] as? String, "gpt-6-astra")
        XCTAssertEqual(rows[0]["label"] as? String, "其他工具的新标题")
        XCTAssertEqual(rows[0]["future"] as? Int, 9)
    }

    func testUnrecognizedMenuIsPreservedWholeWhileRelatedReferencesMigrate() async throws {
        let external: [String: Any] = ["options": [["futureModel": "unknown"]], "future": Int64.max]
        try write(["modelPicker": external, "env": ["ANTHROPIC_SMALL_FAST_MODEL": "codex/gpt-6-astra"]])
        let result = try await save(config())
        XCTAssertTrue(result.success)
        XCTAssertEqual(try read()["modelPicker"] as? NSDictionary, external as NSDictionary)
        XCTAssertEqual((try read()["env"] as? [String: String])?["ANTHROPIC_SMALL_FAST_MODEL"], "gpt-6-astra")
    }

    func testUnknownEnvironmentValueDoesNotDiscardKnownFieldsOrItsOwnData() async throws {
        try write(["env": ["ANTHROPIC_DEFAULT_SONNET_MODEL": "codex/gpt-6-astra",
                           "ANTHROPIC_SMALL_FAST_MODEL": "codex/gpt-6-astra",
                           "USER_TEXT": "keep", "futureObject": ["integer": Int64.max]]])
        let loaded = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(loaded?.modelSlots[.sonnet], "codex/gpt-6-astra")
        let result = try await save(config())
        XCTAssertTrue(result.success)
        let env = try XCTUnwrap(read()["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_SMALL_FAST_MODEL"] as? String, "gpt-6-astra")
        XCTAssertEqual(env["USER_TEXT"] as? String, "keep")
        XCTAssertEqual((env["futureObject"] as? [String: NSNumber])?["integer"]?.int64Value, Int64.max)
    }

    func testNameEqualToMigratedIDSurvivesReopenPreviewAndRepeatedSave() async throws {
        try write(["env": ["ANTHROPIC_DEFAULT_OPUS_MODEL": "codex/gpt-6.1-sol",
                           "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "gpt-6.1-sol"]])
        for _ in 0..<3 {
            let loaded = await service.readConfiguration(agent: .claudeCode)
            let saved = try XCTUnwrap(loaded)
            var c = config()
            c.modelSlots = saved.modelSlots
            c.claudeModelDisplayNames = saved.modelDisplayNames
            let plan = ClaudeConfigurationPlan(configuration: c, availableModels: models, legacy: saved.claudeLegacyModelReferences)
            XCTAssertEqual(plan.displayName(for: .opus), "gpt-6.1-sol", "面板和写出使用同一已判定名称")
            let result = try await save(c)
            XCTAssertTrue(result.success)
            let env = try XCTUnwrap(read()["env"] as? [String: String])
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "gpt-6.1-sol")
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"], "gpt-6.1-sol")
        }
        var object = try read(), env = try XCTUnwrap(object["env"] as? [String: String])
        env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"] = "Opus"
        object["env"] = env
        try write(object)
        let loaded = await service.readConfiguration(agent: .claudeCode)
        let saved = try XCTUnwrap(loaded)
        var c = config(); c.modelSlots = saved.modelSlots; c.claudeModelDisplayNames = saved.modelDisplayNames
        let plan = ClaudeConfigurationPlan(configuration: c, availableModels: models, legacy: saved.claudeLegacyModelReferences)
        XCTAssertEqual(plan.displayName(for: .opus), "Opus", "外部名称改动必须使旧绑定失效")
        c.modelSlots[.opus] = "gpt-6-astra"
        let changed = ClaudeConfigurationPlan(configuration: c, availableModels: models, legacy: saved.claudeLegacyModelReferences)
        XCTAssertEqual(changed.displayName(for: .opus), "Opus", "绑定不能套用到另一个模型")
    }

    func testUnreadableStructureIsNeverReplacedAndEmptyFileStillSupportsFirstSetup() async throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for text in ["{invalid", "[1,2]", "null"] {
            let original = Data(text.utf8)
            try original.write(to: settingsURL)
            let result = try await save(config())
            XCTAssertFalse(result.success)
            XCTAssertEqual(try Data(contentsOf: settingsURL), original)
            let backups = await service.listBackups(agent: .claudeCode)
            XCTAssertTrue(backups.isEmpty)
        }
        try Data(" \n\t".utf8).write(to: settingsURL)
        let result = try await save(config())
        XCTAssertTrue(result.success)
        XCTAssertEqual(try read()["model"] as? String, "gpt-6.1-sol[1m]")
    }

    func testShellOnlyCannotPretendToMigrateExistingJSONReferences() async throws {
        try write(["modelPicker": menu()])
        let original = try Data(contentsOf: settingsURL)
        let result = try await save(config(), storage: .shellOnly)
        XCTAssertFalse(result.success)
        XCTAssertEqual(try Data(contentsOf: settingsURL), original)
        let backups = await service.listBackups(agent: .claudeCode)
        XCTAssertTrue(backups.isEmpty)
        let manual = try await save(config(), mode: .manual)
        XCTAssertTrue(manual.success, "手动输出仍能提供完整 JSON，不能在预览阶段被误拦")
    }

    @MainActor
    func testDirectoryEvidenceIsInvalidAfterConnectionChangeOrReopen() async throws {
        try write(["modelPicker": menu()])
        let models = self.models
        let vm = AgentSetupViewModel(configurationService: service, fetchModels: { _, _ in models },
                                     configurationEndpoint: { "https://fixture.invalid" })
        let id = vm.startConfiguration(for: .claudeCode, apiKey: "fixture")
        for _ in 0..<200 {
            if !vm.isLoadingConfiguration && !vm.isFetchingModels { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vm.claudeCompatibilityModels.count, models.count)
        XCTAssertFalse(try XCTUnwrap(vm.claudeCompatibilityPlan).migrations.isEmpty)
        vm.currentConfiguration?.apiKey = "new-client-key"
        XCTAssertTrue(vm.claudeCompatibilityModels.isEmpty)
        XCTAssertTrue(try XCTUnwrap(vm.claudeCompatibilityPlan).migrations.isEmpty)
        vm.currentConfiguration?.apiKey = "fixture"
        vm.currentConfiguration?.proxyURL = "https://other.invalid/v1"
        XCTAssertTrue(vm.claudeCompatibilityModels.isEmpty)
        vm.dismissConfiguration(sessionID: id)
        XCTAssertNil(vm.claudeCompatibilityPlan)
    }
}
