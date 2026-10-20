import Foundation
import XCTest
@testable import QuotioPlus

/// 以生产计划和实际 JSON 验证追加菜单契约；目录、账号与凭据均是临时夹具。
final class ClaudeMenuSourceTests: XCTestCase {
    private func configuration() -> AgentConfiguration {
        var result = AgentConfiguration(agent: .claudeCode, proxyURL: "https://fixture.invalid/v1", apiKey: "fixture-only")
        result.claudeCatalogManaged = true
        result.modelSlots = [.opus: "base", .sonnet: "base", .haiku: "base"]
        return result
    }
    private var catalog: [AvailableModel] {
        [AvailableModel(id: "base", name: "Base", provider: "fixture", isDefault: false),
         AvailableModel(id: "fixed", name: "Fixed Model", provider: "openai", isDefault: false,
            displaySource: .init(platforms: ["codex"], account: "work@test.invalid", isAccountPool: false)),
         AvailableModel(id: "pool", name: "Pool Model", provider: "openai", isDefault: false,
            displaySource: .init(platforms: ["antigravity"], account: nil, isAccountPool: true)),
         AvailableModel(id: "unknown", name: "Unknown Model", provider: "openai", isDefault: false)]
    }
    func testAllNewRowsHaveNamesAndSourceInsteadOfDuplicatedIDs() throws {
        let plan = ClaudeConfigurationPlan(configuration: configuration(), availableModels: catalog)
        let rows = plan.configuration.claudeEffectivePickerOptions
        XCTAssertEqual(rows.first { $0.model == "fixed" }?.label, "Fixed Model")
        XCTAssertEqual(rows.first { $0.model == "fixed" }?.description, "Codex · work@test.invalid")
        XCTAssertEqual(rows.first { $0.model == "pool" }?.description, "Antigravity · " + "agents.claudeMenu.accountPool".localizedStatic())
        XCTAssertEqual(rows.first { $0.model == "unknown" }?.description, "agents.claudeMenu.sourceUnknown".localizedStatic())
        XCTAssertFalse(rows.contains { $0.description == $0.model })
        let output = try XCTUnwrap(plan.configuration.claudePickerJSONObject() as? [String: Any])
        let written = try XCTUnwrap(output["options"] as? [[String: Any]])
        for row in rows {
            XCTAssertEqual(written.first { $0["model"] as? String == row.selector }?["label"] as? String,
                           plan.configuration.claudePickerLabel(for: row))
            XCTAssertEqual(written.first { $0["model"] as? String == row.selector }?["description"] as? String,
                           plan.configuration.claudePickerDescription(for: row))
        }
    }
    func testSourceChangesRefreshExistingGeneratedDescriptionsAndPreserveCustomLabelAndExtensions() {
        var value = configuration()
        value.claudeModelPicker.options.append(.init(model: "pool", label: "用户保留名称", description: "旧平台 · 旧邮箱",
            extraFields: ["future": .unsignedInteger(UInt64.max)]))
        let before = value
        let plan = ClaudeConfigurationPlan(configuration: value, availableModels: catalog)
        let row = plan.configuration.claudeEffectivePickerOptions.first { $0.model == "pool" }
        XCTAssertEqual(row?.label, "用户保留名称")
        XCTAssertEqual(row?.description, "Antigravity · " + "agents.claudeMenu.accountPool".localizedStatic())
        XCTAssertEqual(row?.extraFields["future"], .unsignedInteger(UInt64.max))
        XCTAssertEqual(value, before, "预览纯计划不能回写草稿")
    }
    func testMagpieRowsAreRemovedButOriginalBackupAndUnknownFieldsSurvive() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeMenuSource-" + UUID().uuidString)
        let file = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let original: [String: Any] = ["futureRoot": ["keep": true], "modelPicker": ["futureMenu": ["keep": true], "options": [
            ["model": "codex/fixed", "label": "旧 Magpie", "description": "old@test.invalid · via magpie", "futureRow": UInt64.max],
            ["model": "pool", "label": "保留名称", "description": "旧说明", "futureRow": ["keep": true]]]]]
        let bytes = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        try bytes.write(to: file)
        let service = AgentConfigurationService(homeDirectory: home)
        let result = try await service.generateConfiguration(agent: .claudeCode, config: configuration(), mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: catalog)
        XCTAssertTrue(result.success, result.error ?? "")
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let menu = try XCTUnwrap(after["modelPicker"] as? [String: Any])
        let rows = try XCTUnwrap(menu["options"] as? [[String: Any]])
        XCTAssertFalse(rows.contains { $0["label"] as? String == "旧 Magpie" })
        XCTAssertFalse(rows.contains { ($0["description"] as? String)?.contains("old@test.invalid") == true })
        XCTAssertEqual(after["futureRoot"] as? NSDictionary, ["keep": true])
        XCTAssertEqual(menu["futureMenu"] as? NSDictionary, ["keep": true])
        XCTAssertEqual(rows.first { $0["model"] as? String == "pool" }?["futureRow"] as? NSDictionary, ["keep": true])
        let backup = try XCTUnwrap(result.backupPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backup)), bytes)
    }
    func testValidPrefixWithoutMagpieMarkerIsNeverMistakenForLegacyAccount() {
        var value = configuration()
        value.claudeModelPicker.options.append(.init(model: "codex/legal", label: "保留合法前缀"))
        let models = catalog + [AvailableModel(id: "codex/legal", name: "Legal Model", provider: "fixture", isDefault: false)]
        let plan = ClaudeConfigurationPlan(configuration: value, availableModels: models)
        XCTAssertTrue(plan.blockingReferences.isEmpty)
        XCTAssertTrue(plan.configuration.claudeEffectivePickerOptions.contains { $0.model == "codex/legal" })
        XCTAssertEqual(plan.removedLegacyMenuCount, 0)
    }

    /// 通过实际配置服务写入临时文件，核对目录容量最终进入角色、Default 和追加菜单的同一份输出。
    func testAutomaticContextWritesConsistentRoleDefaultAndMenuJSON() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeMenuContext-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var value = configuration()
        value.modelSlots[.opus] = "long"
        value.claudeDefaultModel = "long"
        // 角色已覆盖的 ID 不会重复自动追加；显式保留旧字面项，验证它与角色使用同一容量规则。
        value.claudeModelPicker.options.append(.init(model: "long"))
        value.claudeModelPicker.shouldWrite = true
        let models = catalog + [AvailableModel(id: "long", name: "Long Model", provider: "fixture", isDefault: false,
                                             contextWindow: 1_048_576)]
        let result = try await AgentConfigurationService(homeDirectory: home).generateConfiguration(agent: .claudeCode,
            config: value, mode: .automatic, detectionService: AgentDetectionService(), availableModels: models)
        XCTAssertTrue(result.success, result.error ?? "")
        let file = home.appendingPathComponent(".claude/settings.json")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let env = try XCTUnwrap(document["env"] as? [String: String])
        XCTAssertEqual(document["model"] as? String, "long[1m]")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "long[1m]")
        let rows = try XCTUnwrap((document["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]])
        XCTAssertEqual(rows.first { $0["model"] as? String == "long[1m]" }?["label"] as? String, "Long Model[1m]")
        XCTAssertNil(value.claudeModel1M[.opus], "生成器不得回写调用方草稿")
    }
    func testAutomaticContextResolvesLegacyPrefixAndSharesRoleMenuAndOutputRules() throws {
        var value = configuration()
        value.modelSlots[.opus] = "codex/long"
        value.claudeDefaultModel = "opus"
        value.claudeModelPicker.options = [.init(model: "opus")]
        let long = AvailableModel(id: "long", name: "Long Model", provider: "fixture", isDefault: false, contextWindow: 1_048_576)
        let plan = ClaudeConfigurationPlan(configuration: value, availableModels: catalog + [long])
        XCTAssertTrue(plan.blockingReferences.isEmpty)
        XCTAssertEqual(plan.configuration.claudeRequestModel(for: .opus), "long[1m]")
        XCTAssertEqual(plan.configuration.claudeDefaultRequestModel, "long[1m]")
        XCTAssertTrue(plan.configuration.claudeDefaultUses1MContext)
        XCTAssertEqual(plan.configuration.claudeEffectivePickerOptions.first { $0.model == "opus" }?.description, "long[1m]")
        XCTAssertEqual(plan.confirmedRequest("opus"), "long[1m]")
        XCTAssertEqual(value.modelSlots[.opus], "codex/long", "纯投影不能改写原选择")
    }
    @MainActor
    func testChoosingBeforeCatalogLoadsDoesNotPinFalseAndExplicitOldChoicesStillSurvive() async {
        let model = AvailableModel(id: "long", name: "long", provider: "fixture", isDefault: false, contextWindow: 1_048_576)
        let vm = AgentSetupViewModel(fetchModels: { _, _ in [model] })
        vm.selectedAgent = .claudeCode
        vm.currentConfiguration = configuration()
        vm.updateModelSlot(.opus, model: "long")
        XCTAssertNil(vm.currentConfiguration?.claudeModel1M[.opus])
        let loaded = await vm.loadModels()
        XCTAssertTrue(loaded)
        XCTAssertEqual(vm.claudeCompatibilityPlan?.configuration.claudeRequestModel(for: .opus), "long[1m]")
        vm.currentConfiguration?.modelSlots[.haiku] = "long"
        vm.currentConfiguration?.claudeModel1M[.haiku] = false
        XCTAssertEqual(vm.claudeCompatibilityPlan?.configuration.claudeRequestModel(for: .haiku), "long")
        vm.updateDefaultModel("long")
        XCTAssertFalse(vm.currentConfiguration?.claudeDefaultUses1MContext == true, "自动推导不应污染原草稿")
        XCTAssertTrue(vm.claudeCompatibilityPlan?.configuration.claudeDefaultUses1MContext == true)
        vm.updateModelSlot(.sonnet, model: "long")
        XCTAssertNil(vm.currentConfiguration?.claudeModel1M[.sonnet])
        XCTAssertEqual(vm.claudeCompatibilityPlan?.configuration.claudeRequestModel(for: .sonnet), "long[1m]")
        // 同一 ID 的容量更新只能改变纯计划，不能被上一轮推导值钉住，也不能覆盖历史显式选择。
        var shorter = model
        shorter.contextWindow = 128_000
        let refreshed = ClaudeConfigurationPlan(configuration: vm.currentConfiguration!, availableModels: catalog + [shorter])
        XCTAssertEqual(refreshed.configuration.claudeRequestModel(for: .sonnet), "long")
        XCTAssertEqual(refreshed.configuration.claudeDefaultRequestModel, "long")
        XCTAssertEqual(refreshed.configuration.claudeRequestModel(for: .haiku), "long")
        // 输入自带的显式声明仍是兼容契约，不能因 setter 拆分后缀或目录容量较小而被吞掉。
        vm.updateDefaultModel("long[1M]")
        let explicit = ClaudeConfigurationPlan(configuration: vm.currentConfiguration!, availableModels: catalog + [shorter])
        XCTAssertEqual(explicit.configuration.claudeDefaultRequestModel, "long[1m]")
        XCTAssertTrue(vm.currentConfiguration?.claudeDefaultModel1M == true)
    }
}
