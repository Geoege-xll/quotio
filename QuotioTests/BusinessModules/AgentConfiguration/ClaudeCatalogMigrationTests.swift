import XCTest
@testable import QuotioPlus

/// 目录接管是完整配置事务：覆盖请求身份、已生效菜单、关联字段和备份恢复，不访问真实账号。
/// 全部写入都限定临时 home；失败由注入的原子写入依赖制造，不修改用户文件权限或真实 Shell。
final class ClaudeCatalogMigrationTests: XCTestCase {
    private var home: URL!
    private var service: AgentConfigurationService!
    private var file: URL { home.appendingPathComponent(".claude/settings.json") }
    private var models: [AvailableModel] {
        ["live-one", "live-two", "legal/model", "api-alias"].map { .init(id: $0, name: $0, provider: "fixture", isDefault: false) }
    }
    private func config() -> AgentConfiguration {
        var c = AgentConfiguration(agent: .claudeCode, proxyURL: "https://fixture.invalid/v1", apiKey: "fixture-secret")
        c.claudeCatalogManaged = true
        c.modelSlots = [.opus: "codex/live-one", .sonnet: "live-two", .haiku: "live-one"]
        c.claudeDefaultModel = "sonnet"
        c.claudeSubagentModel = "haiku"
        return c
    }
    private func input() -> [String: Any] {
        ["modelPicker": ["futureMenu": ["integer": UInt64.max], "options": [
            ["model": "codex/live-one", "label": "工作模型", "description": "账号 A", "future": Int64.max],
            ["model": "codex/live-one", "label": "另一个账号", "description": "账号 B"],
            ["model": "retired-route[1m]", "label": "旧模型", "future": ["preserved": true]],
            ["model": "api-alias", "label": "已公开别名"]]],
         "env": ["USER_FIELD": ["keep": true], "ANTHROPIC_SMALL_FAST_MODEL": "missing-background",
                 "CLAUDE_CODE_MODEL_CAPABILITIES": "codex/live-one=old;live-one=current;missing=keep;future-format"],
         "modelSettings": ["codex/live-one": ["old": true], "live-one": ["current": Int64.max], "missing": ["retainedInBackup": true]],
         "fallbackModel": ["codex/live-one", "missing-fallback", "default"], "advisorModel": "missing-advisor",
         "permissions": ["allow": ["Read"]], "futureRoot": ["keep": UInt64.max]]
    }
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCatalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        service = AgentConfigurationService(homeDirectory: home)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    private func write(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: file)
    }
    private func read() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }
    private func save(_ value: AgentConfiguration? = nil, directory: [AvailableModel]? = nil,
                      storage: ConfigStorageOption = .jsonOnly) async throws -> AgentConfigResult {
        try await service.generateConfiguration(agent: .claudeCode, config: value ?? config(), mode: .automatic,
            storageOption: storage, detectionService: AgentDetectionService(), availableModels: directory ?? models)
    }
    func testOnePlanRemovesUnknownMenuModelsAndResolvesAllPublishedRows() throws {
        var c = config(); c.claudeModelPicker = .read(input()["modelPicker"])
        let plan = ClaudeConfigurationPlan(configuration: c, availableModels: models, legacy: .read(input()))
        XCTAssertTrue(plan.blockingReferences.isEmpty)
        XCTAssertTrue(plan.removedModels.contains("retired-route[1m]"))
        XCTAssertFalse(plan.configuration.claudeEffectivePickerOptions.contains { $0.model == "retired-route[1m]" })
        XCTAssertTrue(plan.configuration.claudeEffectivePickerOptions.allSatisfy { plan.confirmedRequest($0.selector) != nil })
        XCTAssertEqual(plan.configuration.claudeEffectivePickerOptions.filter { $0.model == "live-one" }.count, 2)
        XCTAssertTrue(plan.configuration.claudeEffectivePickerOptions.contains { $0.model == "legal/model" })
        XCTAssertEqual(plan.configuration.claudeModelPicker.mode, .curated)
        XCTAssertFalse(plan.configuration.claudeGatewayModelDiscovery)
        XCTAssertEqual(plan.legacy.capabilities, "live-one=current;future-format")
        XCTAssertNil(plan.legacy.modelSettings?["codex/live-one"])
        XCTAssertNil(plan.legacy.modelSettings?["missing"])
        XCTAssertEqual(plan.legacy.fallbackModel, .array([.string("live-one"), .string("default")]))
        XCTAssertNil(plan.legacy.advisorModel)
    }

    /// 模拟实际现场：交换角色目标后，磁盘菜单仍保留上次的角色说明。
    /// 固定角色说明必须随新映射更新；角色标题、未知字段和追加模型的账号信息不能被一起重建。
    func testRoleMenuDescriptionsFollowCurrentMappingAndExplicitOneMVariant() async throws {
        let oldMenu: [String: Any] = ["future-menu": ["keep": true], "options": [
            ["model": "opus", "label": "自定义 Opus", "description": "antigravity/live-two[1m]", "future-row": ["keep": true]],
            ["model": "sonnet", "label": "Sonnet", "description": "codex/live-one"],
            ["model": "opus[1m]", "label": "长上下文角色", "description": "antigravity/live-two[1m]"],
            ["model": "live-two", "label": "独立账号", "description": "平台 · 账号 A"]]]
        try write(["modelPicker": oldMenu])
        var value = config(); value.modelSlots = [.opus: "live-one", .sonnet: "live-two", .haiku: "live-one"]
        value.claudeModelPicker = .read(oldMenu); value.claudeModelPicker.shouldWrite = false
        let directory = [
            AvailableModel(id: "live-one", name: "live-one", provider: "fixture", isDefault: false, displayPlatform: "codex"),
            AvailableModel(id: "live-two", name: "live-two", provider: "fixture", isDefault: false, displayPlatform: "antigravity")]
        let before = try JSONEncoder().encode(value)
        let plan = ClaudeConfigurationPlan(configuration: value, availableModels: directory)
        let options = plan.configuration.claudeEffectivePickerOptions
        XCTAssertEqual(options.first { $0.model == "opus" }?.description, "codex/live-one")
        XCTAssertEqual(options.first { $0.model == "sonnet" }?.description, "antigravity/live-two")
        XCTAssertEqual(options.first { $0.model == "opus[1m]" }?.description, "codex/live-one[1m]")
        XCTAssertEqual(options.first { $0.model == "live-two" }?.description, "Antigravity", "旧账号文案不能当作当前实际绑定，目录仅证明归属时只显示平台")
        XCTAssertEqual(options.first { $0.model == "opus" }?.label, "自定义 Opus")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: before) as? NSDictionary, "只读预览不能改写原草稿")
        let result = try await save(value, directory: directory)
        XCTAssertTrue(result.success, result.error ?? "")
        let root = try read()
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        let menu = try XCTUnwrap(root["modelPicker"] as? [String: Any])
        let rows = try XCTUnwrap(menu["options"] as? [[String: Any]])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String, "live-one")
        XCTAssertEqual(rows.first { $0["model"] as? String == "opus" }?["description"] as? String, "codex/live-one")
        XCTAssertEqual((rows.first { $0["model"] as? String == "opus" }?["future-row"] as? [String: Bool])?["keep"], true)
        XCTAssertEqual((menu["future-menu"] as? [String: Bool])?["keep"], true)
    }
    func testSavePreservesUnknownFieldsAndByteExactBackupAndProducesRedactedReport() async throws {
        let original = input(); try write(original)
        let before = try Data(contentsOf: file)
        let result = try await save()
        XCTAssertTrue(result.success, result.error ?? "")
        let after = try read(), picker = try XCTUnwrap(after["modelPicker"] as? [String: Any])
        XCTAssertEqual(picker["replaceBuiltInOptions"] as? Bool, true)
        XCTAssertEqual((picker["futureMenu"] as? [String: NSNumber])?["integer"]?.uint64Value, UInt64.max)
        XCTAssertEqual((after["futureRoot"] as? [String: NSNumber])?["keep"]?.uint64Value, UInt64.max)
        XCTAssertEqual((after["permissions"] as? NSDictionary), original["permissions"] as? NSDictionary)
        let env = try XCTUnwrap(after["env"] as? [String: Any])
        XCTAssertEqual(env["USER_FIELD"] as? NSDictionary, ["keep": true])
        XCTAssertNil(env["ANTHROPIC_SMALL_FAST_MODEL"])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_MODEL"] as? String, "live-two", "原生 Default 必须落到确认的实际目标")
        let backup = try XCTUnwrap(result.backupPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backup)), before)
        let report = try Data(contentsOf: URL(fileURLWithPath: backup + ".migration.json"))
        XCTAssertFalse(String(decoding: report, as: UTF8.self).contains("fixture-secret"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: report) as? [String: Any])?["status"] as? String, "committed")
        let rows = try XCTUnwrap(picker["options"] as? [[String: Any]])
        XCTAssertEqual((try XCTUnwrap(rows.first { $0["label"] as? String == "工作模型" })["future"] as? NSNumber)?.int64Value, Int64.max)
    }
    func testEmptyMissingRoleAndUnsupportedMenuFailBeforeAnyBackupOrWrite() async throws {
        try write(input()); let before = try Data(contentsOf: file)
        let empty = try await save(directory: []); XCTAssertFalse(empty.success)
        var c = config(); c.modelSlots[.haiku] = "missing-role"
        let missing = try await save(c); XCTAssertFalse(missing.success)
        c = config(); c.claudeModelPicker = .read(["options": [["futureModel": "opaque"]]])
        c.claudeModelPicker.shouldWrite = true
        let external = try await save(c); XCTAssertFalse(external.success)
        let shell = try await save(storage: .shellOnly); XCTAssertFalse(shell.success)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let backups = await service.listBackups(agent: .claudeCode); XCTAssertTrue(backups.isEmpty)
    }
    func testRestoreIsAtomicAndCreatesAnotherBackupEvenWithinSameSecond() async throws {
        try write(input()); let before = try Data(contentsOf: file)
        let result = try await save(); XCTAssertTrue(result.success)
        let migrated = try Data(contentsOf: file)
        let firstList = await service.listBackups(agent: .claudeCode)
        let original = try XCTUnwrap(firstList.first)
        try await service.restoreFromBackup(original)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let backups = await service.listBackups(agent: .claudeCode)
        XCTAssertEqual(backups.count, 2)
        XCTAssertTrue(try backups.contains { try Data(contentsOf: URL(fileURLWithPath: $0.path)) == migrated })
    }
    func testAtomicWriteFailureLeavesOriginalAndVerifiedBackup() async throws {
        try write(input()); let before = try Data(contentsOf: file)
        service = AgentConfigurationService(homeDirectory: home, writeConfigurationData: { data, url in
            if url.lastPathComponent == "settings.json" { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        })
        let result = try await save(); XCTAssertFalse(result.success)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let backups = await service.listBackups(agent: .claudeCode)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(backups.first).path)), before)
    }
    func testReportCommitFailureRollsBackJsonInsteadOfReportingSuccess() async throws {
        try write(input()); let before = try Data(contentsOf: file)
        service = AgentConfigurationService(homeDirectory: home, writeConfigurationData: { data, url in
            if url.path.hasSuffix(".migration.json"),
               (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String == "committed" {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: .atomic)
        })
        let result = try await save(); XCTAssertFalse(result.success)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testRollbackRefusesToOverwriteExternalChange() async throws {
        try write(input()); let result = try await save()
        let receipt = try XCTUnwrap(result.claudeRollback)
        try write(["external": "newer"]); let newer = try Data(contentsOf: file)
        do { try await service.rollbackClaudeConfiguration(receipt); XCTFail("不能覆盖外部新文件") }
        catch { XCTAssertTrue(error is AgentConfigurationService.ClaudeCommitError) }
        XCTAssertEqual(try Data(contentsOf: file), newer)
    }
    func testManagedAccountSyncUsesLatestDiskAndSkipsUnchangedWritesAndOtherSources() async throws {
        try write(input()); let saved = try await save(); XCTAssertTrue(saved.success)
        let source = ClaudeConfigurationPlan.sourceID(url: config().proxyURL, key: config().apiKey)
        let before = await service.listBackups(agent: .claudeCode)
        let unchanged = await service.synchronizeManagedClaudeCatalog(sourceID: source, serviceBaseURLs: ["https://fixture.invalid"], models: models)
        XCTAssertEqual(unchanged?.success, true)
        let unchangedBackups = await service.listBackups(agent: .claudeCode); XCTAssertEqual(before.count, unchangedBackups.count)
        var latest = try read(); latest["externalUnknown"] = ["preserve": true]; try write(latest)
        let directory = models.filter { $0.id != "api-alias" } + [.init(id: "new-model", name: "new-model", provider: "fixture", isDefault: false)]
        let updated = await service.synchronizeManagedClaudeCatalog(sourceID: source, serviceBaseURLs: ["https://fixture.invalid"], models: directory)
        XCTAssertEqual(updated?.success, true, updated?.error ?? "")
        let after = try read(), menu = try XCTUnwrap(after["modelPicker"] as? [String: Any])
        let rows = try XCTUnwrap(menu["options"] as? [[String: Any]])
        XCTAssertFalse(rows.contains { $0["model"] as? String == "api-alias" })
        XCTAssertTrue(rows.contains { $0["model"] as? String == "new-model" })
        XCTAssertEqual(after["externalUnknown"] as? NSDictionary, ["preserve": true])
        let wrong = await service.synchronizeManagedClaudeCatalog(sourceID: "wrong", serviceBaseURLs: ["https://fixture.invalid"], models: [])
        XCTAssertNil(wrong)
        let absent = await service.managedClaudeConfiguration(serviceBaseURLs: ["https://other.invalid"]); XCTAssertNil(absent)
        let invalid = await service.synchronizeManagedClaudeCatalog(sourceID: source, serviceBaseURLs: ["https://fixture.invalid"], models: [models[0]])
        XCTAssertEqual(invalid?.success, false)
        XCTAssertEqual(try read() as NSDictionary, after as NSDictionary, "默认或角色失效不能擅自换模型")
    }
    @MainActor
    func testManagedNoticesAreBundledInEveryAppLanguage() {
        for language in AppLanguage.allCases {
            for name in ["oldVersion", "requiresJSON", "blocked", "changed", "fileChanged", "rollbackFailed", "summary", "removed", "restart"] {
                let key = "agents.catalog." + name
                XCTAssertNotEqual(language.bundle.localizedString(forKey: key, value: nil, table: nil), key)
            }
        }
    }
    func testNativeRoleCyclesAndOnlyOneMillionCatalogAreHandledWithoutGuessing() {
        var c = config(); c.modelSlots = [.opus: "sonnet", .sonnet: "opus", .haiku: "live-one"]
        let cycle = ClaudeConfigurationPlan(configuration: c, availableModels: models)
        XCTAssertTrue(cycle.blockingReferences.contains("Opus"))
        c = config(); c.modelSlots = [.opus: "long-model", .sonnet: "long-model", .haiku: "long-model"]
        c.claudeModel1M = [.opus: true, .sonnet: true, .haiku: true]
        let long = ClaudeConfigurationPlan(configuration: c, availableModels: [.init(id: "long-model[1m]", name: "long-model[1m]", provider: "fixture", isDefault: false)])
        XCTAssertTrue(long.blockingReferences.contains("Sonnet"), "CLI 最终请求 long-model，带后缀目录行不能证明裸 ID 可用")
        XCTAssertNil(long.confirmedRequest("sonnet"))
        XCTAssertTrue(long.configuration.claudeEffectivePickerOptions.isEmpty)
        XCTAssertEqual(long.configuration.modelSlots[.sonnet], "long-model", "不确认目录时保留旧选择，不猜型号或静默替换")
        let confirmed = ClaudeConfigurationPlan(configuration: c, availableModels: [.init(id: "long-model", name: "long-model", provider: "fixture", isDefault: false)])
        XCTAssertTrue(confirmed.blockingReferences.isEmpty)
        XCTAssertEqual(confirmed.confirmedRequest("sonnet"), "long-model[1m]")
    }

    func testCatalogSuffixOnlyPrefixIsPreservedButDoesNotGuessAnotherWireModel() {
        var value = config()
        value.modelSlots[.opus] = "codex/live-one[1m]"
        let directory = models + [.init(id: "codex/live-one[1m]", name: "codex/live-one[1m]", provider: "fixture", isDefault: false)]
        let plan = ClaudeConfigurationPlan(configuration: value, availableModels: directory)
        XCTAssertEqual(plan.configuration.modelSlots[.opus], "codex/live-one[1m]", "保留目录中完整前缀身份，不能猜成无前缀的另一个型号")
        XCTAssertTrue(plan.blockingReferences.contains("Opus"))
        XCTAssertNil(plan.confirmedRequest("opus"))
        XCTAssertFalse(plan.migrations.contains { $0.original == "codex/live-one[1m]" })
    }
    private actor CatalogSequence {
        private var count = 0
        let values: [AvailableModel]
        init(_ values: [AvailableModel]) { self.values = values }
        func fetch() -> [AvailableModel] {
            count += 1
            return count == 1 ? values : values + [.init(id: "new-model", name: "new-model", provider: "fixture", isDefault: false)]
        }
    }
    @MainActor
    func testSaveFreshensCatalogAndStopsWhenPublishedSetChanged() async throws {
        let sequence = CatalogSequence(models)
        let profile = home.appendingPathComponent("profile").path
        let vm = AgentSetupViewModel(configurationService: service,
            shellManager: ShellProfileManager(profilePath: { _ in profile }),
            fetchModels: { _, _ in await sequence.fetch() })
        vm.selectedAgent = .claudeCode; vm.currentConfiguration = config()
        let loaded = await vm.loadModels(); XCTAssertTrue(loaded)
        await vm.applyConfiguration()
        XCTAssertNil(vm.configResult)
        XCTAssertEqual(vm.errorMessage, "agents.catalog.changed".localized())
        XCTAssertFalse(vm.isConfiguring)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(vm.currentConfiguration?.modelSlots[.opus], "codex/live-one", "重新取证不改用户草稿")
    }
    @MainActor
    func testShellFailureRollsBackJsonAndKeepsBothOriginalFilesAndBackups() async throws {
        try write(input()); let before = try Data(contentsOf: file)
        let profile = home.appendingPathComponent("profile")
        let text = "export USER_SETTING=keep\n# CLIProxyAPI Configuration for Claude Code\nexport ANTHROPIC_MODEL=old\n# End CLIProxyAPI Configuration for Claude Code\n"
        try text.write(to: profile, atomically: true, encoding: .utf8)
        let shell = ShellProfileManager(profilePath: { _ in profile.path }, writeProfile: { _, _ in throw CocoaError(.fileWriteUnknown) })
        let directory = models
        let vm = AgentSetupViewModel(configurationService: service, shellManager: shell, fetchModels: { _, _ in directory })
        vm.selectedAgent = .claudeCode; vm.currentConfiguration = config()
        let loaded = await vm.loadModels(); XCTAssertTrue(loaded)
        await vm.applyConfiguration()
        XCTAssertEqual(vm.configResult?.success, false)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try String(contentsOf: profile, encoding: .utf8), text)
        let files = try FileManager.default.contentsOfDirectory(atPath: home.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("profile.backup.") })
        let backups = await service.listBackups(agent: .claudeCode); XCTAssertEqual(backups.count, 1)
    }
    func testAtomicSaveAndRestorePreserveSymbolicLinkAndUseIndependentBackup() async throws {
        let target = home.appendingPathComponent("dotfile.json")
        try JSONSerialization.data(withJSONObject: input()).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let original = try Data(contentsOf: target)
        let result = try await save(); XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), target.path)
        let list = await service.listBackups(agent: .claudeCode)
        let backup = try XCTUnwrap(list.first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backup.path)), original)
        try await service.restoreFromBackup(backup)
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), target.path)
    }
    private actor DelayedCatalog {
        let started: XCTestExpectation
        let values: [AvailableModel]
        private var pending: CheckedContinuation<[AvailableModel], Never>?
        private var count = 0
        init(_ started: XCTestExpectation, values: [AvailableModel]) { self.started = started; self.values = values }
        func fetch() async -> [AvailableModel] {
            count += 1
            if count == 1 { return await withCheckedContinuation { pending = $0; started.fulfill() } }
            return values + [.init(id: "latest-route", name: "latest-route", provider: "fixture", isDefault: false)]
        }
        func release() { pending?.resume(returning: values); pending = nil }
    }
    @MainActor
    func testLateAccountCatalogCannotOverwriteNewerManagedSync() async throws {
        try write(input()); let saved = try await save(); XCTAssertTrue(saved.success)
        let started = expectation(description: "首轮账号目录响应挂起")
        let gate = DelayedCatalog(started, values: models)
        let vm = AgentSetupViewModel(configurationService: service, fetchModels: { _, _ in await gate.fetch() })
        let old = Task { await vm.synchronizeManagedClaudeCatalog(serviceBaseURLs: ["https://fixture.invalid"], canCommit: { true }) }
        await fulfillment(of: [started], timeout: 3)
        let latest = await vm.synchronizeManagedClaudeCatalog(serviceBaseURLs: ["https://fixture.invalid"], canCommit: { true })
        XCTAssertNil(latest)
        let before = try Data(contentsOf: file)
        await gate.release(); let stale = await old.value; XCTAssertNil(stale)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let rows = try XCTUnwrap((read()["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]])
        XCTAssertTrue(rows.contains { $0["model"] as? String == "latest-route" })
    }

    func testRemovedOptionalRoleAndInheritedFallbackAreReconciledTogether() async throws {
        var original = input()
        var env = try XCTUnwrap(original["env"] as? [String: Any])
        env["ANTHROPIC_DEFAULT_FABLE_MODEL"] = "missing-fable"
        env["ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"] = "原名称"
        original["env"] = env; original["fallbackModel"] = ["sonnet", "default"]
        try write(original)
        let result = try await save(); XCTAssertTrue(result.success, result.error ?? "")
        let out = try read()
        XCTAssertNil((out["env"] as? [String: Any])?["ANTHROPIC_DEFAULT_FABLE_MODEL"])
        XCTAssertNil((out["env"] as? [String: Any])?["ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"])
        XCTAssertEqual(out["fallbackModel"] as? [String], ["sonnet", "default"])
    }
    func testShellCleanupPreservesOutsideCommandsAndRemovesRepeatedBlocks() async throws {
        let profile = home.appendingPathComponent("profile")
        let block = "# CLIProxyAPI Configuration for Claude Code\nexport ANTHROPIC_MODEL=old\n# End CLIProxyAPI Configuration for Claude Code\n"
        let before = "export BEFORE=keep\n" + block + "export BETWEEN=keep\n" + block + "export AFTER=keep\n"
        try before.write(to: profile, atomically: true, encoding: .utf8)
        let shell = ShellProfileManager(profilePath: { _ in profile.path })
        try await shell.removeFromProfile(shell: .zsh, agent: .claudeCode)
        XCTAssertEqual(try String(contentsOf: profile, encoding: .utf8), "export BEFORE=keep\nexport BETWEEN=keep\nexport AFTER=keep\n")
        let incomplete = "export BEFORE=keep\n# CLIProxyAPI Configuration for Claude Code\nexport ANTHROPIC_MODEL=old\n"
        try incomplete.write(to: profile, atomically: true, encoding: .utf8)
        do { try await shell.removeFromProfile(shell: .zsh, agent: .claudeCode); XCTFail("不完整管理段不能当成功清理") }
        catch { XCTAssertTrue(error is ShellProfileManager.ShellProfileError) }
        XCTAssertEqual(try String(contentsOf: profile, encoding: .utf8), incomplete)
    }

    func testManagedServiceIdentityPreservesDeploymentPath() async throws {
        var c = config(); c.proxyURL = "https://fixture.invalid/deploy//tenant/v1"
        let result = try await save(c); XCTAssertTrue(result.success, result.error ?? "")
        let current = await service.managedClaudeConfiguration(serviceBaseURLs: ["https://fixture.invalid/deploy//tenant"])
        XCTAssertEqual(current?.proxyURL, c.proxyURL)
        let other = await service.managedClaudeConfiguration(serviceBaseURLs: ["https://fixture.invalid/deploy/tenant"])
        XCTAssertNil(other, "不能把另一个部署路径的账号变化写入本配置")
    }

    func testReservedCliSelectorsCannotReappearAsRawGatewayModels() {
        let directory = models + ["default", "inherit", "best", "opusplan"].map {
            AvailableModel(id: $0, name: $0, provider: "fixture", isDefault: false)
        }
        let plan = ClaudeConfigurationPlan(configuration: config(), availableModels: directory)
        XCTAssertFalse(plan.configuration.claudeEffectivePickerOptions.contains { ClaudeConfigurationPlan.nonModelSelectors.contains($0.model) })
        XCTAssertNil(plan.confirmedRequest("default"))
        XCTAssertTrue(plan.blockingReferences.isEmpty)
        let reservedAlias = CPAModelAlias(id: "reserved", model: "live-one", alias: "default", provider: "fixture", protocolName: "openai",
            effort: nil, channel: nil, section: nil, providerIndex: 0, modelIndex: 0)
        let candidates = AgentModelCandidatePolicy(agent: .claudeCode, models: directory, aliases: [reservedAlias], selectedModel: "")
        XCTAssertTrue(candidates.confirmedAliases.isEmpty)
        XCTAssertTrue(Set(candidates.modelIDs).isDisjoint(with: ClaudeConfigurationPlan.nonModelSelectors))
    }

    func testRoleChainsGenerateFinalIDsAndKeepInnerOneMillionDeclaration() async throws {
        var c = config()
        c.modelSlots = [.opus: "sonnet", .sonnet: "haiku", .haiku: "live-one"]
        c.claudeDefaultModel = "opus"
        c.claudeModel1M[.haiku] = true
        c.claudeModelDisplayNames = [.opus: "live-one"]
        let plan = ClaudeConfigurationPlan(configuration: c, availableModels: models)
        XCTAssertTrue(plan.blockingReferences.isEmpty)
        for role in ModelSlot.legacyCases {
            XCTAssertEqual(plan.configuration.claudeRequestModel(for: role), "live-one[1m]")
        }
        let result = try await save(c)
        XCTAssertTrue(result.success, result.error ?? "")
        let doc = try read(), env = try XCTUnwrap(doc["env"] as? [String: String])
        XCTAssertEqual(doc["model"] as? String, "opus", "启动选择器继续保留角色继承")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_MODEL"], "live-one[1m]")
        for role in ModelSlot.legacyCases {
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_" + role.envSuffix + "_MODEL"], "live-one[1m]")
        }
        XCTAssertEqual(c.modelSlots[.opus], "sonnet", "纯计划不能回写原草稿")
        let loaded = await service.readConfiguration(agent: .claudeCode)
        let saved = try XCTUnwrap(loaded)
        var reopened = c
        reopened.modelSlots = saved.modelSlots
        reopened.claudeModelDisplayNames = saved.modelDisplayNames
        reopened.claudeModel1M = saved.claudeModel1M
        let second = ClaudeConfigurationPlan(configuration: reopened, availableModels: models,
                                              legacy: saved.claudeLegacyModelReferences)
        XCTAssertEqual(second.displayName(for: .opus), "live-one", "名称等于最终 ID 时重开也必须保留")
    }

    @MainActor
    func testClosedPageAccountInvalidationRejectsOldSyncBeforeNextSyncStarts() async throws {
        try write(input()); let saved = try await save(); XCTAssertTrue(saved.success)
        let before = try Data(contentsOf: file)
        let started = expectation(description: "旧目录请求在账号变更前挂起")
        let gate = DelayedCatalog(started, values: models + [.init(id: "stale-exclusive", name: "stale-exclusive", provider: "fixture", isDefault: false)])
        let vm = AgentSetupViewModel(configurationService: service, fetchModels: { _, _ in await gate.fetch() })
        let old = Task { await vm.synchronizeManagedClaudeCatalog(serviceBaseURLs: ["https://fixture.invalid"], canCommit: { true }) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertNil(vm.selectedAgent)
        let reload = vm.invalidateModelsForAccountChange(serviceBaseURLs: ["https://fixture.invalid"])
        XCTAssertNil(reload, "关闭页不需要页面刷新令牌，但仍必须废弃旧同步")
        // 刻意不启动第二轮同步：覆盖账号刷新还在 await、旧结果已经返回的间隙。
        await gate.release(); _ = await old.value
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    @MainActor
    func testQueuedCatalogCommitChecksInvalidationWhenConfigurationActorActuallyRuns() async throws {
        try write(input()); let saved = try await save(); XCTAssertTrue(saved.success)
        let before = try Data(contentsOf: file)
        let backupsBefore = await service.listBackups(agent: .claudeCode)
        let codex = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"before\"\n".utf8).write(to: codex)
        let backupPath = codex.path + ".backup.1"
        try Data("model = \"after\"\n".utf8).write(to: URL(fileURLWithPath: backupPath))
        let entered = expectation(description: "另一客户端的原子恢复占用配置 actor")
        let queued = expectation(description: "旧目录已返回并排队等待 actor")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let isolated = AgentConfigurationService(homeDirectory: home, writeConfigurationData: { data, url in
            if url.lastPathComponent == "config.toml" { entered.fulfill(); release.wait() }
            try data.write(to: url, options: .atomic)
        })
        let backup = AgentConfigurationService.BackupFile(path: backupPath, timestamp: Date(timeIntervalSince1970: 1), agent: .codexCLI)
        let holder = Task { try await isolated.restoreFromBackup(backup) }
        await fulfillment(of: [entered], timeout: 3)
        let permission = ClaudeCatalogCommitAuthorization()
        let source = ClaudeConfigurationPlan.sourceID(url: config().proxyURL, key: config().apiKey)
        let oldCatalog = models + [.init(id: "stale-exclusive", name: "stale-exclusive", provider: "fixture", isDefault: false)]
        let old = Task {
            queued.fulfill()
            return await isolated.synchronizeManagedClaudeCatalog(sourceID: source,
                serviceBaseURLs: ["https://fixture.invalid"], models: oldCatalog, authorization: permission)
        }
        await fulfillment(of: [queued], timeout: 3)
        permission.invalidate()
        release.signal()
        try await holder.value
        let stale = await old.value
        XCTAssertNil(stale)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let backupsAfter = await isolated.listBackups(agent: .claudeCode)
        XCTAssertEqual(backupsAfter.count, backupsBefore.count, "失效事务不能先创建备份或报告再停止")
    }

}
