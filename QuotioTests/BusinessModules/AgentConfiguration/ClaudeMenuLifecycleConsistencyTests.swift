import Foundation
import XCTest
@testable import QuotioPlus

/// 用生产配置 actor 验证菜单跨“应用、磁盘回读、账号目录同步”的完整往返，不只测试内存纯计划。
/// 全部文件位于临时目录，来源与容量均由离线目录提供，不接触用户配置或真实账号。
final class ClaudeMenuLifecycleConsistencyTests: XCTestCase {
    private actor CatalogGate {
        let started: XCTestExpectation
        var continuation: CheckedContinuation<[AvailableModel], Never>?
        init(_ started: XCTestExpectation) { self.started = started }
        func wait() async -> [AvailableModel] {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        func release(_ models: [AvailableModel]) { continuation?.resume(returning: models); continuation = nil }
    }
    private func fixture() throws -> (URL, AgentConfigurationService, AgentConfiguration) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeMenuLifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var config = AgentConfiguration(agent: .claudeCode, proxyURL: "https://fixture.invalid/v1", apiKey: "fixture-only")
        config.claudeCatalogManaged = true
        config.modelSlots = [.opus: "base", .sonnet: "base", .haiku: "base"]
        return (directory.appendingPathComponent(".claude/settings.json"), AgentConfigurationService(homeDirectory: directory), config)
    }
    private func models(name: String = "First Name", capacity: Int = 1_048_576, pool: Bool = true) -> [AvailableModel] {
        [.init(id: "base", name: "Base", provider: "fixture", isDefault: false),
         .init(id: "extra", name: name, provider: "fixture", isDefault: false,
               displaySource: .init(platforms: ["codex"], account: pool ? nil : "single@test.invalid", isAccountPool: pool),
               contextWindow: capacity)]
    }
    private func object(_ file: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }
    private func row(_ object: [String: Any]) throws -> [String: Any] {
        let rows = try XCTUnwrap((object["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]])
        return try XCTUnwrap(rows.first { ($0["model"] as? String)?.hasPrefix("extra") == true })
    }
    private func sync(_ service: AgentConfigurationService, config: AgentConfiguration, models: [AvailableModel]) async throws {
        let result = await service.synchronizeManagedClaudeCatalog(
            sourceID: ClaudeConfigurationPlan.sourceID(url: config.proxyURL, key: config.apiKey),
            serviceBaseURLs: ["https://fixture.invalid"], models: models)
        XCTAssertEqual(result?.success, true, result?.error ?? "未进入受管同步")
    }

    func testGeneratedNamePoolAndAutomaticContextFollowCatalogAfterDiskRoundTrip() async throws {
        let (file, service, config) = try fixture()
        let first = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: models())
        XCTAssertTrue(first.success)
        XCTAssertEqual(try row(object(file))["label"] as? String, "First Name[1m]")
        // 账号由池变为单一来源，容量降低；名称、来源和选择器应一起跟随当前目录。
        try await sync(service, config: config, models: models(name: "Second Name", capacity: 128_000, pool: false))
        let current = try row(object(file))
        XCTAssertEqual(current["model"] as? String, "extra")
        XCTAssertEqual(current["label"] as? String, "Second Name")
        XCTAssertEqual(current["description"] as? String, "Codex · single@test.invalid")
        // 再次启用第二个账号并恢复长窗口，不能一直保留第一次生成的名称或后缀。
        try await sync(service, config: config, models: models(name: "Third Name"))
        let latest = try row(object(file))
        XCTAssertEqual(latest["model"] as? String, "extra[1m]")
        XCTAssertEqual(latest["label"] as? String, "Third Name[1m]")
        XCTAssertEqual(latest["description"] as? String, "Codex · " + "agents.claudeMenu.accountPool".localizedStatic())
        // 用户直接改过已生成标题后，旧来源快照不能强行恢复该标题的自动管理权。
        var disk = try object(file)
        var menu = try XCTUnwrap(disk["modelPicker"] as? [String: Any])
        var rows = try XCTUnwrap(menu["options"] as? [[String: Any]])
        let index = try XCTUnwrap(rows.firstIndex { $0["model"] as? String == "extra[1m]" })
        rows[index]["label"] = "用户外部编辑名称"
        menu["options"] = rows; disk["modelPicker"] = menu
        try JSONSerialization.data(withJSONObject: disk).write(to: file)
        try await sync(service, config: config, models: models(name: "Fourth Name", capacity: 128_000))
        XCTAssertEqual(try row(object(file))["label"] as? String, "用户外部编辑名称")
    }

    func testAutomaticRoleDefaultAndSubagentDoNotBecomeExplicitAfterReadback() async throws {
        let (file, service, original) = try fixture()
        var config = original
        config.modelSlots[.opus] = "extra"
        config.claudeDefaultModel = "extra"
        config.claudeSubagentModel = "extra"
        let first = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: models())
        XCTAssertTrue(first.success)
        let read = await service.readConfiguration(agent: .claudeCode)
        XCTAssertNil(read?.claudeModel1M[.opus], "目录自动声明不能伪装成用户固定 true")
        XCTAssertEqual(read?.claudeDefaultModel1M, false)
        XCTAssertEqual(read?.claudeSubagentModel, "extra")
        try await sync(service, config: config, models: models(capacity: 128_000))
        let after = try object(file)
        let env = try XCTUnwrap(after["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "extra")
        XCTAssertEqual(after["model"] as? String, "extra")
        XCTAssertEqual(env["CLAUDE_CODE_SUBAGENT_MODEL"], "extra")
    }

    func testExternalLabelAndExplicitContextsSurviveWhileUnknownFieldsAndBackupRemainIntact() async throws {
        let (file, service, original) = try fixture()
        var config = original
        config.modelSlots[.opus] = "extra"
        config.claudeModel1M[.opus] = true
        config.claudeModel = "extra[1m]"
        config.claudeSubagentModel = "extra[1m]"
        config.claudeModelPicker.options.append(.init(model: "extra[1m]", label: "用户名称",
            extraFields: ["futureRow": .unsignedInteger(UInt64.max)]))
        config.claudeModelPicker.shouldWrite = true
        let first = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: models())
        XCTAssertTrue(first.success)
        var disk = try object(file)
        var ownership = try XCTUnwrap(disk["quotioClaudeCatalog"] as? [String: Any])
        var projection = try XCTUnwrap(ownership["projection"] as? [String: Any])
        projection["futureProjection"] = ["keep": true]
        ownership["projection"] = projection; ownership["futureOwner"] = ["keep": true]
        disk["quotioClaudeCatalog"] = ownership; disk["futureRoot"] = ["keep": true]
        let before = try JSONSerialization.data(withJSONObject: disk, options: [.sortedKeys])
        try before.write(to: file)
        try await sync(service, config: config, models: models(name: "Changed", capacity: 128_000))
        let after = try object(file), current = try row(after)
        XCTAssertEqual(current["model"] as? String, "extra[1m]")
        XCTAssertEqual(current["label"] as? String, "用户名称")
        XCTAssertEqual((current["futureRow"] as? NSNumber)?.uint64Value, UInt64.max)
        XCTAssertEqual(after["model"] as? String, "extra[1m]")
        let env = try XCTUnwrap(after["env"] as? [String: String])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "extra[1m]")
        XCTAssertEqual(env["CLAUDE_CODE_SUBAGENT_MODEL"], "extra[1m]")
        XCTAssertEqual(after["futureRoot"] as? NSDictionary, ["keep": true])
        let owner = try XCTUnwrap(after["quotioClaudeCatalog"] as? [String: Any])
        XCTAssertEqual(owner["futureOwner"] as? NSDictionary, ["keep": true])
        XCTAssertEqual((owner["projection"] as? [String: Any])?["futureProjection"] as? NSDictionary, ["keep": true])
        let backups = await service.listBackups(agent: .claudeCode)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(backups.first).path)), before)
    }

    func testFutureProjectionIsPreservedAndFailsBeforeBackupOrWrite() async throws {
        let (file, service, config) = try fixture()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let input: [String: Any] = ["quotioClaudeCatalog": ["managed": true, "version": 1,
            "source": ClaudeConfigurationPlan.sourceID(url: config.proxyURL, key: config.apiKey),
            "projection": ["version": 2, "future": ["keep": true]]]]
        let before = try JSONSerialization.data(withJSONObject: input)
        try before.write(to: file)
        let result = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: models())
        XCTAssertFalse(result.success)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let backups = await service.listBackups(agent: .claudeCode)
        XCTAssertTrue(backups.isEmpty)
    }

    func testExplicitDefaultAndNormalRoleStayIndependentFromSameAutomaticMenu() async throws {
        let (file, service, original) = try fixture()
        var config = original
        config.claudeModel = "extra[1m]"
        config.modelSlots[.sonnet] = "extra"
        config.claudeModel1M[.sonnet] = false
        config.claudeModelPicker.options.append(.init(model: "extra"))
        config.claudeModelPicker.shouldWrite = true
        let first = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: models())
        XCTAssertTrue(first.success)
        for capacity in [128_000, 1_048_576] {
            let read = await service.readConfiguration(agent: .claudeCode)
            XCTAssertEqual(read?.claudeDefaultModel1M, true, "同名自动菜单不应吸收历史 Default 显式后缀")
            XCTAssertEqual(read?.claudeModel1M[.sonnet], false, "同一型号各用途的普通／长窗口声明必须独立回填")
            try await sync(service, config: config, models: models(capacity: capacity))
            let disk = try object(file)
            XCTAssertEqual(disk["model"] as? String, "extra[1m]")
            XCTAssertEqual((disk["env"] as? [String: String])?["ANTHROPIC_DEFAULT_SONNET_MODEL"], "extra")
        }
    }

    func testOfficialRestorePreservesUnknownProjectionAndCanApplyAgain() async throws {
        let (file, service, config) = try fixture()
        let applied = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: models())
        XCTAssertTrue(applied.success)
        var disk = try object(file)
        var owner = try XCTUnwrap(disk["quotioClaudeCatalog"] as? [String: Any])
        var projection = try XCTUnwrap(owner["projection"] as? [String: Any])
        projection["future"] = ["keep": true]
        projection["contexts"] = ["future-context": "keep"]
        owner["projection"] = projection; disk["quotioClaudeCatalog"] = owner
        try JSONSerialization.data(withJSONObject: disk).write(to: file)
        var official = config
        official.setupMode = .defaultSetup
        let restored = try await service.generateConfiguration(agent: .claudeCode, config: official, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: models())
        XCTAssertTrue(restored.success, restored.error ?? "")
        let remaining = try XCTUnwrap((object(file)["quotioClaudeCatalog"] as? [String: Any])?["projection"] as? [String: Any])
        XCTAssertEqual(remaining["future"] as? NSDictionary, ["keep": true])
        XCTAssertEqual(remaining["contexts"] as? NSDictionary, ["future-context": "keep"])
        XCTAssertNil(remaining["version"])
        let again = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: models())
        XCTAssertTrue(again.success, again.error ?? "")
    }

    func testLegacyUnmanagedServiceCallKeepsManagedMenuTextAndContextUntouched() async throws {
        let (file, service, config) = try fixture()
        let first = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: models())
        XCTAssertTrue(first.success)
        let menu = try XCTUnwrap(object(file)["modelPicker"] as? NSDictionary)
        var compatible = config
        compatible.claudeCatalogManaged = false
        compatible.claudeModelPicker.shouldWrite = false
        let result = try await service.generateConfiguration(agent: .claudeCode, config: compatible, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: models())
        XCTAssertTrue(result.success)
        XCTAssertEqual(try object(file)["modelPicker"] as? NSDictionary, menu)
    }

    /// 配置 actor 被其他事务占用时更换 CPA，旧许可必须在替换的同步入口失效，不能先备份再拒绝。
    @MainActor
    func testClientReplacementRevokesPendingCommitBeforeConfigurationActorIsReleased() async throws {
        let (file, service, config) = try fixture()
        let result = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: models())
        XCTAssertTrue(result.success)
        let before = try Data(contentsOf: file), home = file.deletingLastPathComponent().deletingLastPathComponent()
        let backups = await service.listBackups(agent: .claudeCode)
        let suite = "ClaudeMenuCommit-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = QuotaViewModel(directAuthService: DirectAuthFileService(authDirectory: home.appendingPathComponent("auth")),
            startsBackgroundServices: false, modeManager: OperatingModeManager(defaults: defaults),
            menuBarSettings: MenuBarSettingsManager(defaults: defaults), refreshSettings: RefreshSettingsManager(defaults: defaults),
            warmupSettings: WarmupSettingsManager(defaults: defaults),
            notificationManager: NotificationManager(testDefaults: defaults, notificationSink: { _ in }))
        let client = ManagementAPIClient(baseURL: "https://unused.invalid/v8/management", authKey: "fixture-only")
        root.setAuthImportClientForTesting(client)
        addTeardownBlock { @MainActor in await client.invalidate(); defaults.removePersistentDomain(forName: suite) }
        let fetched = expectation(description: "旧目录正在等待返回")
        let gate = CatalogGate(fetched)
        let entered = expectation(description: "配置 actor 被另一客户端事务占用")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let isolated = AgentConfigurationService(homeDirectory: home, writeConfigurationData: { data, url in
            if url.lastPathComponent == "config.toml" { entered.fulfill(); release.wait() }
            try data.write(to: url, options: .atomic)
        })
        let setup = AgentSetupViewModel(configurationService: isolated, fetchModels: { _, _ in await gate.wait() })
        root.setAgentSetupViewModelForTesting(setup)
        let task = Task { await setup.synchronizeManagedClaudeCatalog(serviceBaseURLs: ["https://fixture.invalid"], canCommit: { true }) }
        await fulfillment(of: [fetched], timeout: 2)
        let permission = try XCTUnwrap(setup.managedCatalogAuthorizationForTesting())
        let codex = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"old\"".utf8).write(to: codex)
        let backup = codex.path + ".backup.1"
        try Data("model = \"new\"".utf8).write(to: URL(fileURLWithPath: backup))
        let holder = Task { try await isolated.restoreFromBackup(.init(path: backup, timestamp: Date(timeIntervalSince1970: 1), agent: .codexCLI)) }
        await fulfillment(of: [entered], timeout: 2)
        await gate.release(models(name: "Stale Name"))
        root.setAuthImportClientForTesting(nil)
        XCTAssertNil(permission.withPermission { true }, "原客户端退出应同步撤销原许可，而不依赖迟到响应的返回检查")
        release.signal()
        try await holder.value
        _ = await task.value
        XCTAssertEqual(try Data(contentsOf: file), before)
        let after = await service.listBackups(agent: .claudeCode)
        XCTAssertEqual(after.count, backups.count)
    }
}
